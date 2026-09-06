# Test harness

Everything here runs against a **throwaway** libvirt VM with a **throwaway**
encrypted pool. Nothing touches a real pool, a real ESP, or the machine you
are actually trying to fix. Test the image here before it goes anywhere near a
box you care about -- an image that cannot import your pool is a trip to the
console with a keyboard, and an image that hangs on a dead network is worse.

## Setup

    cp test/test.conf.example test/test.conf     # edit IMG, VM, TANG_URL, ...

Requirements on the test host: `libvirt` + `virt-install`, OVMF firmware, ZFS
(to create the test pool), `sgdisk`, `losetup`, and an SSH key whose public
half is in `dropbear/root_key`. Most of the scripts need `sudo` because they
loop-mount the disk image and talk to `qemu:///system`.

    sudo test/mkdisk.sh out/zbm-dropbear.EFI   # 4 GiB disk: ESP + test pool
    sudo test/mkvm.sh                          # define and start the VM
    sudo test/coldboot.sh t1                   # time a cold boot

To retest with a different image without rebuilding the pool:

    sudo test/swapefi.sh out/zbm-clevis.EFI
    sudo test/coldboot.sh t2

`test/mkvm.sh` will start the libvirt `default` network if it is inactive.
If it was inactive deliberately, stop it again when you are done.

## Offline inspection

`test/verify-in-image.sh` never boots anything. It pulls the initramfs back out
of the PE binary and shows you what is really in it -- the command line, the
hostid, `dropbear.conf`, the authorized-key count, the JWE's size and digest,
which `clevis-decrypt-*` binaries made it in, the hook body, and the patched
`ipconfig` line:

    test/verify-in-image.sh out/zbm-clevis.EFI

Run this first, every time. It catches most mistakes in seconds, and it is the
only check that works without a hypervisor.

## The test matrix

The timings below were measured on one host (a modern desktop CPU, VM with
2 vCPU / 2 GiB, virtio disk and NIC, libvirt NAT network). Yours will differ in
the constant term; what matters is the *shape* -- unlock in well under half a
minute, and every failure mode reaching a usable prompt rather than hanging.

| | Scenario | Expect | Measured |
|---|---|---|---|
| **T1** | `dropbear` image, network up | DHCP lease, SSH on `DROPBEAR_PORT`, manual `zfs load-key` works | lease and SSH within a few seconds of ZBM starting |
| **T2** | `clevis` image, Tang reachable | zero-touch unlock, no prompt ever shown | `keystatus=available` at **+19.4 s** from power-on |
| **T3** | `clevis` image, Tang **stopped** (connection refused) | fast fall-through to the passphrase prompt | prompt at **+16-18 s** |
| **T4** | `clevis` image, Tang **blackholed** (packets dropped) | fall-through bounded by `CLEVIS_TIMEOUT` | prompt at **+35.7 s** with `CLEVIS_TIMEOUT=15` |
| **T5** | link down (no DHCP at all) | fall-through bounded by `NET_TIMEOUT` | prompt at **+36-39 s** with `NET_TIMEOUT=20` |
| **T6** | hostid and pool import | pool visible, correct hostid, real JWE round-trips | `hostid` matches; decrypt digest matches the keyfile |

Note the asymmetry between T3 and T4, because it is the whole reason
`CLEVIS_TIMEOUT` exists: a **refused** connection fails in about 0.15 s, so a
Tang server that is merely down costs you nothing. A **dropped** packet gives
`curl` nothing to react to, and `clevis-decrypt-tang` sets no timeout of its
own -- without the `timeout` wrapper in the hook, T4 would hang forever.

### T1 -- dropbear image

    sudo test/mkdisk.sh out/zbm-dropbear.EFI
    sudo test/mkvm.sh
    sudo test/coldboot.sh t1

Then, from the test host (`<vm-ip>` comes from `virsh domifaddr`):

    ssh -p 222 root@<vm-ip>

and inside that shell:

    hostid; cat /proc/cmdline; ip -4 -o addr show
    zfs get -H -o value keystatus <pool>
    printf '%s\n' '<test-passphrase>' | zfs load-key -L prompt <pool>
    zfs get -H -o value keystatus <pool>          # -> available
    zfs unload-key <pool>                          # leave it clean

Piping the passphrase in is not laziness: it exercises exactly the mechanism
the Clevis hook uses, so if this fails the hook was never going to work.

### T2 -- zero touch

    sudo test/swapefi.sh out/zbm-clevis.EFI
    sudo test/coldboot.sh t2

`coldboot.sh` prints `keystatus_available_at`. A pass is: the pool unlocks and
the VM proceeds without any prompt appearing on the console screenshot.

### T3 -- Tang refused

Stop the Tang service (`docker stop tang`, or stop the unit), confirm the
advertisement is gone (`curl -sf ${TANG_URL}/adv` fails), then:

    sudo test/shotseq.sh t3 16 2

`shotseq.sh` rather than `coldboot.sh`, because dropbear logs each SSH
connection to the ZFSBootMenu console and polling would scroll the prompt off
screen. Look through `test/shots/t3/` for the first frame showing the
passphrase prompt; its filename carries the elapsed time. Restart Tang
afterwards.

### T4 -- Tang blackholed

The point is a *dropped* packet, not a refused one. On the Tang host, insert a
DROP rule for the VM network in front of the Tang port:

    sudo iptables -I INPUT -s <vm-subnet> -p tcp --dport 7500 -j DROP
    # ... run the test ...
    sudo iptables -D INPUT -s <vm-subnet> -p tcp --dport 7500 -j DROP

Then `sudo test/shotseq.sh t4 20 2`. The prompt must appear a little after
`CLEVIS_TIMEOUT` seconds past the point where the network came up. If it never
appears, the `timeout` wrapper in the hook is not doing its job -- check that
`timeout` actually made it into the image (`verify-in-image.sh` lists it).

### T5 -- link down

Detach the VM's NIC, or take the libvirt bridge down, so `ipconfig` gets no
answer at all:

    sudo virsh domif-setlink zbmtest <mac> down
    sudo test/shotseq.sh t5 24 2
    sudo virsh domif-setlink zbmtest <mac> up

The prompt should appear a few seconds after `NET_TIMEOUT`. If it never does,
`rc.d/20-net-timeout` did not patch the `net` hook -- `verify-in-image.sh`
prints the patched `ipconfig` line, check it says `-t`.

### T6 -- hostid, import, and the real JWE

From the dropbear shell in the running ZFSBootMenu:

    hostid
    od -An -tx1 /etc/hostid
    cat /proc/cmdline
    zpool import                    # your pool should be listed
    zfs get -H -o value keystatus <pool>

To prove a **real** JWE decrypts to the right thing without ever printing the
passphrase, compare digests only:

    timeout 15 clevis decrypt < /etc/zbm-clevis/clevis.jwe > /tmp/p
    echo "rc=$?  bytes=$(wc -c < /tmp/p)  sha256=$(sha256sum < /tmp/p)"
    rm -f /tmp/p

and check that digest against `sha256sum < /etc/zfs/<pool>.key` on the real
machine. Never `cat` either one.

## Cleaning up

    sudo virsh destroy zbmtest; sudo virsh undefine zbmtest --nvram
    sudo rm -f /var/lib/libvirt/images/zbmtest.img
    rm -f test/test.pw; rm -rf test/shots

`test/*.img`, `test/*.pw`, `test/test.conf` and `test/shots/` are all
`.gitignore`d, but the disk image usually lives under libvirt's directory
rather than in the repository -- remove it by hand.
