#!/bin/bash
# Stop the VM and replace \EFI\BOOT\BOOTX64.EFI on the test disk, leaving the
# VM off. Lets you retest with a different image without rebuilding the pool.
# Run with sudo.   sudo test/swapefi.sh out/zbm-clevis.EFI
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

T="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -r "${T}/test.conf" ] && . "${T}/test.conf"
: "${IMG:=/var/lib/libvirt/images/zbmtest.img}"
: "${VM:=zbmtest}"

EFI="${1:?usage: swapefi.sh /path/to/image.EFI}"
[ -f "${EFI}" ] || { echo "FAIL: ${EFI} missing"; exit 1; }

virsh destroy "${VM}" 2>/dev/null || true
sleep 2

LOOP="$(losetup -f --show -P "${IMG}")"
trap 'losetup -d "${LOOP}" 2>/dev/null || true' EXIT
udevadm settle; sleep 1
MNT="$(mktemp -d)"
mount "${LOOP}p1" "${MNT}"
cp "${EFI}" "${MNT}/EFI/BOOT/BOOTX64.EFI"
sync
echo "installed: $(sha256sum "${MNT}/EFI/BOOT/BOOTX64.EFI")"
echo "source   : $(sha256sum "${EFI}")"
umount "${MNT}"; rmdir "${MNT}"
losetup -d "${LOOP}"; trap - EXIT
echo "OK: ESP now carries $(basename "${EFI}"); ${VM} is off"
