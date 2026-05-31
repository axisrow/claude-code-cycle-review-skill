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
#   EVENT <r> error                    # sustained API outage — fetch failed FETCH_FAIL_MAX ticks
#   EVENT claude done (resumed)        # already settled in a prior run
#   FINAL
#   claude=done|timeout|limit|error
#   codex=done|timeout|error
#
# Exit code is always 0 — the caller reads the FINAL block to decide what to do.
# `error` means the reviews could NOT be read (not "no findings"): the caller must
# STOP and NOT merge — never treat it like a clean review. `timeout` is fail-soft
# (bot was slow, proceed with a warning); `error` is fail-closed (outage, stop).
# Portable to bash 3.2 (macOS default): no associative arrays, no `mapfile`.

set -uo pipefail

: "${OWNER:?set OWNER}"; : "${REPO:?set REPO}"; : "${PR:?set PR}"
: "${REVIEWERS:?set REVIEWERS (e.g. \"claude codex\")}"
POLL="${POLL:-30}"                 # seconds between ticks
RESET="${RESET:-0}"                # 1 = discard prior state, start a fresh round
# Consecutive failed-fetch ticks before we FAIL CLOSED. A single transient blip
# (network/rate-limit) only burns one tick; only a SUSTAINED outage escalates, so an
# API failure can never be silently mistaken for "no findings → safe to merge".
FETCH_FAIL_MAX="${FETCH_FAIL_MAX:-3}"

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

# Fetch a paginated+slurped endpoint, distinguishing FAILURE from empty-but-ok.
# Prints the flattened JSON array on stdout and signals success/failure via its EXIT
# CODE (0 = gh succeeded, even on an empty list; 1 = gh itself failed: auth/rate-limit/
# network). The status MUST be the return code, not a global — callers capture stdout
# with `X="$(fetch_json …)"`, which runs the body in a subshell where a variable
# assignment would be invisible to the parent; only the exit code survives `$(…)`.
# Never use `|| echo '[]'` for this — that is exactly what hides an outage behind an
# empty array and risks merging unreviewed code.
#   fetch_json <api-path> [jq-postfilter]
fetch_json() {
  local out
  if out="$(gh api "$1" --paginate --slurp 2>/dev/null)"; then
    printf '%s' "$out" | jq -c "${2:-add // []}" 2>/dev/null || printf '[]'
    return 0
  fi
  printf '[]'
  return 1
}

# Announce reviewers already settled in a prior run (resume path).
if [ "$RESUMED" = 1 ]; then
  for r in $REVIEWERS; do
    s="$(status_of "$r")"
    [ -n "$s" ] && echo "EVENT $r $s (resumed)"
  done
fi

FETCH_FAILS=0   # consecutive failed-fetch ticks; reset on any fully-successful tick

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
  # always `--slurp` then `add` to flatten (via fetch_json). Reviews use `.submitted_at`,
  # normalized to `.updated_at` so latest_body's round-scoping filter works uniformly.
  # fetch_json signals failure via exit code, so a real outage is distinguished from
  # "no comments yet" — `$(…)` runs the function in a subshell, where only the exit
  # code (not a variable) survives. Any failed fetch flips fetch_ok_all to 0.
  fetch_ok_all=1
  ISSUE_C="$(fetch_json "repos/$OWNER/$REPO/issues/$PR/comments")"  || fetch_ok_all=0
  REVIEWS="$(fetch_json "repos/$OWNER/$REPO/pulls/$PR/reviews" \
    '(add // []) | [.[] | {user, body, updated_at: .submitted_at, created_at: .submitted_at}]')" || fetch_ok_all=0
  INLINE_C="$(fetch_json "repos/$OWNER/$REPO/pulls/$PR/comments")" || fetch_ok_all=0
  COMMENTS="$(printf '%s\n%s\n%s' "$ISSUE_C" "$REVIEWS" "$INLINE_C" | jq -cs 'add // []' 2>/dev/null || echo '[]')"

  # Fail CLOSED on a SUSTAINED outage. One transient failure only burns a tick; after
  # FETCH_FAIL_MAX consecutive failures, settle every unsettled reviewer as `error`
  # (NOT done/timeout) so the caller stops instead of merging unreviewed code.
  if [ "$fetch_ok_all" = 1 ]; then
    FETCH_FAILS=0
  else
    FETCH_FAILS=$(( FETCH_FAILS + 1 ))
    if [ "$FETCH_FAILS" -ge "$FETCH_FAIL_MAX" ]; then
      for r in $REVIEWERS; do is_settled "$r" || settle "$r" error; done
      break
    fi
    sleep "$POLL"; continue   # transient: don't run body checks on a known-bad fetch
  fi

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
