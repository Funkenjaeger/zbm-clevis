# Tang server (McCallum-Relyea key escrow) for network-bound ZFS unlock.
#
# Debian trixie ships tang 15, whose tangd binary supports standalone listen
# mode (-l), so no systemd socket activator or inetd wrapper is needed inside
# the container. The Debian package installs the binaries into /usr/libexec
# from tang-common; /usr/libexec is not on PATH, so the full path is used.
#
# Keys live in /db (bind-mounted). tangd generates a fresh signing +
# key-exchange pair there on first run if the directory is empty. Tang never
# holds the client's secret -- losing /db only means clients bound to those
# keys can no longer unlock, so /db is what gets backed up.
FROM debian:trixie-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tang \
 && rm -rf /var/lib/apt/lists/*

# The tang package creates the unprivileged _tang user (uid 100, gid 101). The
# bind-mounted host directory is chowned to the same numeric ids, so tangd runs
# as a non-root user that owns its key directory.
USER 100:101

EXPOSE 7500

ENTRYPOINT ["/usr/libexec/tangd", "-l", "-p", "7500", "/db"]
