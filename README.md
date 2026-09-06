# zbm-clevis

Zero-touch boot of a ZFS-native-encrypted root, without giving up the
passphrase. A machine built this way powers on and comes all the way up on its
own **while it is on a network you control**; carried off that network it stops
at ZFSBootMenu's ordinary passphrase prompt, exactly as it would have anyway,
with dropbear listening so you can unlock it over SSH instead of finding a
monitor. No plaintext key is stored anywhere -- not on the ESP, not in the
initramfs, not on the pool -- and ZFSBootMenu's boot-environment selection,
snapshot rollback and recovery shell all still work, because the image is a
stock ZFSBootMenu with two extra files in it.

**This is not a fork of ZFSBootMenu.** It vendors no ZFSBootMenu source. It is
a configuration overlay for the official `zbm-builder` container: some
`mkinitcpio.conf.d` snippets, three build-time `rc.d` scripts, one 30-line
`load-key.d` hook, and the glue to keep the machine-specific parts out of git.
Upstream does the work; this repository is a client.

**Which Clevis pins are supported.** The hook is pin-agnostic: it runs
`clevis decrypt`, and Clevis dispatches on the pin named in the JWE header to
whichever `clevis-decrypt-<pin>` binary is in the image. The image built here
carries `tang`, `sss` and `null`, so it handles a single Tang server or a
Shamir threshold over several (see *Two sites, either one sufficient*). Tang is
the worked example throughout because network-bound unlock is the property this
design exists for. A `tpm2` pin is possible in principle -- add
`clevis-decrypt-tpm2`, `tpm2-tools` and the TPM kernel modules to the image --
but it is untested here, needs no network, and gives up the "locked off my
network" property that the rest of this README is built around. Tang itself is
not part of this repository; `examples/tang-docker/` shows one way to run it.

---

## How it works

**Tang** ([latchset/tang](https://github.com/latchset/tang)) is a stateless
server that performs one half of a McCallum-Relyea key exchange. To *bind* a
secret, the client generates an ephemeral key, combines it with Tang's
advertised public key, derives an encryption key, encrypts, and then throws the
ephemeral private half away. To *unbind*, the client asks Tang to perform a
single exchange that lets it re-derive the same key. Tang never sees the
secret, never sees the derived key, and stores nothing per client -- so it is
not a place where your passphrase is kept. It is a *thing that must be
reachable*.

**Clevis** ([latchset/clevis](https://github.com/latchset/clevis)) is the
client side. `clevis encrypt tang '{"url":"..."}'` turns your pool passphrase
into a **JWE** -- a compact JSON blob that is useless without a live Tang
server. That JWE is baked into the ZFSBootMenu image at
`/etc/zbm-clevis/clevis.jwe`.

**The hook.** ZFSBootMenu runs every executable in its `load-key.d` stage once
per locked filesystem, just before it would prompt. `hooks/load-key.d/10-clevis-tang.sh`
runs `timeout N clevis decrypt` on the JWE and pipes the result into
`zfs load-key -L prompt "$ZBM_ENCRYPTION_ROOT"`. It always exits 0.
ZFSBootMenu does not care what a hook returns: afterwards it simply re-checks
`keystatus`, and if the key is not loaded it prompts as usual. That
fall-through *is* the design -- every failure path, from "Tang is down" to
"someone stole the laptop", lands on the same prompt.

**Threat model, stated plainly.** The JWE sits on an unencrypted ESP, and it
can be read by anyone with the disk. **JWE + reachability of your Tang server =
your passphrase.** Everything rests on that second term. So:

* Bind Tang to one address on a network you trust, and firewall it there. A
  Tang server on the open internet, or on a guest VLAN, is equivalent to
  writing the passphrase on the ESP in plaintext.
* Physical theft is defended only to the extent that the thief cannot reach
  Tang. A machine stolen from the same LAN as its Tang server unlocks itself.
* **Do not run a mesh VPN inside ZFSBootMenu to reach Tang.** It is the obvious
  next idea and it inverts the whole point: the machine would then unlock
  itself anywhere in the world with an internet connection, which is precisely
  the property "network-bound" was supposed to remove. If you want a second
  site to work, put a second Tang server *at that site* and use an `sss` policy
  (below).
* This buys you nothing against an attacker who is already root on the running
  machine -- the key is loaded and the pool is mounted.

---

## Requirements

* **A build host** with `docker` or `podman`. It does not have to be the target
  machine and usually should not be; the image is built host-generically on
  purpose.
* **A Tang server** the target can reach at boot. `examples/tang-docker/`
  contains a small one; a distribution package plus a socket unit works equally
  well. Back up its key directory.
* **A target with a ZFS-native-encrypted root**, `keyformat=passphrase`, booted
  by ZFSBootMenu from an ESP you can write to, with enough free space for a
  second image (these are around 100 MiB, versus about 62 MiB for stock,
  because the host-generic build keeps all its drivers).
* **The target's hostid**, as a 4-byte `./hostid` file. ZFS stamps a pool with
  the hostid that last imported it; ZFSBootMenu's default import policy copes
  with a mismatch by re-importing under the pool's own hostid, but carrying the
  target's real value avoids that forced re-import and keeps the pool's stamp
  consistent with the OS you boot into. The build host's hostid is almost never
  right, so `build.sh` refuses to build without `./hostid`. See the notes at
  the end of `local.conf.example`.

---

## Quick start

    git clone <this repo> && cd zbm-clevis
    cp local.conf.example local.conf          # then read it and edit it
    cp ~/.ssh/authorized_keys dropbear/root_key
    # write the target's hostid, 4 raw little-endian bytes:
    python3 -c 'import struct,sys; sys.stdout.buffer.write(struct.pack("<I", 0x0abcdef0))' > hostid

**1. Prove the boring half first.**

    ./build.sh dropbear
    test/verify-in-image.sh out/zbm-dropbear.EFI
    sudo test/mkdisk.sh out/zbm-dropbear.EFI && sudo test/mkvm.sh
    sudo test/coldboot.sh t1

You want a DHCP lease and an SSH login on `DROPBEAR_PORT` before Clevis enters
the picture. Install this one on the real machine too, if you like -- remote
unlock is useful on its own.

**2. Enrol.** On the machine that owns the pool, as root:

    scripts/enroll.sh -u http://tang.example:7500 -k /etc/zfs/<pool>.key -o clevis.jwe

It checks the keyfile, verifies the advertisement, encrypts, and proves the
round-trip with `cmp` before you trust it. It never prints key material. Copy
the resulting `clevis.jwe` to the build host and point `JWE_FILE` at it.

**3. Build and test the real thing.**

    ./build.sh clevis
    test/verify-in-image.sh out/zbm-clevis.EFI
    sudo test/swapefi.sh out/zbm-clevis.EFI && sudo test/coldboot.sh t2

Then work through the failure cases in `test/README.md` -- Tang stopped, Tang
blackholed, link down. The failure cases are the point; a zero-touch boot that
cannot fall back is a brick waiting to happen.

**4. Install alongside, never over.**

    ESP=/boot/efi DISK=/dev/nvme0n1 PART=1 \
      sudo scripts/install-image.sh out/zbm-clevis.EFI <sha256-from-build>

This writes a **new** file with its **own** boot entry, restores `BootOrder`
verbatim, and arms a one-shot `BootNext`. If the image misbehaves, power-cycle:
the firmware has already consumed `BootNext` and you are back on the entry you
have always used.

> **Keep the stock ZFSBootMenu image as a separate boot entry, forever.** Give
> it a label you will recognise in the firmware boot menu at 2 a.m. Never
> overwrite it. It is the difference between "select the backup entry and type
> the passphrase" and "find a USB stick".

**5. Promote, only after a verified good boot.**

    sudo scripts/promote-image.sh

It refuses unless `BootCurrent` is the one-shot entry -- that is, unless the
machine is running the image you are about to make the default -- and unless a
byte-identical backup of the outgoing loader still exists elsewhere on the ESP.

---

## Gotchas

Each of these cost real time to find.

* **`autodetect` prunes the drivers you need.** mkinitcpio decides what to
  include by inspecting the running system, which inside the build container is
  the *build* host's hardware; an image built on A and booted on B loses B's
  NIC. The hook is dropped, at the cost of about 40 MiB.
* **klibc `ipconfig` retries DHCP forever.** The stock `net` hook passes no
  timeout, so a dead link hangs the boot instead of reaching the prompt.
  `rc.d/20-net-timeout` patches in `-t ${net_timeout:-NET_TIMEOUT}`; see
  `upstream/` for the fix proposed to mkinitcpio-nfs-utils.
* **`clevis-decrypt-tang` gives `curl` no timeout.** A *refused* connection
  fails in milliseconds, but a *dropped* packet hangs forever -- hence the
  `timeout` wrapper in the hook and the `CLEVIS_TIMEOUT` knob.
* **mkinitcpio's `add_file` resolves symlinks.** Symlinking `/etc/dropbear` to
  the build directory to persist host keys puts every file in the image under
  the build path and leaves `/etc/dropbear` empty -- dropbear then starts with
  no host keys on port 22. `rc.d/10-dropbear` copies, and copies the generated
  keys back out.
* **Some firmware rewrites `BootOrder` when you create an entry.** Lenovo
  silently reordered the whole list on `efibootmgr -c`; both scripts here save
  the order first and restore it verbatim, then verify.
* **Drivers built into the kernel have no `.ko`.** If your NIC's driver is
  `=y` in the container's kernel (common for widely used wired Intel parts --
  `CONFIG_E1000E=y`, for instance), it will never appear in the module list and
  naming it in `EXTRA_MODULES` achieves nothing; it is already there. Do not go
  hunting for a missing module when the real problem is elsewhere.
* **`zfs load-key -L prompt` reads stdin only to the first newline.** So it
  makes no difference whether your keyfile has a trailing newline; the hook and
  the enrolment round-trip both work either way. (`cmp` against the original
  file is still the check that matters.)

---

## Key rotation and re-enrolment

Rotating Tang's keys, or changing the pool passphrase, invalidates the JWE. The
procedure is the same for both, and the worst case is one visit to the console:

1. Rotate on the Tang server (move the old keys to hidden names, i.e. prefix
   the filenames with `.`, so existing clients keep working until they
   re-enrol; then delete them once nothing is bound to them).
2. Re-run `scripts/enroll.sh` on the target to produce a fresh `clevis.jwe`.
3. Copy it to the build host, `./build.sh clevis`, and go round the
   install/test/promote loop again.

If you lose Tang's key directory entirely, nothing is lost except automation:
boot the backup entry, type the passphrase, stand up a new Tang, re-enrol.

### Two sites, either one sufficient

Bind to two Tang servers with a Shamir policy at threshold 1, so each site
works without routing to the other:

    scripts/enroll.sh -s -t 1 \
      -u http://tang-a.example:7500 \
      -u http://tang-b.example:7500 \
      -k /etc/zfs/<pool>.key -o clevis.jwe

`-t 2` instead requires both, which is a stricter and rarely wanted trade.

### Optional: `zbm.hookroot`

ZFSBootMenu can be told to load its hooks from a directory outside the image
(`zbm.hookroot=` on its command line, pointing at a path on the ESP). Putting
the hook and the JWE there instead of baking them in means a key rotation is a
file copy rather than a rebuild-and-reinstall. The trade is that the hook
becomes editable by anyone who can write to the ESP -- which, for a machine
whose threat model already accepts the JWE living there, may well be fine.
This repository bakes them in by default because it keeps the image
self-describing and the ESP untouched between builds.

---

## Testing

See [`test/README.md`](test/README.md) for the harness and the full T1-T6
matrix. Measured in a VM (2 vCPU, virtio, libvirt NAT):

| Scenario | Result |
|---|---|
| Tang reachable | unlocked, no prompt, **+19.4 s** from power-on |
| Tang stopped (refused) | passphrase prompt at **+16-18 s** |
| Tang blackholed (dropped) | passphrase prompt at **+35.7 s** (`CLEVIS_TIMEOUT=15`) |
| Link down | passphrase prompt at **+36-39 s** (`NET_TIMEOUT=20`) |

`test/verify-in-image.sh` also inspects a built image offline -- command line,
hostid, dropbear config, JWE digest, hook body, which clevis binaries made it
in -- without booting anything.

---

## Upstream

Two things here belong in other people's projects, and
[`upstream/README.md`](upstream/README.md) makes the case for both: the
`load-key.d` hook as a ZFSBootMenu `contrib` script, and a `net_timeout` knob
for mkinitcpio-nfs-utils' `net` hook (with a patch in
`upstream/mkinitcpio-nfs-utils-net-timeout.patch`). Until the latter lands,
`rc.d/20-net-timeout` does the same edit at build time.

---

## Publishing safely

Everything machine-specific is `.gitignore`d: `local.conf`, `hostid`,
`dropbear/root_key`, the dropbear host keys, `*.jwe`, `out/`. Before you commit
or push a fork of this, run:

    scripts/check-clean.sh

It scans tracked files for PEM private-key blocks, SSH public keys, compact-JWE
blobs and private/CGNAT IPv4 addresses, and exits non-zero on any hit. Wire it
up as a pre-commit check if you like -- deliberately *not* installed for you:

    ln -s ../../scripts/check-clean.sh .git/hooks/pre-commit

---

## Credits

* **[ZFSBootMenu](https://github.com/zbm-dev/zfsbootmenu)** -- the thing that
  makes any of this possible, and whose `zbm-builder.sh` is vendored here
  unmodified (MIT; see the header in that file).
* **[mkinitcpio-dropbear](https://github.com/ahesford/mkinitcpio-dropbear)** by
  ahesford -- the dropbear initramfs hook.
* **mkinitcpio-nfs-utils** -- the `net` hook and klibc `ipconfig`.
* **[clevis](https://github.com/latchset/clevis)** and
  **[tang](https://github.com/latchset/tang)** by latchset -- the whole
  network-bound encryption idea, and the McCallum-Relyea exchange behind it.

MIT licensed. See [`LICENSE`](LICENSE).
