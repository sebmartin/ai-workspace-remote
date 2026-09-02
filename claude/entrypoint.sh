#!/bin/bash
# Install the workspace plugin, then start whatever CMD says.
#
# Claude installs plugins as `name@marketplace`, only from a registered
# marketplace, never straight from a repo URL, and nothing in the CLI takes a
# git ref. So we keep our own single-entry marketplace on disk and write the
# repo and ref into its manifest. Same path whether or not a ref is pinned.
set -uo pipefail

MARKET=aiwr
MARKET_DIR=~/.claude/aiwr-marketplace

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
