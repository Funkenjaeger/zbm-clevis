#!/usr/bin/env bash
# Refuse to let secrets or private network identity reach a public repository.
#
# Scans every file git currently tracks (plus anything staged) for:
#   * PEM private key blocks
#   * SSH public keys (they identify people and machines)
#   * compact-JWE payloads (a serialised Clevis blob starts "eyJ")
#   * RFC1918 addresses, and CGNAT / tailnet space (the 100.64-127 range)
#
# Suggested use -- as a pre-commit check you run yourself. This repository
# deliberately does NOT install a git hook for you; if you want one:
#
#     ln -s ../../scripts/check-clean.sh .git/hooks/pre-commit
#
# Exits 0 when clean, 1 on any hit.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(readlink -f "$0")")")" || exit 1

SELF="scripts/check-clean.sh"

if git rev-parse --git-dir >/dev/null 2>&1; then
  mapfile -d '' FILES < <(git ls-files -z --cached --others --exclude-standard)
else
  echo "warning: not a git repository; scanning all files except .git" >&2
  mapfile -d '' FILES < <(find . -type f -not -path './.git/*' -not -path './out/*' -not -path './.stage/*' -print0)
fi

rc=0
hit() {
  rc=1
  printf 'DIRTY [%s] %s\n' "$1" "$2"
}

# Patterns. Kept as separate greps so the failure message names the offence.
# shellcheck disable=SC2016
PEM='-----BEGIN [A-Z ]*PRIVATE KEY-----'
SSHPUB='\bssh-(ed25519|rsa|dss)\b|\becdsa-sha2-nistp[0-9]+\b'
JWE='(^|[^A-Za-z0-9])eyJ[A-Za-z0-9_-]{16,}'
IPV4PRIV='(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9.]|$)'

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  # This script necessarily contains every pattern it looks for.
  [ "${f#./}" = "$SELF" ] && continue
  # Skip anything that is not text.
  if ! grep -Iq . "$f" 2>/dev/null; then continue; fi

  grep -qE "$PEM"      "$f" 2>/dev/null && hit "private key" "$f"
  grep -qE "$SSHPUB"   "$f" 2>/dev/null && hit "ssh public key" "$f"
  grep -qE "$JWE"      "$f" 2>/dev/null && hit "JWE/base64url blob" "$f"
  grep -qE "$IPV4PRIV" "$f" 2>/dev/null && hit "private/CGNAT IPv4 address" "$f"
done

# Files that must never be tracked at all, whatever their content.
if git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      dropbear/*host_key*|dropbear/root_key|*.jwe|hostid|local.conf|JWE_SOURCE)
        hit "must not be tracked" "$f" ;;
    esac
  done < <(git ls-files)
fi

if [ "$rc" -eq 0 ]; then
  echo "check-clean: OK (${#FILES[@]} files scanned)"
else
  echo "check-clean: FAILED -- do not commit" >&2
fi
exit "$rc"
