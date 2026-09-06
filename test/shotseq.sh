#!/bin/bash
# Cold-boot the VM and grab a screenshot every INTERVAL seconds, with no SSH
# traffic at all -- dropbear logs every connection to the ZFSBootMenu console,
# so polling over SSH scrolls the very prompt you are trying to photograph.
# This is how you time "when did the passphrase prompt appear".
#
# Run with sudo.   sudo test/shotseq.sh <tag> [count] [interval]
set -u
export LIBVIRT_DEFAULT_URI=qemu:///system

T="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -r "${T}/test.conf" ] && . "${T}/test.conf"
: "${VM:=zbmtest}"

TAG="${1:?usage: shotseq.sh <tag> [count] [interval]}"; N="${2:-16}"; IV="${3:-2}"
D="${T}/shots/${TAG}"; rm -rf "${D}"; mkdir -p "${D}"

virsh destroy "${VM}" >/dev/null 2>&1 || true
sleep 2
T0=$(date +%s.%N)
virsh start "${VM}" >/dev/null
echo "T0 (virsh start) = $(date -Is)"
for i in $(seq 1 "${N}"); do
  sleep "${IV}"
  EL=$(printf '%.1f' "$(echo "$(date +%s.%N) - ${T0}" | bc)")
  F="${D}/$(printf '%02d' "$i")_t${EL}.png"
  virsh screenshot "${VM}" "${F}" >/dev/null 2>&1 && echo "shot ${F} md5=$(md5sum "${F}" | cut -c1-12)"
done
[ -n "${SUDO_USER:-}" ] && chown -R "${SUDO_USER}" "${T}/shots"
exit 0
