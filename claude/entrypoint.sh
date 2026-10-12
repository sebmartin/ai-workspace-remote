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

# Inside the config directory so they persist with everything else. ~/.claude
# is not mounted any more, so a marketplace there would vanish on a recreate
# while the registration pointing at it survived.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INSTALLED="$CONFIG_DIR/plugins/installed_plugins.json"

MARKET=aiwr
MARKET_DIR="$CONFIG_DIR/aiwr-marketplace"

PLUGIN_NAME="${PLUGIN_NAME:-ai-workspace}"
PLUGIN_REPO="${PLUGIN_REPO:-sebmartin/ai-workspace-plugin}"

# The GitHub path for the workspace plugin, kept for deployments that have no
# checkout under /src. PLUGIN_REPO=none turns it off, which is what a
# deployment installing that plugin from CLAUDE_PLUGIN_PATHS instead wants.
if [ "$PLUGIN_REPO" = none ]; then
  echo "plugin: PLUGIN_REPO=none, skipping the GitHub install of $PLUGIN_NAME"
else
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
fi

# ---- plugins in development, from paths under /src ------------------------
#
# A plugin being worked on is not in any marketplace, so we generate one naming
# each path. Two constraints found by testing, neither of them documented: a
# plugin entry's `source` must be a relative path starting with "./", and it
# must resolve inside the marketplace directory. An absolute path is refused
# outright, and so is "./../x". So each path is symlinked in and named by the
# link. Symlinks are accepted here because this marketplace is a local
# directory rather than one Claude fetched.
DEV_MARKET=aiwr-dev
DEV_MARKET_DIR="$CONFIG_DIR/aiwr-dev-marketplace"

dev_ids=""
dev_entries="[]"

for path in ${CLAUDE_PLUGIN_PATHS:-}; do
  manifest="$path/.claude-plugin/plugin.json"
  if [ ! -f "$manifest" ]; then
    echo "WARNING: $path has no .claude-plugin/plugin.json, skipping it"
    continue
  fi
  name="$(jq -r '.name // ""' "$manifest" 2>/dev/null)"
  if [ -z "$name" ]; then
    echo "WARNING: $manifest declares no name, skipping $path"
    continue
  fi
  dev_entries="$(printf '%s' "$dev_entries" \
    | jq --arg n "$name" '. + [{name: $n, source: ("./" + $n)}]')"
  dev_ids="$dev_ids $name@$DEV_MARKET"
done

# Rebuilt rather than updated, so a path removed from the list leaves no stale
# symlink behind pointing at a plugin nobody asked for any more.
rm -rf "$DEV_MARKET_DIR"
if [ "$dev_entries" != "[]" ]; then
  mkdir -p "$DEV_MARKET_DIR/.claude-plugin"
  for path in ${CLAUDE_PLUGIN_PATHS:-}; do
    name="$(jq -r '.name // ""' "$path/.claude-plugin/plugin.json" 2>/dev/null)"
    [ -n "$name" ] && ln -sfn "$path" "$DEV_MARKET_DIR/$name"
  done
  jq -n --arg m "$DEV_MARKET" --argjson ps "$dev_entries" \
    '{name: $m, owner: {name: "ai-workspace-remote"}, plugins: $ps}' \
    > "$DEV_MARKET_DIR/.claude-plugin/marketplace.json"
  claude plugin marketplace add "$DEV_MARKET_DIR" </dev/null
  claude plugin marketplace update "$DEV_MARKET" </dev/null
fi

# Anything installed from here on a previous boot that is no longer asked for.
# Left alone it would keep loading, and its path under /src may well be gone.
for id in $(jq -r --arg m "@$DEV_MARKET" \
              '.plugins | keys[] | select(endswith($m))' "$INSTALLED" 2>/dev/null); do
  case " $dev_ids " in
    *" $id "*) ;;
    *) echo "plugin: $id is no longer listed, uninstalling"
       claude plugin uninstall "$id" </dev/null >/dev/null 2>&1 || true ;;
  esac
done

# Always a reinstall, never an update. `plugin install` copies the directory to
# cache/<marketplace>/<plugin>/<version>/ and `plugin update` is keyed on the
# version in plugin.json, so a plugin edited without a version bump reports
# "already at the latest version" and keeps serving the old copy. A local
# directory copy is cheap, so taking whatever is on disk every boot is both
# simpler and more predictable than trying to detect the change.
for id in $dev_ids; do
  claude plugin uninstall "$id" </dev/null >/dev/null 2>&1 || true
  claude plugin install "$id" --scope user </dev/null \
    || echo "WARNING: could not install $id"
done

# ---- published plugins, from their own marketplaces -----------------------
#
# Nothing is generated here and no ref is pinned: these are released plugins,
# their versions bump, so `plugin update` does the right thing on its own.
for source in ${CLAUDE_MARKETPLACES:-}; do
  claude plugin marketplace add "$source" </dev/null \
    || { echo "WARNING: could not add marketplace $source"; continue; }
done

# Updated in a second pass, because `marketplace add` takes a source while
# `marketplace update` takes the name from the manifest, and the two are only
# the same string by coincidence. With no name it updates every registered
# marketplace, which sidesteps working out which name a source resolved to.
claude plugin marketplace update </dev/null \
  || echo "WARNING: could not refresh the marketplaces"

for id in ${CLAUDE_PLUGINS:-}; do
  claude plugin install "$id" --scope user </dev/null \
    || { echo "WARNING: could not install $id"; continue; }
  claude plugin update "$id" </dev/null \
    || echo "WARNING: $id may not be at its latest version"
done

# Says what is actually live, in `docker logs`.
claude plugin list

exec "$@"
