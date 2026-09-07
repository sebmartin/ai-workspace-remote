#!/bin/bash
# Install the workspace plugin, then start whatever CMD says.
#
# Claude installs plugins as `name@marketplace`, only from a registered
# marketplace, never straight from a repo URL, and nothing in the CLI takes a
# git ref. So we keep our own single-entry marketplace on disk and write the
# repo and ref into its manifest. Same path whether or not a ref is pinned.
set -uo pipefail

# Starts as root so the container's user can be moved to whoever owns the files
# on the host, then drops and re-enters this script as that user. The uid is not
# baked into the image, so changing it in .env needs no rebuild.
if [ "$(id -u)" = "0" ]; then
  want_uid="${WORKSPACE_UID:-1000}"
  want_gid="${WORKSPACE_GID:-1000}"
  if [ "$(id -u claude)" != "${want_uid}" ] || [ "$(id -g claude)" != "${want_gid}" ]; then
    groupmod -o -g "${want_gid}" claude
    usermod  -o -u "${want_uid}" -g "${want_gid}" claude
    # Only what the image owns. The config directory is a bind mount the host
    # already owns, and recursing into it would be slow and pointless.
    chown "${want_uid}:${want_gid}" /home/claude
    chown -R "${want_uid}:${want_gid}" /home/claude/.local /home/claude/.gitconfig 2>/dev/null
  fi
  exec setpriv --reuid="${want_uid}" --regid="${want_gid}" --init-groups -- "$0" "$@"
fi

# Claude updates itself in the background, but it installs into ~/.local,
# which is not mounted, so the download is thrown away whenever the container
# is recreated and the version falls back to whatever the image was built
# with. Updating at boot means a fresh container starts current.
#
# Not fatal: a failure here should not stop the workspace from coming up.
claude update </dev/null || echo "WARNING: could not check for claude updates"

MARKET=aiwr
# Inside the config directory so it persists with everything else. ~/.claude
# is not mounted any more, so a marketplace there would vanish on a recreate
# while the registration pointing at it survived.
MARKET_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aiwr-marketplace"

PLUGIN_NAME="${PLUGIN_NAME:-ai-workspace}"
PLUGIN_REPO="${PLUGIN_REPO:-sebmartin/ai-workspace-plugin}"

mkdir -p "$MARKET_DIR/.claude-plugin"
jq -n --arg m "$MARKET" --arg p "$PLUGIN_NAME" \
      --arg r "$PLUGIN_REPO" --arg f "${PLUGIN_REF:-}" \
  '{name: $m, owner: {name: "ai-workspace-remote"},
    plugins: [{
      name: $p,
      source: ({source: "github", repo: $r}
               + (if $f == "" then {} else {ref: $f} end))
    }]}' > "$MARKET_DIR/.claude-plugin/marketplace.json"

# All four are idempotent, and all four are needed. `marketplace add` does
# not re-read a manifest it already knows, and `plugin install` is a no-op
# once the plugin exists. Only `plugin update` re-resolves a changed ref, so
# without it a new PLUGIN_REF would silently not take effect.
claude plugin marketplace add "$MARKET_DIR" </dev/null
claude plugin marketplace update "$MARKET" </dev/null
claude plugin install "$PLUGIN_NAME@$MARKET" --scope user </dev/null
claude plugin update "$PLUGIN_NAME@$MARKET" </dev/null \
  || echo "WARNING: $PLUGIN_NAME may not be at ${PLUGIN_REF:-its default branch}"

# Says what is actually live, in `docker logs`.
claude plugin list

exec "$@"
