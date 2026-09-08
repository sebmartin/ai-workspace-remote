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
# `ref` is cloned with --branch and cannot take a commit. Commits go in `sha`,
# a separate field wanting 40 lowercase hex.
jq -n --arg m "$MARKET" --arg p "$PLUGIN_NAME" \
      --arg r "$PLUGIN_REPO" --arg f "${PLUGIN_REF:-}" \
  '{name: $m, owner: {name: "ai-workspace-remote"},
    plugins: [{
      name: $p,
      source: ({source: "github", repo: $r}
               + (if $f == "" then {}
                  elif ($f | test("^[0-9a-fA-F]{40}$")) then {sha: ($f | ascii_downcase)}
                  else {ref: $f} end))
    }]}' > "$MARKET_DIR/.claude-plugin/marketplace.json"

# A short commit would be sent as a branch name and fail confusingly.
case "${PLUGIN_REF:-}" in
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*)
    if [ "${#PLUGIN_REF}" -ne 40 ] && printf '%s' "$PLUGIN_REF" | grep -qE '^[0-9a-fA-F]+$'; then
      echo "WARNING: PLUGIN_REF looks like a shortened commit. Use the full 40 characters."
    fi ;;
esac

# `marketplace add` does not re-read a manifest it already knows, and
# `plugin install` is a no-op once the plugin exists, so both are needed.
claude plugin marketplace add "$MARKET_DIR" </dev/null
claude plugin marketplace update "$MARKET" </dev/null

# `plugin update` is keyed on the version in plugin.json, so a branch that
# moved without a version bump reports "already at the latest version". Only a
# reinstall re-resolves the ref, so compare commits and reinstall on a
# mismatch. Unresolvable means keep what is installed.
INSTALLED="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"

if printf '%s' "${PLUGIN_REF:-}" | grep -qE '^[0-9a-fA-F]{40}$'; then
  want="$(printf '%s' "$PLUGIN_REF" | tr 'A-F' 'a-f')"
else
  want="$(git ls-remote "https://github.com/${PLUGIN_REPO}" "${PLUGIN_REF:-HEAD}" 2>/dev/null \
          | awk 'NR==1 {print $1}')"
fi
have="$(jq -r --arg id "$PLUGIN_NAME@$MARKET" \
          '.plugins[$id][0].gitCommitSha // ""' "$INSTALLED" 2>/dev/null || true)"

if [ -z "$want" ]; then
  echo "WARNING: could not resolve ${PLUGIN_REF:-the default branch}, keeping the installed copy"
elif [ -n "$have" ] && [ "$want" != "$have" ]; then
  echo "plugin: ${have:0:7} -> ${want:0:7}, reinstalling"
  claude plugin uninstall "$PLUGIN_NAME@$MARKET" </dev/null >/dev/null 2>&1 || true
fi

claude plugin install "$PLUGIN_NAME@$MARKET" --scope user </dev/null
claude plugin update "$PLUGIN_NAME@$MARKET" </dev/null \
  || echo "WARNING: $PLUGIN_NAME may not be at ${PLUGIN_REF:-its default branch}"

# Says what is actually live, in `docker logs`.
claude plugin list

exec "$@"
