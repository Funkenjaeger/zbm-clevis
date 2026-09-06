#!/usr/bin/env bash
# Install a freshly built ZFSBootMenu image on the TARGET machine, as a NEW
# file on the ESP with its OWN boot entry, and arm a one-shot boot into it.
#
# Nothing that already exists on the ESP is touched. If the new image does not
# work you power-cycle and the machine comes back on the entry it has always
# used. Only after a verified good boot do you run promote-image.sh.
#
# Run as root on the target.
#
#   ESP=/boot/efi DISK=/dev/nvme0n1 PART=1 \
#   scripts/install-image.sh out/zbm-clevis.EFI <expected-sha256>
#
# Environment (all optional except DISK):
#   ESP         ESP mount point                    (default /boot/efi)
#   DISK        block device holding the ESP       (REQUIRED, e.g. /dev/sda)
#   PART        partition number of the ESP        (default 1)
#   TARGET_REL  ESP-relative path to write         (default EFI/ZBM/VMLINUZ-NEW.EFI)
#   LABEL       UEFI boot entry label              (default "ZFSBootMenu (new)")
#   STATE_FILE  where to record what we did        (default
#               /var/lib/zbm-clevis/install-state)
set -uo pipefail

img="${1:-}"; want="${2:-}"
[ -n "$img" ] && [ -n "$want" ] || { echo "usage: $0 <image.EFI> <expected-sha256>" >&2; exit 1; }

ESP="${ESP:-/boot/efi}"
DISK="${DISK:-}"
PART="${PART:-1}"
TARGET_REL="${TARGET_REL:-EFI/ZBM/VMLINUZ-NEW.EFI}"
LABEL="${LABEL:-ZFSBootMenu (new)}"
STATE_FILE="${STATE_FILE:-/var/lib/zbm-clevis/install-state}"

[ "$(id -u)" -eq 0 ] || { echo "FAIL: run as root" >&2; exit 1; }
[ -n "$DISK" ] || { echo "FAIL: set DISK to the block device holding the ESP" >&2; exit 1; }
[ -b "$DISK" ] || { echo "FAIL: $DISK is not a block device" >&2; exit 1; }
[ -r "$img" ] || { echo "FAIL: $img not readable" >&2; exit 1; }
command -v efibootmgr >/dev/null 2>&1 || { echo "FAIL: efibootmgr not installed" >&2; exit 1; }
[ -d /sys/firmware/efi ] || { echo "FAIL: not booted in UEFI mode" >&2; exit 1; }

got="$(sha256sum "$img" | cut -d' ' -f1)"
[ "$got" = "$want" ] || { echo "FAIL: sha256 mismatch $got != $want"; exit 1; }
mountpoint -q "$ESP" || { echo "FAIL: $ESP not mounted"; exit 1; }

dst="${ESP}/${TARGET_REL}"
# The whole point of this script: never overwrite anything.
if [ -e "$dst" ]; then
  echo "FAIL: $dst already exists. Refusing to overwrite. Pick another"
  echo "      TARGET_REL, or remove that file deliberately if it is a stale"
  echo "      staging copy from a previous run."
  exit 1
fi

echo "=== ESP inventory before ==="
# Record every EFI binary currently on the ESP with its digest, so
# promote-image.sh can prove nothing else changed underneath it.
inventory="$(find "$ESP" -type f \( -iname '*.EFI' -o -iname '*.efi' \) -print0 \
             | xargs -0 -r sha256sum | sed "s#${ESP}/##" | sort -k2)"
printf '%s\n' "$inventory"
[ -n "$inventory" ] || echo "(no EFI binaries found -- is $ESP really the ESP?)"

avail_kb="$(df --output=avail -k "$ESP" | tail -1)"
need_kb=$(( ($(stat -c %s "$img") / 1024) + 2048 ))
[ "$avail_kb" -gt "$need_kb" ] || { echo "FAIL: ESP has ${avail_kb}k free, need ${need_kb}k"; exit 1; }

orig_order="$(efibootmgr | awk '/^BootOrder:/{print $2}')"
echo "original BootOrder=${orig_order}"
[ -n "$orig_order" ] || { echo "FAIL: could not read BootOrder"; exit 1; }

mkdir -p "$(dirname "$dst")"
cp "$img" "${dst}.tmp" && sync && mv "${dst}.tmp" "$dst" && sync
[ "$(sha256sum "$dst" | cut -d' ' -f1)" = "$want" ] || { echo "FAIL: copy to ESP corrupted"; exit 1; }
echo "installed ${dst}"

# Reuse an entry with our label if one is already there; otherwise create one.
find_entry() {
  efibootmgr | awk -v l="$LABEL" 'index($0,l){sub(/^Boot/,"",$1); sub(/\*$/,"",$1); print $1; exit}'
}
num="$(find_entry)"
if [ -z "$num" ]; then
  # efibootmgr wants a backslash-separated, ESP-relative loader path.
  loader="\\$(printf '%s' "$TARGET_REL" | tr '/' '\\')"
  efibootmgr -c -d "$DISK" -p "$PART" -L "$LABEL" -l "$loader" >/dev/null
  num="$(find_entry)"
fi
[ -n "$num" ] || { echo "FAIL: could not find or create boot entry"; exit 1; }
echo "entry Boot${num} = ${LABEL}"

# `efibootmgr -c` prepends the new entry to BootOrder -- and some firmware
# (Lenovo, in the wild) reorders the whole list while it is at it. Put the
# original order back verbatim and check that it took.
efibootmgr -o "$orig_order" >/dev/null
now_order="$(efibootmgr | awk '/^BootOrder:/{print $2}')"
[ "$now_order" = "$orig_order" ] || { echo "FAIL: BootOrder is now ${now_order}, wanted ${orig_order}"; exit 1; }

# One shot. BootNext is consumed by the firmware on the next boot, so a machine
# that fails to come up simply reverts to BootOrder on the power cycle after.
efibootmgr -n "$num" >/dev/null

mkdir -p "$(dirname "$STATE_FILE")"
{
  echo "# written by install-image.sh on $(date -Is)"
  echo "ESP=${ESP}"
  echo "TARGET_REL=${TARGET_REL}"
  echo "LABEL=${LABEL}"
  echo "BOOT_NUM=${num}"
  echo "IMAGE_SHA=${want}"
  echo "ORIG_BOOTORDER=${orig_order}"
  echo "# ESP inventory recorded before the new file was written:"
  printf '%s\n' "$inventory" | sed 's/^/#INV /'
} > "$STATE_FILE"
chmod 600 "$STATE_FILE"

echo
efibootmgr | grep -E '^(BootNext|BootOrder|BootCurrent)'
efibootmgr | grep -E "^Boot${num}"
echo "state written to ${STATE_FILE}"
echo "INSTALL_OK BootNext=${num}"
echo
echo "Now reboot. If the machine comes up as expected, run promote-image.sh"
echo "from that boot; if it does not, power-cycle and you are back where you"
echo "started."
