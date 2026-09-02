#!/bin/sh
set -eu

log() { printf 'level=%s event=%s %s\n' "$1" "$2" "${3:-}" >&2; }
die() { log error "$1" "${2:-}"; exit 1; }

PASSWORD_FILE=/run/secrets/smb_password
[ -s "${PASSWORD_FILE}" ] || die missing_password \
  "${PASSWORD_FILE} is empty or absent. Run: make smb-password"

WORKSPACE_UID="${WORKSPACE_UID:-1000}"
WORKSPACE_GID="${WORKSPACE_GID:-1000}"

SMB_USER=claude
SMB_SHARE_NAME=workspace

[ -d /workspace ] || die missing_workspace "/workspace is not mounted"

# Match the workspace owner so force user/group resolves to the right ids.
if ! getent group "${WORKSPACE_GID}" >/dev/null 2>&1; then
  groupadd -g "${WORKSPACE_GID}" "${SMB_USER}"
fi
if ! getent passwd "${WORKSPACE_UID}" >/dev/null 2>&1; then
  useradd -u "${WORKSPACE_UID}" -g "${WORKSPACE_GID}" \
          -M -d /workspace -s /usr/sbin/nologin "${SMB_USER}"
fi

# The passdb lives in tmpfs and is rebuilt from the environment on every
# boot. Rotating the password is a redeploy, and no credential file survives.
mkdir -p /var/lib/samba/private /run/samba /var/log/samba
password="$(cat "${PASSWORD_FILE}")"
printf '%s\n%s\n' "${password}" "${password}" \
  | smbpasswd -a -s "${SMB_USER}" >/dev/null \
  || die passdb "could not set the SMB password for ${SMB_USER}"
smbpasswd -e "${SMB_USER}" >/dev/null 2>&1 || true

# Refuse to start on a bad config rather than serving a half-broken share.
if ! testparm -s /etc/samba/smb.conf >/dev/null 2>/tmp/testparm.err; then
  cat /tmp/testparm.err >&2
  die bad_config "testparm rejected smb.conf"
fi

# vfs_fruit missing would only show up later as strange macOS behaviour.
if ! testparm -s --parameter-name='vfs objects' \
      --section-name="${SMB_SHARE_NAME}" /etc/samba/smb.conf 2>/dev/null \
      | grep -q fruit; then
  die missing_fruit "vfs_fruit is not loaded; is samba-vfs-modules installed?"
fi

log info start "share=${SMB_SHARE_NAME} user=${SMB_USER} uid=${WORKSPACE_UID}"
exec smbd --foreground --no-process-group --debug-stdout
