#!/bin/bash
# ZFSBootMenu load-key hook: try network-bound unlock via Clevis+Tang, and fall
# through to ZFSBootMenu's own passphrase prompt on any failure.
#
# ---------------------------------------------------------------------------
# How ZFSBootMenu calls this
#
# Scripts in the load-key.d stage run once per locked filesystem, immediately
# before ZFSBootMenu would prompt for a passphrase. Two variables are exported
# into the environment (see zfsbootmenu(7), "User Hooks"):
#
#   ZBM_LOCKED_FS        the filesystem ZFSBootMenu wants to unlock
#   ZBM_ENCRYPTION_ROOT  the dataset that actually holds the key -- this is the
#                        one to pass to `zfs load-key`, since a child inherits
#                        its encryption root's key
#
# Fall-through semantics: ZFSBootMenu does not care what this script returns.
# After every load-key.d hook has run it simply re-checks `keystatus`. If the
# key is loaded, boot continues untouched; if not, the normal prompt appears.
# So the correct behaviour on ANY error is a quiet `exit 0` -- never a
# non-zero exit and never a message that could be mistaken for a prompt. A
# machine off its home network must still be unlockable by a human at the
# console (or over dropbear), and that path is ZFSBootMenu's, not ours.
# ---------------------------------------------------------------------------

jwe=/etc/zbm-clevis/clevis.jwe
[ -r "$jwe" ] || exit 0
[ -n "$ZBM_ENCRYPTION_ROOT" ] || exit 0

# Bound the attempt. clevis-decrypt-tang calls curl with no timeout of its own,
# so a Tang address that silently drops packets would hang here forever.
# The value is baked into the image by rc.d/30-clevis from CLEVIS_TIMEOUT.
t=15
[ -r /etc/zbm-clevis/timeout ] && read -r t < /etc/zbm-clevis/timeout
case "$t" in ''|*[!0-9]*) t=15 ;; esac

# `zfs load-key -L prompt` reads the key from stdin up to the first newline,
# so a trailing newline in the original keyfile is irrelevant either way.
if pass="$(timeout "$t" clevis decrypt < "$jwe" 2>/dev/null)" && [ -n "$pass" ]; then
  printf '%s\n' "$pass" | zfs load-key -L prompt "$ZBM_ENCRYPTION_ROOT" >/dev/null 2>&1
fi

exit 0
