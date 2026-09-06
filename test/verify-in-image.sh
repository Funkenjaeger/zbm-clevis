#!/bin/bash
# Inspect a built ZFSBootMenu EFI image WITHOUT booting it: pull the initramfs
# back out of the PE binary and check that everything we thought we baked in is
# actually there, with the bytes we expect.
#
#   test/verify-in-image.sh out/zbm-clevis.EFI [outdir]
#
# Needs: objcopy (binutils), zstd, cpio, python3. No root, no libvirt.
#
# Layout note. A ZFSBootMenu unified kernel image is a PE file whose sections
# carry the pieces:
#     .cmdline   the kernel command line
#     .linux     the kernel
#     .initrd    the initramfs
# and the initramfs itself is TWO concatenated archives: an uncompressed newc
# cpio (the "early" one, holding kernel modules and firmware) followed by a
# zstd-compressed newc cpio (everything else). Tools that only look at the
# first archive will tell you the image is nearly empty. This script walks the
# first archive to its TRAILER!!! entry, finds the zstd magic after it, and
# unpacks both.
set -uo pipefail

EFI="${1:?usage: verify-in-image.sh <image.EFI> [outdir]}"
[ -r "${EFI}" ] || { echo "FAIL: ${EFI} not readable"; exit 1; }
OUT="${2:-$(mktemp -d)}"
mkdir -p "${OUT}"

for t in objcopy zstd cpio python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} not installed"; exit 1; }
done

echo "=== image ==="
echo "file   : ${EFI}"
echo "bytes  : $(stat -c %s "${EFI}")"
echo "sha256 : $(sha256sum "${EFI}" | cut -d' ' -f1)"

echo
echo "=== .cmdline ==="
objcopy -O binary --only-section=.cmdline "${EFI}" "${OUT}/cmdline" 2>/dev/null
tr -d '\000' < "${OUT}/cmdline"; echo

objcopy -O binary --only-section=.initrd "${EFI}" "${OUT}/initrd.img" 2>/dev/null
[ -s "${OUT}/initrd.img" ] || { echo "FAIL: no .initrd section in ${EFI}"; exit 1; }

# Split the two archives.
SPLIT="$(python3 - "${OUT}/initrd.img" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
off = 0
# Walk newc cpio headers: 110-byte header, then namesize bytes (4-aligned),
# then filesize bytes (4-aligned).
while True:
    if data[off:off+6] != b'070701':
        # Not a cpio header: either padding to the next archive, or we are done.
        break
    namesize = int(data[off+94:off+102], 16)
    filesize = int(data[off+54:off+62], 16)
    name = data[off+110:off+110+namesize-1]
    nxt = off + 110 + namesize
    nxt += (-nxt) % 4
    nxt += filesize
    nxt += (-nxt) % 4
    off = nxt
    if name == b'TRAILER!!!':
        break
# Skip zero padding, then find the zstd frame magic.
magic = b'\x28\xb5\x2f\xfd'
idx = data.find(magic, off)
if idx < 0:
    sys.exit("no zstd magic after the early cpio")
print(off, idx)
PY
)" || { echo "FAIL: could not split the initramfs"; exit 1; }
EARLY_END="${SPLIT%% *}"; ZSTD_AT="${SPLIT##* }"
echo
echo "=== initrd layout ==="
echo "early newc cpio : 0 .. ${EARLY_END}"
echo "zstd frame at   : ${ZSTD_AT}"

head -c "${EARLY_END}" "${OUT}/initrd.img" > "${OUT}/early.cpio"
tail -c "+$((ZSTD_AT + 1))" "${OUT}/initrd.img" > "${OUT}/main.cpio.zst"

cpio -t --quiet < "${OUT}/early.cpio" 2>/dev/null | sort > "${OUT}/early.list"
zstd -dc "${OUT}/main.cpio.zst" 2>/dev/null | cpio -t --quiet 2>/dev/null | sort > "${OUT}/main.list"
echo "early entries   : $(wc -l < "${OUT}/early.list")"
echo "main entries    : $(wc -l < "${OUT}/main.list")"

R="${OUT}/root"; rm -rf "${R}"; mkdir -p "${R}"
( cd "${R}" && zstd -dc "${OUT}/main.cpio.zst" | cpio -idm --quiet --no-absolute-filenames ) 2>/dev/null || true

echo
echo "=== hostid ==="
# /etc/hostid in the image is a symlink to /build/hostid (mkinitcpio recorded
# the path it was given), so look at both.
hid=""
for c in "${R}/etc/hostid" "${R}/build/hostid"; do
  [ -f "$c" ] && { hid="$c"; break; }
done
if [ -n "$hid" ]; then
  echo "${hid#"${R}"} = $(od -An -tx4 "$hid" | tr -d ' ')  ($(stat -c %s "$hid") bytes)"
  [ -L "${R}/etc/hostid" ] && echo "  (/etc/hostid -> $(readlink "${R}/etc/hostid"))"
else
  echo "WARN: no hostid in the image -- ZFS will use the running default and"
  echo "      may refuse to import the pool"
fi

echo
echo "=== dropbear ==="
if [ -f "${R}/etc/dropbear/dropbear.conf" ]; then
  echo "dropbear.conf : $(cat "${R}/etc/dropbear/dropbear.conf")"
  echo "root_key      : $(wc -l < "${R}/etc/dropbear/root_key") key(s), sha256 $(sha256sum < "${R}/etc/dropbear/root_key" | cut -c1-16)..."
  ls -l "${R}/etc/dropbear/" | sed 's/^/  /'
else
  echo "no /etc/dropbear in this image"
fi

echo
echo "=== clevis ==="
if [ -f "${R}/etc/zbm-clevis/clevis.jwe" ]; then
  echo "clevis.jwe    : $(stat -c '%a %s bytes' "${R}/etc/zbm-clevis/clevis.jwe"), sha256 $(sha256sum < "${R}/etc/zbm-clevis/clevis.jwe" | cut -d' ' -f1)"
  echo "timeout       : $(cat "${R}/etc/zbm-clevis/timeout" 2>/dev/null || echo '(absent, hook default applies)')"
  for b in clevis clevis-decrypt clevis-decrypt-tang clevis-decrypt-sss clevis-decrypt-null jose curl timeout; do
    p="$(grep -m1 -E "(^|/)(usr/)?(s?bin)/${b}\$" "${OUT}/main.list" || true)"
    printf '  %-22s %s\n' "$b" "${p:-MISSING}"
  done
  h="${R}/libexec/hooks/load-key.d/10-clevis-tang.sh"
  if [ -f "$h" ]; then
    echo "hook          : $(stat -c %a "$h") $(sha256sum "$h" | cut -d' ' -f1)"
    echo "--- hook body ---"
    sed 's/^/  /' "$h"
  else
    echo "hook          : MISSING -- the image will never try Clevis"
  fi
else
  echo "no /etc/zbm-clevis in this image (dropbear-only build?)"
fi

echo
echo "=== net hook timeout ==="
grep -h 'ipconfig' "${R}/hooks/net" 2>/dev/null | sed 's/^/  /' || echo "  (no /hooks/net found)"

echo
echo "artefacts left in ${OUT}"
