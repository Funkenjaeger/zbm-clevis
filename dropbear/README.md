# dropbear/

Everything in this directory except this file is machine-private and is
excluded by `.gitignore`. Nothing here should ever be committed.

## What you must put here

### `root_key` (required)

Your `authorized_keys` for the pre-boot root shell. One public key per line,
standard OpenSSH format. Dropbear inside ZFSBootMenu accepts key
authentication only -- there is no password on that root account, so this file
is the entire access control list for remote unlock.

    cp ~/.ssh/authorized_keys dropbear/root_key

Keep it to the keys that actually need to unlock this machine. A key in here
can do anything a ZFSBootMenu console can do: import pools, roll back
snapshots, chroot into a boot environment.

`build.sh` refuses to build without it.

## What appears here on its own

### `dropbear_{rsa,ecdsa,ed25519}_host_key` (+ `.pub`)

Generated inside the build container on the first build that finds them
missing, and copied back out here so that **every later image keeps the same
host key fingerprints**. That matters: without it, each rebuild would look
like a man-in-the-middle to your SSH client, and you would get into the habit
of clearing `known_hosts` before an unlock -- exactly the habit that makes the
warning useless.

These are private keys. They are `.gitignore`d. If you want reproducible
fingerprints across machines that build this image, generate them once with
`dropbearkey` and copy them in; do not put them in git either way.

Record the fingerprints the build prints (`HOSTKEY ed25519: SHA256:...`) and
pin them in your client's `known_hosts` under the bracketed host-and-port form
that OpenSSH uses for non-default ports, `[host.example]:222`, followed by the
key type and the key itself. `ssh-keyscan -p 222 host.example` will write that
line for you once the machine is sitting at the ZFSBootMenu prompt -- compare
the fingerprint against what the build printed before you trust it.

### `dropbear.conf`

Not tracked and not yours to write: `rc.d/10-dropbear` generates it inside the
container from `DROPBEAR_PORT` in `local.conf`, so the port lives in exactly
one place.
