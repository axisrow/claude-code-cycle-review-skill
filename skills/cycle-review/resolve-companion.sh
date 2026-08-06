#!/usr/bin/env bash
# resolve-companion.sh — resolve the path to the Codex companion script (`codex-companion.mjs`).
#
# Deliberately dumb and deterministic. The resolved script is later run with
# `dangerouslyDisableSandbox: true` (it needs TLS), so a wrong pick would execute an
# unrelated plugin impersonating the reviewer. Everything that decides *which* file that
# is lives here, in one place, instead of being re-transcribed from markdown prose each run.
#
# Resolution order:
#   1. Manual override (`CODEX_COMPANION_PATH`, or the deprecated
#      `CYCLE_REVIEW_CODEX_COMPANION_PATH`). This is the escape hatch for installs the
#      manifest structurally cannot see — most commonly a manual dev symlink
#      (`~/.claude/skills/codex` → a local git clone) that never went through
#      `/plugin install`. Setting the var is a deliberate act in the user's own shell
#      profile; that intent is what authorizes the sandbox-disabled launch.
#      A set-but-broken override FAILS CLOSED (`OVERRIDE_BROKEN`) — it does NOT fall back
#      to the manifest, since that would mask the user's typo and silently run a different
#      executable than the one they named.
#   2. Otherwise `~/.claude/plugins/installed_plugins.json`, the canonical plugin→installPath
#      index. Filters, in order:
#        - plugin name (the part before `@`) matches `^codex(-fork)?$` — an anchored
#          allowlist, NOT a substring match (an unrelated plugin merely containing "codex"
#          must not qualify);
#        - `scope == "user"` only — `local`/`project` entries are tied to another repo's
#          `projectPath` and must never be eligible outside it;
#        - newest `lastUpdated` first — the actively installed version, not a file-cache
#          leftover;
#        - probe both layouts per candidate, first existing wins, preserving the timestamp
#          order (do NOT re-sort by path): `<installPath>/plugins/codex/scripts/codex-companion.mjs`
#          (the fork meta-plugin wrapping a `codex` sub-plugin) then
#          `<installPath>/scripts/codex-companion.mjs` (the direct upstream plugin).
#
# Why not `${CLAUDE_PLUGIN_ROOT}`? It is substituted only inside the *owning* plugin — in a
# cycle-review session it points at cycle-review, so it cannot address a sibling plugin.
#
# Plain shell, no network — does NOT itself need `dangerouslyDisableSandbox`.
#
#   bash <path-to-skill-dir>/resolve-companion.sh
#
#   CODEX_COMPANION_PATH                 optional — explicit override (takes priority).
#   CYCLE_REVIEW_CODEX_COMPANION_PATH    optional, DEPRECATED — used only when the new name is
#                                        unset; prints a one-line deprecation warning to stderr.
#   PLUGINS_MANIFEST                     optional — manifest path (defaults to
#                                        $HOME/.claude/plugins/installed_plugins.json). For tests.
#
# Output (one line on stdout; the caller reads the line, not the exit code which is always 0):
#   <path>                  the resolved companion script.
#   NOT_FOUND               no override and the manifest yielded no existing companion — the codex
#                           plugin is not installed at user scope. Caller: fail closed, and do NOT
#                           suggest `codex login` (there is nothing to log into yet).
#   OVERRIDE_BROKEN <path>  an override was set but points at no existing file. Caller: surface the
#                           path and stop — the manifest was deliberately NOT consulted.

set -uo pipefail

MANIFEST="${PLUGINS_MANIFEST:-$HOME/.claude/plugins/installed_plugins.json}"

# --- 1. Manual override (new name wins; old name is a one-release deprecation fallback) ---
OVERRIDE="${CODEX_COMPANION_PATH:-}"
if [ -z "$OVERRIDE" ] && [ -n "${CYCLE_REVIEW_CODEX_COMPANION_PATH:-}" ]; then
  OVERRIDE="$CYCLE_REVIEW_CODEX_COMPANION_PATH"
  echo "CYCLE_REVIEW_CODEX_COMPANION_PATH is deprecated, use CODEX_COMPANION_PATH" >&2
fi

if [ -n "$OVERRIDE" ]; then
  if [ -f "$OVERRIDE" ]; then
    echo "$OVERRIDE"
  else
    # Fail closed. Falling through to the manifest here would run an executable the user
    # did not name, and would hide their typo behind a working-looking review.
    echo "OVERRIDE_BROKEN $OVERRIDE"
  fi
  exit 0
fi

# --- 2. Manifest resolver ---
COMPANION=$(jq -r '
    .plugins // {} | to_entries[]
    | select(.key | split("@")[0] | test("^codex(-fork)?$"))
    | .value[]
    | select(.scope == "user")
    | select(.installPath and (.installPath | length > 0))
    | "\(.lastUpdated // "")\t\(.installPath)"
  ' "$MANIFEST" 2>/dev/null \
  | sort -r | while IFS=$'\t' read -r _ ip; do
      for cand in "$ip/plugins/codex/scripts/codex-companion.mjs" "$ip/scripts/codex-companion.mjs"; do
        [ -f "$cand" ] && { echo "$cand"; break 2; }
      done
    done)

if [ -n "$COMPANION" ]; then
  echo "$COMPANION"
else
  echo "NOT_FOUND"
fi
exit 0
