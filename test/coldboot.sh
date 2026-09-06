#!/bin/bash
# Cold-boot the test VM and time two things from power-on:
#   * when it gets a DHCP lease (the `net` hook worked)
#   * when the test pool's keystatus becomes `available` (the Clevis hook
#     worked) -- polled over dropbear, so it also proves remote unlock access
#
# Run with sudo.   sudo test/coldboot.sh <tag> [max_seconds]
set -u
export LIBVIRT_DEFAULT_URI=qemu:///system

T="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -r "${T}/test.conf" ] && . "${T}/test.conf"
: "${VM:=zbmtest}"
: "${POOL:=zbmtest}"
: "${DROPBEAR_PORT:=222}"
: "${SSH_KEY:=${SUDO_USER:+/home/${SUDO_USER}}/.ssh/id_ed25519}"

TAG="${1:?usage: coldboot.sh <tag> [max_seconds]}"; MAX="${2:-120}"
SHOTS="${T}/shots"; mkdir -p "${SHOTS}"

[ -r "${SSH_KEY}" ] || { echo "FAIL: SSH_KEY=${SSH_KEY} not readable; set it in test.conf"; exit 1; }
SSHOPT="-p${DROPBEAR_PORT} -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=3"

virsh destroy "${VM}" >/dev/null 2>&1 || true
sleep 2
T0=$(date +%s.%N)
virsh start "${VM}" >/dev/null
echo "T0 (virsh start) = $(date -Is)"

IP=""; LEASE_T=""; KEY_T=""
while :; do
  EL=$(echo "$(date +%s.%N) - ${T0}" | bc)
  [ "$(echo "${EL} > ${MAX}" | bc)" = "1" ] && break
  if [ -z "${IP}" ]; then
    IP=$(virsh domifaddr "${VM}" --source lease 2>/dev/null | awk '/ipv4/{split($4,a,"/"); print a[1]}')
    [ -n "${IP}" ] && { LEASE_T="${EL}"; echo "lease at +${EL}s"; }
  fi
  if [ -n "${IP}" ]; then
    # shellcheck disable=SC2086
    KS=$(timeout 6 ssh ${SSHOPT} "root@${IP}" "zfs get -H -o value keystatus ${POOL}" 2>/dev/null)
    if [ -n "${KS}" ]; then
      echo "keystatus=${KS} at +${EL}s"
      [ "${KS}" = "available" ] && { KEY_T="${EL}"; break; }
    fi
  fi
  sleep 2
done

echo "SUMMARY tag=${TAG} lease_at=${LEASE_T:-none} keystatus_available_at=${KEY_T:-never}"
virsh screenshot "${VM}" "${SHOTS}/${TAG}.png" 2>&1
[ -n "${SUDO_USER:-}" ] && chown -R "${SUDO_USER}" "${SHOTS}"
exit 0
