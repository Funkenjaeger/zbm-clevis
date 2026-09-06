#!/bin/bash
# Create the throwaway UEFI test disk: a GPT with an ESP carrying the image
# under test as the removable-media fallback loader, and a second partition
# holding a disposable encrypted pool with a bootfs.
#
# Run with sudo.   sudo test/mkdisk.sh out/zbm-dropbear.EFI
set -euo pipefail

T="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -r "${T}/test.conf" ] && . "${T}/test.conf"
: "${IMG:=/var/lib/libvirt/images/zbmtest.img}"
: "${POOL:=zbmtest}"
: "${TEST_PASSPHRASE:=zbm-test-passphrase}"
PW="${T}/test.pw"

EFI="${1:?usage: mkdisk.sh /path/to/image.EFI}"
[ -f "${EFI}" ] || { echo "FAIL: ${EFI} missing"; exit 1; }

# Never operate on a pool that is currently imported -- if the name collides
# with something real, stop.
if zpool list -H -o name 2>/dev/null | grep -qx "${POOL}"; then
  echo "FAIL: a pool named '${POOL}' is imported. Refusing to touch it."; exit 1
fi

printf '%s' "${TEST_PASSPHRASE}" > "${PW}"
chmod 600 "${PW}"
[ "$(wc -c < "${PW}")" -eq "${#TEST_PASSPHRASE}" ] || { echo "FAIL: pwfile wrong size"; exit 1; }

rm -f "${IMG}"
truncate -s 4G "${IMG}"

sgdisk -og "${IMG}" >/dev/null
sgdisk -n 1:2048:+512M -t 1:EF00 -c 1:ESP "${IMG}" >/dev/null
sgdisk -n 2:0:0        -t 2:BF00 -c 2:ZFS "${IMG}" >/dev/null
sgdisk -p "${IMG}"

LOOP="$(losetup -f --show -P "${IMG}")"
echo "LOOP=${LOOP}"
trap 'losetup -d "${LOOP}" 2>/dev/null || true' EXIT
udevadm settle
sleep 1
[ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] || { echo "FAIL: partitions did not appear"; exit 1; }

mkfs.vfat -F32 -n ZBMESP "${LOOP}p1" >/dev/null
MNT="$(mktemp -d)"
mount "${LOOP}p1" "${MNT}"
mkdir -p "${MNT}/EFI/BOOT"
# \EFI\BOOT\BOOTX64.EFI is the removable-media fallback path: OVMF boots it
# without needing any NVRAM entry, which keeps the harness stateless.
cp "${EFI}" "${MNT}/EFI/BOOT/BOOTX64.EFI"
sync
echo "ESP sha256: $(sha256sum "${MNT}/EFI/BOOT/BOOTX64.EFI")"
umount "${MNT}"; rmdir "${MNT}"

zpool create -f -o ashift=12 -o compatibility=openzfs-2.2-linux \
  -O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation="file://${PW}" \
  -O mountpoint=none -R "/mnt/${POOL}" "${POOL}" "${LOOP}p2"

zfs create -p -o canmount=noauto -o mountpoint=/ "${POOL}/ROOT/test"
zpool set "bootfs=${POOL}/ROOT/test" "${POOL}"
# ZFSBootMenu (and the load-key hook) must see keylocation=prompt, otherwise
# ZFS would look for the keyfile path, which does not exist in the initramfs.
zfs set keylocation=prompt "${POOL}"

echo "--- pool state before export ---"
zpool get -H -o value bootfs "${POOL}"
zfs get -H -o value keylocation,keystatus "${POOL}"
zpool export "${POOL}"

losetup -d "${LOOP}"
trap - EXIT
echo "--- after export ---"
zpool list
losetup -a
echo "OK: ${IMG} ready"
