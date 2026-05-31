#!/usr/bin/env bash
# wait-for-reviews.sh — the ONE canonical reviewer-wait procedure for /cycle-review.
#
# Why this exists: the skill used to wait with ad-hoc, re-invented loops — and the
# worst of them watched the *comment count* ("wait until the bot has > 1 comment").
# That hangs forever, because Claude ALWAYS edits its single existing comment in
# place instead of posting a new one (the counter never moves). This script never
# looks at counts. Every tick it re-fetches ALL comments from ALL bots and decides
# completion from each bot's latest comment BODY.
#
# Idempotent per PR: the wait state lives in a file keyed by owner/repo/PR
# (~/.claude/cycle-review/state/<owner>__<repo>__pr<PR>.json). If the loop is
# interrupted (turn boundary, context compaction, manual stop) and the script is
# re-run with the same OWNER/REPO/PR, it RESUMES: reviewers already settled in a
# prior run are not re-awaited, and the timeout clock counts from the ORIGINAL
# start, not the restart. Without this, every continuation restarted the wait from
# scratch — the recurring "run-id in the background task, please continue" pain.
#
# Usage (run via Bash with run_in_background: true AND dangerouslyDisableSandbox: true):
#   OWNER=acme REPO=widgets PR=642 REVIEWERS="claude codex" \
#     bash <path-to-skill-dir>/wait-for-reviews.sh
#
#   REVIEWERS  space-separated subset of: claude codex  (exactly the configured ones)
#   RESET=1    start a FRESH wait for this PR — wipe prior state. Use this at the
#              start of each NEW review round (after you push fixes and re-request
#              review), so a previous round's "done" doesn't short-circuit the new one.
#
# Output (one line per event, plus a FINAL block the caller parses):
#   EVENT claude done | EVENT claude limit | EVENT codex done | EVENT <r> timeout
#   EVENT claude done (resumed)        # already settled in a prior run
#   FINAL
#   claude=done|timeout|limit
#   codex=done|timeout
#
# Exit code is always 0 — the caller reads the FINAL block to decide what to do.
# Portable to bash 3.2 (macOS default): no associative arrays, no `mapfile`.

set -uo pipefail

: "${OWNER:?set OWNER}"; : "${REPO:?set REPO}"; : "${PR:?set PR}"
: "${REVIEWERS:?set REVIEWERS (e.g. \"claude codex\")}"
POLL="${POLL:-30}"                 # seconds between ticks
RESET="${RESET:-0}"                # 1 = discard prior state, start a fresh round

# Per-reviewer max wait (seconds). Codex is slower than Claude (~5 min vs ~2 min),
# so it gets a longer ceiling. Override via env if a repo's bots are unusual.
CLAUDE_MAX="${CLAUDE_MAX:-420}"    # 7 min
CODEX_MAX="${CODEX_MAX:-720}"      # 12 min

login_of() {
  case "$1" in
    claude) echo "claude[bot]" ;;
    codex)  echo "chatgpt-codex-connector[bot]" ;;
    *)      echo "$1" ;;
  esac
}
maxwait_of() {
  case "$1" in
    claude) echo "$CLAUDE_MAX" ;;
    codex)  echo "$CODEX_MAX" ;;
    *)      echo 600 ;;
  esac
}

# Claude signals completion by editing "Claude finished" into its comment body.
CLAUDE_DONE='Claude finished'
# Claude usage-cap messages (case-insensitive). Confirmed wording includes
# "usage limit" / "Claude Max usage limit"; the rest are defensive synonyms.
LIMIT_RE='usage limit|max usage limit|reached your usage limit|rate limit|quota'
# Substrings that mean a comment is still a progress placeholder, not a verdict.
PROGRESS_RE='working…|working\.\.\.|in progress|\[ \]'

# ---- Persistent, per-PR state (the idempotency core) ------------------------
STATE_DIR="${CR_STATE_DIR:-$HOME/.claude/cycle-review/state}"
# Sanitize owner/repo so the filename is safe (slashes etc. -> _).
safe() { printf '%s' "$1" | tr '/ :' '___'; }
STATE_FILE="$STATE_DIR/$(safe "$OWNER")__$(safe "$REPO")__pr$(safe "$PR").json"
mkdir -p "$STATE_DIR"

[ "$RESET" = 1 ] && rm -f "$STATE_FILE"

# State schema: { "start": <epoch>, "start_iso": <ISO-8601>, "statuses": { "claude": "done", ... } }
# `start_iso` is the round boundary: only bot comments/reviews updated AFTER it count
# as this round's verdict, so an old in-place-edited "Claude finished" (Claude reuses
# one comment forever) or a stale prior-round Codex review can't short-circuit a fresh
# round. Read the original boundary when resuming; otherwise stamp a fresh one.
if [ -f "$STATE_FILE" ] && jq -e '.start' "$STATE_FILE" >/dev/null 2>&1; then
  START="$(jq -r '.start' "$STATE_FILE")"
  START_ISO="$(jq -r '.start_iso // ""' "$STATE_FILE")"
  RESUMED=1
else
  START="$(date +%s)"
  START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  RESUMED=0
  printf '{"start":%s,"start_iso":"%s","statuses":{}}' "$START" "$START_ISO" > "$STATE_FILE"
fi
# Back-compat: a state file written before start_iso existed has none — fall back to
# the epoch START so the round-scoping filter still has a valid boundary.
[ -z "$START_ISO" ] && START_ISO="$(date -u -r "$START" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '1970-01-01T00:00:00Z')"

# Read a reviewer's persisted status ("" if none).
status_of() { jq -r --arg r "$1" '.statuses[$r] // ""' "$STATE_FILE"; }

# Persist a reviewer's terminal status into the state file (atomic-ish via temp).
persist_status() {
  tmp="$STATE_FILE.tmp.$$"
  jq --arg r "$1" --arg s "$2" '.statuses[$r] = $s' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

settle() {  # settle <reviewer> <status> [suffix]
  persist_status "$1" "$2"
  echo "EVENT $1 $2${3:-}"
}
is_settled() { [ -n "$(status_of "$1")" ]; }

# latest body from a given bot login, "" if none.
#   latest_body <comments-json> <login> <since-iso>
# Only considers comments/reviews whose updated_at (or created_at) is strictly after
# <since-iso> — this scopes completion detection to the current review round.
latest_body() {
  printf '%s' "$1" | jq -r --arg u "$2" --arg since "$3" \
    '[.[] | select(.user.login==$u) | select(((.updated_at // .created_at) // "") > $since)]
     | (last // {}) | .body // ""'
}

# Announce reviewers already settled in a prior run (resume path).
if [ "$RESUMED" = 1 ]; then
  for r in $REVIEWERS; do
    s="$(status_of "$r")"
    [ -n "$s" ] && echo "EVENT $r $s (resumed)"
  done
fi

while :; do
  # Short-circuit: if everything is already settled (e.g. fully-resumed run), stop.
  alldone=1
  for r in $REVIEWERS; do is_settled "$r" || alldone=0; done
  [ "$alldone" -eq 1 ] && break

  # A reviewer can speak on any of three GitHub surfaces, and bots differ on which:
  #   - issue comments      (Claude edits its single one in place)
  #   - PR review objects    (Codex posts its verdict here — invisible to issue comments)
  #   - PR inline review comments
  # We merge all three into one flat array. `--paginate` WITHOUT `--slurp` emits each
  # page as a separate JSON array, which breaks `[.[]]|last` (it runs per page); so we
  # always `--slurp` then `add` to flatten. Reviews use `.submitted_at`, normalized to
  # `.updated_at` so latest_body's round-scoping filter works uniformly.
  ISSUE_C="$(gh api "repos/$OWNER/$REPO/issues/$PR/comments" --paginate --slurp 2>/dev/null \
    | jq -c 'add // []' 2>/dev/null || echo '[]')"
  REVIEWS="$(gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate --slurp 2>/dev/null \
    | jq -c '(add // []) | [.[] | {user, body, updated_at: .submitted_at, created_at: .submitted_at}]' 2>/dev/null || echo '[]')"
  INLINE_C="$(gh api "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate --slurp 2>/dev/null \
    | jq -c 'add // []' 2>/dev/null || echo '[]')"
  COMMENTS="$(printf '%s\n%s\n%s' "$ISSUE_C" "$REVIEWS" "$INLINE_C" | jq -cs 'add // []' 2>/dev/null || echo '[]')"
  NOW="$(date +%s)"; ELAPSED=$(( NOW - START ))

  for r in $REVIEWERS; do
    is_settled "$r" && continue
    body="$(latest_body "$COMMENTS" "$(login_of "$r")" "$START_ISO")"

    if [ "$r" = claude ]; then
      if printf '%s' "$body" | grep -qiE "$LIMIT_RE"; then settle claude limit; continue; fi
      if printf '%s' "$body" | grep -qF  "$CLAUDE_DONE"; then settle claude done;  continue; fi
    else
      # Codex: a non-empty comment that is NOT a progress placeholder = settled review.
      if [ -n "$body" ] && ! printf '%s' "$body" | grep -qiE "$PROGRESS_RE"; then
        settle "$r" done; continue
      fi
    fi

    if [ "$ELAPSED" -ge "$(maxwait_of "$r")" ]; then settle "$r" timeout; continue; fi
  done

  alldone=1
  for r in $REVIEWERS; do is_settled "$r" || alldone=0; done
  [ "$alldone" -eq 1 ] && break

  sleep "$POLL"
done

echo "FINAL"
for r in $REVIEWERS; do printf '%s=%s\n' "$r" "$(status_of "$r")"; done
echo "STATE $STATE_FILE"
