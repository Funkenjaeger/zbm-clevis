#!/usr/bin/env bash
# Bind a ZFS pool passphrase to one or two Tang servers, producing the Clevis
# JWE that build.sh bakes into the ZFSBootMenu image.
#
# Run this AS ROOT ON THE MACHINE THAT OWNS THE POOL -- the keyfile never has
# to leave it, and the JWE that comes out is not secret in the same way (it is
# useless to anyone who cannot reach Tang).
#
#   scripts/enroll.sh -u http://tang.example:7500 -k /etc/zfs/rpool.key -o clevis.jwe
#
# Two Tang servers, either one sufficient (Shamir t=1 of n=2) -- the pattern
# for a second site, so neither location depends on routing to the other:
#
#   scripts/enroll.sh -s -u http://tang-a.example:7500 -u http://tang-b.example:7500 \
#                     -k /etc/zfs/rpool.key -o clevis.jwe
#
# SECRET HANDLING: the keyfile IS the pool passphrase. This script only ever
# feeds it into `clevis encrypt`, `cmp`, `wc -c` and `tail -c1 | wc -l`.
# Nothing here prints it or anything derived from it, and clevis' stderr is
# redirected to a log the script never reads back. Keep it that way if you
# edit this file.
set -uo pipefail

usage() {
  cat >&2 <<EOF
usage: $0 -u <tang-url> [-u <tang-url> -s] -k <keyfile> -o <out.jwe> [-t <n>]

  -u URL   Tang advertisement URL, e.g. http://tang.example:7500
           Give it twice together with -s for a Shamir policy.
  -s       Use the sss pin with threshold 1 over the given URLs: any single
           Tang can unlock. (Without -s exactly one -u is allowed.)
  -t N     Threshold for -s (default 1). N=2 with two URLs means BOTH must be
           reachable -- that is a different, stricter trade-off.
  -k FILE  The keyfile whose content is the pool passphrase.
  -o FILE  Where to write the JWE.
  -y       Trust the advertisement without asking (non-interactive). Default.
  -A       Do NOT pass -y: clevis will print the Tang key thumbprint and ask
           you to confirm it. Use this the first time you enrol against a new
           Tang server, then verify the thumbprint out of band.
EOF
  exit 1
}

URLS=(); USE_SSS=0; THRESH=1; KEYFILE=""; OUT=""; ADVTRUST="-y"
while getopts "u:sk:o:t:yAh" o; do
  case "$o" in
    u) URLS+=( "$OPTARG" ) ;;
    s) USE_SSS=1 ;;
    t) THRESH="$OPTARG" ;;
    k) KEYFILE="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    y) ADVTRUST="-y" ;;
    A) ADVTRUST="" ;;
    *) usage ;;
  esac
done

[ -n "$KEYFILE" ] && [ -n "$OUT" ] && [ "${#URLS[@]}" -ge 1 ] || usage
if [ "$USE_SSS" -eq 0 ] && [ "${#URLS[@]}" -ne 1 ]; then
  echo "FAIL: more than one -u given without -s" >&2; exit 1
fi
case "$THRESH" in ''|*[!0-9]*) echo "FAIL: -t must be a positive integer" >&2; exit 1 ;; esac
if [ "$USE_SSS" -eq 1 ] && [ "$THRESH" -gt "${#URLS[@]}" ]; then
  echo "FAIL: threshold $THRESH exceeds the ${#URLS[@]} Tang server(s) given" >&2; exit 1
fi

command -v clevis >/dev/null 2>&1 || { echo "FAIL: clevis not installed" >&2; exit 1; }

ERRLOG="$(mktemp)"
chmod 600 "$ERRLOG"
cleanup() { rm -f "$ERRLOG"; }
trap cleanup EXIT

echo "=== 1. keyfile assertions ==="
[ -f "$KEYFILE" ] || { echo "FAIL: $KEYFILE missing"; exit 1; }
[ -s "$KEYFILE" ] || { echo "FAIL: $KEYFILE is empty"; exit 1; }
echo "OK: $KEYFILE exists"
echo "keyfile_bytes=$(wc -c < "$KEYFILE")"
if [ "$(tail -c1 "$KEYFILE" | wc -l)" -eq 1 ]; then
  echo "keyfile_trailing_newline=yes"
else
  echo "keyfile_trailing_newline=no"
fi
# Either is fine: `zfs load-key -L prompt` reads stdin only up to the first
# newline, and the load-key hook pipes exactly one line.
stat -c 'keyfile_mode=%a owner=%U:%G' "$KEYFILE"

echo
echo "=== 2. Tang reachability ==="
for u in "${URLS[@]}"; do
  code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${u%/}/adv" 2>/dev/null)"
  echo "adv ${u} -> HTTP ${code:-none}"
  [ "$code" = "200" ] || { echo "FAIL: no usable advertisement from ${u}"; exit 1; }
done

echo
echo "=== 3. build the policy ==="
if [ "$USE_SSS" -eq 1 ]; then
  PIN=sss
  inner=""
  for u in "${URLS[@]}"; do
    [ -n "$inner" ] && inner="${inner},"
    inner="${inner}{\"url\":\"${u}\"}"
  done
  CFG="{\"t\":${THRESH},\"pins\":{\"tang\":[${inner}]}}"
else
  PIN=tang
  CFG="{\"url\":\"${URLS[0]}\"}"
fi
echo "pin=${PIN}"
echo "cfg=${CFG}"

echo
echo "=== 4. clevis encrypt ==="
# shellcheck disable=SC2086
if clevis encrypt "$PIN" "$CFG" $ADVTRUST < "$KEYFILE" > "$OUT" 2> "$ERRLOG"; then
  echo "ENCRYPT_OK"
else
  echo "ENCRYPT_FAIL (clevis stderr was $(stat -c%s "$ERRLOG") bytes; not shown, it can echo input on some failures)"
  rm -f "$OUT"
  exit 1
fi
chmod 600 "$OUT"
[ -s "$OUT" ] || { echo "FAIL: $OUT is empty"; exit 1; }

echo
echo "=== 5. round trip ==="
# The only correctness test that matters: what comes back must be byte-for-byte
# the keyfile. cmp is silent about content.
if clevis decrypt < "$OUT" 2>> "$ERRLOG" | cmp -s - "$KEYFILE"; then
  echo "ROUNDTRIP_OK"
else
  echo "ROUNDTRIP_FAIL -- do NOT build an image with this JWE"
  exit 1
fi

echo
echo "=== 6. JWE facts (safe to record) ==="
echo "jwe_bytes=$(wc -c < "$OUT")"
echo "jwe_sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
stat -c 'jwe_mode=%a owner=%U:%G' "$OUT"
echo
echo "DONE. Copy $OUT to the build host as the file named by JWE_FILE in"
echo "local.conf, then run ./build.sh clevis."
