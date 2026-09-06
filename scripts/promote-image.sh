#!/usr/bin/env bash
# Promote a staged ZFSBootMenu image to be the machine's default, AFTER a
# verified good boot from the one-shot entry install-image.sh created.
#
# Run as root on the target, from the boot that came up on the staged image.
#
#   PROMOTE_REL=EFI/ZBM/VMLINUZ.EFI scripts/promote-image.sh
#
# Environment (all optional; defaults come from the install state file):
#   STATE_FILE   written by install-image.sh
#                (default /var/lib/zbm-clevis/install-state)
#   PROMOTE_REL  ESP-relative path to become the default loader
#                (default EFI/ZBM/VMLINUZ.EFI)
#   KEEP_STAGING set to 1 to leave the staged file and its boot entry in place
#
# The safety rules, in order of importance:
#   1. Refuse unless THIS boot came from the one-shot entry. Promoting an image
#      you have not actually booted is how you end up at a rescue USB.
#   2. Refuse unless some OTHER file on the ESP still holds a byte-identical
#      copy of the loader we are about to overwrite -- i.e. there is a backup
#      to fall back to.
#   3. Refuse if anything else on the ESP changed since install time.
#   4. Restore BootOrder exactly as install-image.sh recorded it.
set -uo pipefail

STATE_FILE="${STATE_FILE:-/var/lib/zbm-clevis/install-state}"
[ "$(id -u)" -eq 0 ] || { echo "FAIL: run as root" >&2; exit 1; }
[ -r "$STATE_FILE" ] || { echo "FAIL: $STATE_FILE not readable; was install-image.sh run?" >&2; exit 1; }

# shellcheck disable=SC1090
. "$STATE_FILE"
: "${ESP:?state file has no ESP}"
: "${TARGET_REL:?state file has no TARGET_REL}"
: "${BOOT_NUM:?state file has no BOOT_NUM}"
: "${IMAGE_SHA:?state file has no IMAGE_SHA}"
: "${ORIG_BOOTORDER:?state file has no ORIG_BOOTORDER}"
PROMOTE_REL="${PROMOTE_REL:-EFI/ZBM/VMLINUZ.EFI}"
KEEP_STAGING="${KEEP_STAGING:-0}"

mountpoint -q "$ESP" || { echo "FAIL: $ESP not mounted"; exit 1; }

# --- 1. this boot must be the one we staged -------------------------------
cur="$(efibootmgr | awk '/^BootCurrent:/{print $2}')"
echo "BootCurrent=${cur} expected=${BOOT_NUM}"
[ "$cur" = "$BOOT_NUM" ] || {
  echo "FAIL: this boot did not come from Boot${BOOT_NUM} (the staged image)."
  echo "      Refusing to promote an image this machine has not just proven."
  exit 1
}

src="${ESP}/${TARGET_REL}"
dst="${ESP}/${PROMOTE_REL}"
[ -f "$src" ] || { echo "FAIL: staged image ${src} is gone"; exit 1; }
got="$(sha256sum "$src" | cut -d' ' -f1)"
[ "$got" = "$IMAGE_SHA" ] || { echo "FAIL: ${src} sha mismatch ${got} != ${IMAGE_SHA}"; exit 1; }

# --- 2. a backup of the outgoing loader must exist ------------------------
if [ -f "$dst" ]; then
  dst_sha="$(sha256sum "$dst" | cut -d' ' -f1)"
  echo "outgoing ${PROMOTE_REL} sha256=${dst_sha}"
  backups="$(find "$ESP" -type f \( -iname '*.EFI' -o -iname '*.efi' \) -print0 \
             | xargs -0 -r sha256sum \
             | awk -v s="$dst_sha" -v d="${ESP}/${PROMOTE_REL}" -v t="${ESP}/${TARGET_REL}" \
                   '$1==s && $2!=d && $2!=t {print $2}')"
  if [ -z "$backups" ]; then
    echo "FAIL: no other file on the ESP is a byte-identical copy of"
    echo "      ${PROMOTE_REL}. Promoting would leave you with no known-good"
    echo "      loader. Copy the current one aside first, e.g.:"
    echo "          cp ${dst} ${ESP}/EFI/ZBM/VMLINUZ-BACKUP.EFI"
    echo "      and give it its own boot entry with efibootmgr -c."
    exit 1
  fi
  echo "backup copies of the outgoing loader:"
  printf '%s\n' "$backups" | sed 's/^/  /'
else
  echo "note: ${dst} does not exist yet; nothing to back up"
fi

# --- 3. nothing else on the ESP may have changed --------------------------
drift=0
while read -r sha rel; do
  [ -n "${rel:-}" ] || continue
  [ "$rel" = "$PROMOTE_REL" ] && continue   # this one is about to change
  f="${ESP}/${rel}"
  if [ ! -f "$f" ]; then
    echo "DRIFT: ${rel} recorded at install time is gone"; drift=1; continue
  fi
  now="$(sha256sum "$f" | cut -d' ' -f1)"
  [ "$now" = "$sha" ] || { echo "DRIFT: ${rel} changed since install"; drift=1; }
done < <(sed -n 's/^#INV //p' "$STATE_FILE")
[ "$drift" -eq 0 ] || { echo "FAIL: the ESP changed since install-image.sh ran; refusing"; exit 1; }

# --- promote ---------------------------------------------------------------
mkdir -p "$(dirname "$dst")"
cp "$src" "${dst}.tmp" && sync
mv "${dst}.tmp" "$dst" && sync
[ "$(sha256sum "$dst" | cut -d' ' -f1)" = "$IMAGE_SHA" ] || { echo "FAIL: promoted copy corrupted"; exit 1; }
echo "promoted ${TARGET_REL} -> ${PROMOTE_REL}"

# --- tidy up the staging file and its one-shot entry ----------------------
if [ "$KEEP_STAGING" != "1" ]; then
  rm -f "$src" && sync
  efibootmgr -b "$BOOT_NUM" -B >/dev/null || echo "WARN: could not delete Boot${BOOT_NUM}"
fi

# Some firmware rewrites BootOrder whenever entries change. Put it back.
efibootmgr -o "$ORIG_BOOTORDER" >/dev/null
now_order="$(efibootmgr | awk '/^BootOrder:/{print $2}')"
[ "$now_order" = "$ORIG_BOOTORDER" ] \
  || echo "WARN: BootOrder is ${now_order}, wanted ${ORIG_BOOTORDER} -- fix it by hand"

echo
efibootmgr | grep -E '^(BootNext|BootOrder|BootCurrent)'
find "$ESP" -type f \( -iname '*.EFI' -o -iname '*.efi' \) -print0 | xargs -0 -r sha256sum
df -h "$ESP" | tail -1
echo "PROMOTE_OK"
