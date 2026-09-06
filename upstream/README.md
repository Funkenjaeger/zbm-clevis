# Upstream contributions

Two pieces of this repository are not really ours: they are papering over gaps
in projects we are only a consumer of. Both are small, both are self-contained,
and both belong upstream rather than in a config overlay that every user of the
same combination would have to rediscover.

---

## 1. ZFSBootMenu: a Clevis/Tang `load-key.d` contrib hook

**File:** `../hooks/load-key.d/10-clevis-tang.sh` (30 lines of shell, MIT)

**Proposal:** add it to ZFSBootMenu's `contrib/` directory, where it can be
enabled with a one-line `zbm.hookroot=` or by copying it into `hooks/`.

**Rationale.** Network-bound unlock is a recurring request on the ZFSBootMenu
tracker, and the project has met it halfway twice already:

* In 2023, discussion on [zbm-dev/zfsbootmenu#449][pr449] ended with a
  maintainer explicitly inviting a `contrib` script for the Clevis case rather
  than building Clevis support into ZFSBootMenu itself -- the right call, since
  Clevis pulls in `jose`, `curl` and a pin's worth of policy that most users do
  not want in a 60 MiB rescue image.
* ZFSBootMenu later grew the `load-key.d` hook stage with the
  `ZBM_ENCRYPTION_ROOT` / `ZBM_LOCKED_FS` contract, which is exactly the
  interface such a script needs. Nothing else is required: the hook succeeds
  quietly or exits 0 and ZFSBootMenu falls through to its own prompt.

So the remaining gap is purely one of discovery. Everyone who wants this today
writes the same six lines, and gets the same two details wrong:

1. loading the key on `ZBM_LOCKED_FS` rather than `ZBM_ENCRYPTION_ROOT`, which
   silently fails on any pool where the locked dataset inherits its key;
2. calling `clevis decrypt` without a `timeout`, which turns a blackholed Tang
   server into an indefinite hang instead of a fallback to the prompt (see
   below -- `clevis-decrypt-tang` invokes `curl` with no timeout of its own).

A contrib script fixes both by example. It needs no ZFSBootMenu code changes,
adds no dependencies to the default image, and can carry the packaging note
(`BINARIES+=(clevis clevis-decrypt clevis-decrypt-tang jose curl timeout)`)
that is the other half of the puzzle.

[pr449]: https://github.com/zbm-dev/zfsbootmenu/pull/449

---

## 2. mkinitcpio-nfs-utils: a `net_timeout` knob for the `net` hook

**File:** `mkinitcpio-nfs-utils-net-timeout.patch`

**Problem.** The `net` runtime hook calls klibc's `ipconfig` with no `-t`:

    ipconfig "ip=${ip}"

`ipconfig` with no timeout retries DHCP forever. Verified: with no DHCP server
on the wire it was still trying after 75 seconds and showed no sign of
stopping. Any initramfs that uses this hook for something *optional* -- remote
unlock, network-bound decryption, a netconsole -- therefore hangs the boot on a
dead link instead of degrading to whatever the local fallback is. For a
ZFSBootMenu image that fallback is a passphrase prompt at the console, so the
failure mode is "the machine appears bricked" rather than "type your
passphrase".

**Patch.** Honour a `net_timeout=<seconds>` kernel command-line parameter and
pass it through as `ipconfig -t`. When it is unset the behaviour is exactly
what it is today, so nothing existing changes. The parameter name follows the
hook's existing convention of taking its input straight from the command line
(`ip=`, `nfsroot=`, `BOOTIF=`).

The patch is a unified diff against `/usr/lib/initcpio/hooks/net` as shipped in
the `mkinitcpio-nfs-utils` package inside `ghcr.io/zbm-dev/zbm-builder:latest`.
Regenerate the base file with:

    docker run --rm --entrypoint sh ghcr.io/zbm-dev/zbm-builder:latest -c \
      'xbps-install -Suy xbps >/dev/null 2>&1;
       xbps-install -Sy mkinitcpio-nfs-utils >/dev/null 2>&1;
       cat /usr/lib/initcpio/hooks/net'

**Until it lands**, `../rc.d/20-net-timeout` does the same edit with `sed`
inside the build container, defaulting to `NET_TIMEOUT` from `local.conf`. The
`sed` writes `-t "${net_timeout:-<NET_TIMEOUT>}"`, so an image built today
already accepts a `net_timeout=` override on the command line and will keep
working unchanged if the upstream patch is applied.
