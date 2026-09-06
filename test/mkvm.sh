#!/bin/bash
# Define (and start) the throwaway test VM around the disk mkdisk.sh built.
# Run with sudo.   sudo test/mkvm.sh
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

T="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -r "${T}/test.conf" ] && . "${T}/test.conf"
: "${IMG:=/var/lib/libvirt/images/zbmtest.img}"
: "${VM:=zbmtest}"
: "${NET:=default}"
: "${OVMF_CODE:=/usr/share/OVMF/OVMF_CODE_4M.fd}"
: "${OVMF_VARS:=/usr/share/OVMF/OVMF_VARS_4M.fd}"

[ -f "${IMG}" ] || { echo "FAIL: ${IMG} missing; run mkdisk.sh first"; exit 1; }
[ -f "${OVMF_CODE}" ] || { echo "FAIL: ${OVMF_CODE} missing; set OVMF_CODE in test.conf"; exit 1; }

virsh net-info "${NET}" >/dev/null 2>&1 || { echo "FAIL: no libvirt network '${NET}'"; exit 1; }
if [ "$(virsh net-info "${NET}" | awk '/^Active:/{print $2}')" != "yes" ]; then
  echo "note: starting libvirt network '${NET}' (remember to stop it afterwards"
  echo "      if it was inactive on purpose)"
  virsh net-start "${NET}"
fi

virsh destroy "${VM}" 2>/dev/null || true
virsh undefine "${VM}" --nvram 2>/dev/null || true

virt-install \
  --name "${VM}" \
  --memory 2048 --vcpus 2 \
  --boot "uefi,loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,nvram.template=${OVMF_VARS}" \
  --disk "path=${IMG},format=raw,bus=virtio" \
  --network "network=${NET},model=virtio" \
  --graphics vnc \
  --osinfo detect=on,require=off \
  --noautoconsole --import

sleep 2
virsh list --all
virsh dumpxml "${VM}" | grep -E "loader|nvram|<interface|mac address|source (network|file)"
echo "OK: ${VM} defined and started"
