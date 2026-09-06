#!/bin/bash
# Build a ZFSBootMenu EFI image from this overlay, using the official
# ZFSBootMenu build container. This is NOT a fork of ZFSBootMenu: nothing here
# patches or vendors ZBM source, it only feeds configuration to zbm-builder.sh.
#
#   ./build.sh dropbear   -> out/zbm-dropbear.EFI   net + dropbear, no Clevis
#   ./build.sh clevis     -> out/zbm-clevis.EFI     the above + Clevis/Tang
#
# The two variants exist so you can prove the network and the remote-unlock
# path work before you bake an encrypted copy of your pool passphrase into an
# image. Build dropbear first, boot it, confirm you get a DHCP lease and can
# ssh in; only then build clevis.
#
# Everything is assembled into a throwaway staging directory (.stage/) which is
# what actually gets bind-mounted into the container. Tracked files are never
# modified by a build.
set -u

B="$(cd "$(dirname "$0")" && pwd)"
STAGE="${B}/.stage"
V="${1:-}"

case "${V}" in
  dropbear) OUTNAME="zbm-dropbear.EFI"; WANT_CLEVIS=0 ;;
  clevis)   OUTNAME="zbm-clevis.EFI";   WANT_CLEVIS=1 ;;
  *) echo "usage: $0 {dropbear|clevis}" >&2; exit 1 ;;
esac

# ---- configuration ---------------------------------------------------------
if [ ! -r "${B}/local.conf" ]; then
  echo "FAIL: ${B}/local.conf not found. Start from the example:" >&2
  echo "          cp local.conf.example local.conf" >&2
  exit 1
fi
# shellcheck disable=SC1091
. "${B}/local.conf"

: "${JWE_FILE:=clevis.jwe}"
: "${CONTAINER_RUNTIME:=}"
if [ -z "${CONTAINER_RUNTIME}" ]; then
  if command -v podman >/dev/null 2>&1; then CONTAINER_RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then CONTAINER_RUNTIME=docker
  else echo "FAIL: neither podman nor docker found" >&2; exit 1; fi
fi

# ---- required private inputs ----------------------------------------------
if [ ! -s "${B}/dropbear/root_key" ]; then
  echo "FAIL: dropbear/root_key missing or empty." >&2
  echo "      Put the public keys allowed to unlock this machine there, one" >&2
  echo "      per line (see dropbear/README.md)." >&2
  exit 1
fi

# zbm-builder.sh would silently copy the BUILD host's /etc/hostid if ./hostid
# is absent. That is almost never what you want: the image must carry the
# TARGET's hostid or ZFS will refuse to import the pool. Refuse instead.
if [ ! -s "${B}/hostid" ]; then
  echo "FAIL: ./hostid missing. The image must carry the target machine's" >&2
  echo "      hostid or ZFS will not import its pool." >&2
  echo "      See the ./hostid notes at the bottom of local.conf.example." >&2
  exit 1
fi
if [ "$(stat -c %s "${B}/hostid")" -ne 4 ]; then
  echo "FAIL: ./hostid must be exactly 4 bytes (raw little-endian), got $(stat -c %s "${B}/hostid")" >&2
  exit 1
fi

JWE_PATH=""
if [ "${WANT_CLEVIS}" -eq 1 ]; then
  case "${JWE_FILE}" in
    /*) JWE_PATH="${JWE_FILE}" ;;
    *)  JWE_PATH="${B}/${JWE_FILE}" ;;
  esac
  if [ ! -s "${JWE_PATH}" ]; then
    echo "FAIL: JWE_FILE='${JWE_FILE}' (-> ${JWE_PATH}) is missing or empty." >&2
    echo "      Produce it on the machine that owns the pool with:" >&2
    echo "          scripts/enroll.sh -u <tang-url> -k <keyfile> -o clevis.jwe" >&2
    echo "      then copy it here. Refusing to build a 'clevis' image without it." >&2
    exit 1
  fi
fi

# ---- assemble the staging directory ---------------------------------------
rm -rf "${STAGE}"
mkdir -p "${STAGE}/out" "${STAGE}/rc.d" "${STAGE}/mkinitcpio.conf.d" "${STAGE}/dropbear"

cp "${B}/config.yaml"      "${STAGE}/config.yaml"
cp "${B}/zbm-builder.conf" "${STAGE}/zbm-builder.conf"
cp "${B}/local.conf"       "${STAGE}/local.conf"
cp "${B}/hostid"           "${STAGE}/hostid"

cp "${B}/rc.d/10-dropbear"    "${STAGE}/rc.d/"
cp "${B}/rc.d/20-net-timeout" "${STAGE}/rc.d/"
cp "${B}/mkinitcpio.conf.d/00-generic.conf"      "${STAGE}/mkinitcpio.conf.d/"
cp "${B}/mkinitcpio.conf.d/10-net-dropbear.conf" "${STAGE}/mkinitcpio.conf.d/"

# dropbear/README.md is documentation, not something to bake into the image.
for f in "${B}"/dropbear/*; do
  [ -f "${f}" ] || continue
  case "${f##*/}" in README.md) continue ;; esac
  cp "${f}" "${STAGE}/dropbear/"
done

if [ "${WANT_CLEVIS}" -eq 1 ]; then
  cp "${B}/rc.d/30-clevis"                  "${STAGE}/rc.d/"
  cp "${B}/mkinitcpio.conf.d/20-clevis.conf" "${STAGE}/mkinitcpio.conf.d/"
  mkdir -p "${STAGE}/hooks/load-key.d"
  cp "${B}/hooks/load-key.d/10-clevis-tang.sh" "${STAGE}/hooks/load-key.d/"
  chmod 755 "${STAGE}/hooks/load-key.d/10-clevis-tang.sh"
  cp "${JWE_PATH}" "${STAGE}/clevis.jwe"
  chmod 600 "${STAGE}/clevis.jwe"
fi

chmod 755 "${STAGE}"/rc.d/*

# ---- build -----------------------------------------------------------------
echo "=== building variant '${V}' -> out/${OUTNAME} at $(date -Is) ==="
echo "=== runtime=${CONTAINER_RUNTIME} stage=${STAGE} ==="
"${B}/zbm-builder.sh" -b "${STAGE}" -d "${CONTAINER_RUNTIME}"
rc=$?
if [ "${rc}" -ne 0 ]; then echo "FAIL: zbm-builder.sh exited ${rc}" >&2; exit "${rc}"; fi

# With a rootful docker daemon the container runs as root, so everything it
# wrote into the staging directory (the image, any freshly generated dropbear
# host keys) is owned by root and mode 0600 -- unreadable to the user who
# started the build. Rootless podman maps it back for us; docker does not.
if [ -e "${STAGE}/out/zfsbootmenu.EFI" ] && [ ! -O "${STAGE}/out/zfsbootmenu.EFI" ]; then
  "${CONTAINER_RUNTIME}" run --rm -v "${STAGE}:/build" \
    --entrypoint /bin/sh "${BUILD_IMG:-ghcr.io/zbm-dev/zbm-builder:latest}" \
    -c "chown -R $(id -u):$(id -g) /build" \
    || echo "WARN: could not hand build products back to $(id -un); they are root-owned" >&2
fi

# Host keys generated inside the container land in the staging directory; keep
# them so the fingerprints stay stable across rebuilds.
for t in rsa ecdsa ed25519; do
  k="${STAGE}/dropbear/dropbear_${t}_host_key"
  [ -s "${k}" ] && cp -p "${k}" "${B}/dropbear/dropbear_${t}_host_key"
done

if [ ! -s "${STAGE}/out/zfsbootmenu.EFI" ]; then
  echo "FAIL: ${STAGE}/out/zfsbootmenu.EFI was not produced" >&2
  exit 1
fi

mkdir -p "${B}/out"
mv "${STAGE}/out/zfsbootmenu.EFI" "${B}/out/${OUTNAME}"
rm -f "${STAGE}/out/zfsbootmenu-backup.EFI"

echo "OK: out/${OUTNAME}"
echo "    bytes  : $(stat -c %s "${B}/out/${OUTNAME}")"
echo "    sha256 : $(sha256sum "${B}/out/${OUTNAME}" | cut -d' ' -f1)"
echo "Next: test it (see test/README.md), then install it alongside -- never"
echo "over -- your existing ZFSBootMenu image with scripts/install-image.sh."
