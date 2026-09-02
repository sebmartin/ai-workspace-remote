# Samba export of the workspace for the macOS laptop.
#
# Debian rather than Alpine because vfs_fruit - the module that makes macOS
# behave - ships in samba-vfs-modules here, which `samba` only Recommends and
# so must be named explicitly alongside --no-install-recommends.

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      samba \
      samba-common-bin \
      samba-vfs-modules \
      smbclient \
      procps \
    && rm -rf /var/lib/apt/lists/*

COPY smb.conf /etc/samba/smb.conf
COPY --chmod=755 entrypoint.sh /opt/aiwr/entrypoint.sh

# smbd binds 445 and setuids per session, so it stays root in-container.
# The share's force user/group maps every write to WORKSPACE_UID.
ENTRYPOINT ["/opt/aiwr/entrypoint.sh"]
