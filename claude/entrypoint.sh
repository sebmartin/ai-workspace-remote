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

# ~/.claude is not mounted, so a marketplace there would vanish on a recreate
# while the registration pointing at it survived.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INSTALLED="$CONFIG_DIR/plugins/installed_plugins.json"

# Written to git config rather than left in the environment, because
# GIT_AUTHOR_* would not reach a process started by `docker compose exec`, and
# because some tools read the config rather than the variables. $HOME is not
# mounted, so this is rebuilt on every start.
if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --global user.name  "$GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"
  echo "git: committing as $GIT_USER_NAME <$GIT_USER_EMAIL>"
else
  echo "git: no identity set, so a commit under /src will fail. Set GIT_USER_NAME"
  echo "     and GIT_USER_EMAIL in .env, or run \`make init\` to take them from this host."
fi

# An empty file is valid and means no GitHub access.
GH_TOKEN_FILE=/run/secrets/github_token
if [ -s "$GH_TOKEN_FILE" ]; then
  GH_TOKEN="$(tr -d '\r\n' < "$GH_TOKEN_FILE")"
  export GH_TOKEN
  # The export reaches this process and its children, but not one started by
  # `docker compose exec`, which gets the container's configured environment
  # instead. So log gh in as well, leaving the token in ~/.config/gh where any
  # process finds it. That home is not mounted, so it is rebuilt from the
  # secret on every start and never persisted.
  #
  # Not fatal: this validates against the API, so it fails when GitHub is
  # unreachable, and the export still covers the session itself.
  if printf '%s' "$GH_TOKEN" | gh auth login --with-token >/dev/null 2>&1; then
    echo "github: authenticated from the mounted secret"
  else
    echo "github: GH_TOKEN exported, but gh could not validate it. A session will"
    echo "        work; a shell opened with docker exec will not."
  fi
else
  echo "github: no token, so gh and git push will not be authenticated"
fi

MARKET=aiwr
MARKET_DIR="$CONFIG_DIR/aiwr-marketplace"

# One list, three kinds of entry:
#
#   /src/my-plugin                      a directory you are working in
#   name@owner/repo#ref                 a plugin repo, tracked at that ref
#   name@source                         a marketplace, installed by version
#
# The first two are not in any marketplace, so we generate one naming them.
# A plugin entry's `source` must be relative and must resolve inside the
# marketplace directory, so a directory is symlinked in and named by the link.
# Neither constraint is documented; an absolute path and "./../x" are refused.
rm -rf "$MARKET_DIR"
entries="[]"
want=""
refs=""
dirs=""

for entry in ${CLAUDE_PLUGINS:-}; do
  case "$entry" in
    /*)
      manifest="$entry/.claude-plugin/plugin.json"
      name="$(jq -r '.name // ""' "$manifest" 2>/dev/null)"
      if [ -z "$name" ]; then
        echo "WARNING: $entry has no readable .claude-plugin/plugin.json, skipping it"
        continue
      fi
      mkdir -p "$MARKET_DIR/.claude-plugin"
      ln -sfn "$entry" "$MARKET_DIR/$name"
      entries="$(printf '%s' "$entries" | jq --arg n "$name" \
        '. + [{name: $n, source: ("./" + $n)}]')"
      want="$want $name@$MARKET"
      dirs="$dirs $name@$MARKET"
      ;;
    *\#*)
      name="${entry%%@*}"
      rest="${entry#*@}"
      repo="${rest%%\#*}"
      ref="${rest#*\#}"
      [ "$ref" = HEAD ] && ref=""
      # `ref` is cloned with --branch and cannot take a commit. Commits go in
      # `sha`, a separate field wanting 40 lowercase hex.
      mkdir -p "$MARKET_DIR/.claude-plugin"
      entries="$(printf '%s' "$entries" \
        | jq --arg n "$name" --arg r "$repo" --arg f "$ref" \
          '. + [{name: $n, source: ({source: "github", repo: $r}
                 + (if $f == "" then {}
                    elif ($f | test("^[0-9a-fA-F]{40}$")) then {sha: ($f | ascii_downcase)}
                    else {ref: $f} end))}]')"
      want="$want $name@$MARKET"
      refs="$refs $name@$MARKET=$repo=$ref"
      ;;
    *@*)
      source="${entry#*@}"
      name="${entry%%@*}"
      # A repo, URL or path all contain a slash. A bare name is one that is
      # already registered, so it is used as it is.
      case "$source" in
        */*)
          claude plugin marketplace add "$source" </dev/null \
            || { echo "WARNING: could not add marketplace $source"; continue; }
          # The marketplace's name comes from its own manifest, not its path,
          # so read back what the add recorded against this source.
          market="$(jq -r --arg s "$source" \
            'to_entries[] | select(.value.source.repo == $s
                                or .value.source.path == $s
                                or .value.source.url  == $s) | .key' \
            "$CONFIG_DIR/plugins/known_marketplaces.json" 2>/dev/null | head -1)"
          if [ -z "$market" ]; then
            echo "WARNING: added $source but could not work out its marketplace name, skipping $name"
            continue
          fi ;;
        *) market="$source" ;;
      esac
      want="$want $name@$market"
      ;;
    *)
      echo "WARNING: $entry is not a path, name@source or name@repo#ref, skipping it" ;;
  esac
done

if [ "$entries" != "[]" ]; then
  jq -n --arg m "$MARKET" --argjson ps "$entries" \
    '{name: $m, owner: {name: "ai-workspace-remote"}, plugins: $ps}' \
    > "$MARKET_DIR/.claude-plugin/marketplace.json"
  claude plugin marketplace add "$MARKET_DIR" </dev/null
else
  # Its directory is gone, so a registration left behind would fail every
  # update from here on.
  claude plugin marketplace remove "$MARKET" </dev/null >/dev/null 2>&1 || true
fi
claude plugin marketplace update </dev/null \
  || echo "WARNING: could not refresh the marketplaces"

# Dropped from the list, so uninstall it: a directory under /src may be gone.
for id in $(jq -r --arg m "@$MARKET" \
              '.plugins | keys[] | select(endswith($m))' "$INSTALLED" 2>/dev/null); do
  case " $want " in
    *" $id "*) ;;
    *) echo "plugin: $id is no longer listed, uninstalling"
       claude plugin uninstall "$id" </dev/null >/dev/null 2>&1 || true ;;
  esac
done

# A ref that moved without a version bump: `plugin update` reports "already at
# the latest version", so compare commits and reinstall on a mismatch.
# Unresolvable means keep what is installed.
for spec in $refs; do
  id="${spec%%=*}"; rest="${spec#*=}"; repo="${rest%%=*}"; ref="${rest#*=}"
  if printf '%s' "$ref" | grep -qE '^[0-9a-fA-F]{40}$'; then
    continue
  fi
  if [ "${#ref}" -gt 6 ] && printf '%s' "$ref" | grep -qE '^[0-9a-fA-F]+$'; then
    echo "WARNING: $id names what looks like a shortened commit. Use the full 40 characters."
  fi
  live="$(git ls-remote "https://github.com/${repo}" "${ref:-HEAD}" 2>/dev/null \
          | awk 'NR==1 {print $1}')"
  have="$(jq -r --arg id "$id" '.plugins[$id][0].gitCommitSha // ""' "$INSTALLED" 2>/dev/null || true)"
  if [ -z "$live" ]; then
    echo "WARNING: could not resolve ${ref:-the default branch} of $repo, keeping the installed copy"
  elif [ -n "$have" ] && [ "$live" != "$have" ]; then
    echo "plugin: $id ${have:0:7} -> ${live:0:7}, reinstalling"
    claude plugin uninstall "$id" </dev/null >/dev/null 2>&1 || true
  fi
done

# A directory is reinstalled every start: install copies it and `plugin update`
# is keyed on the version in plugin.json, so an edit without a version bump
# keeps serving the old copy.
for id in $want; do
  case " $dirs " in
    *" $id "*) claude plugin uninstall "$id" </dev/null >/dev/null 2>&1 || true ;;
  esac
  claude plugin install "$id" --scope user </dev/null \
    || { echo "WARNING: could not install $id"; continue; }
  claude plugin update "$id" </dev/null >/dev/null 2>&1 || true
done


# Says what is actually live, in `docker logs`.
claude plugin list

exec "$@"
