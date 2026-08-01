#!/usr/bin/env bash
# verify-comment.sh — confirm a local triage-summary comment really exists on the PR.
#
# Deliberately dumb. In local mode the worker is TOLD to post a triage-summary comment
# every cycle (step 6), but a text instruction does not force it — the worker sometimes
# skips the comment or edits the PR body (`gh pr edit --body`) instead of creating an
# issue comment. This script turns "post the comment" into a verifiable gate: the worker
# must capture the comment id from `gh pr comment`, pass it here, and this script confirms
# via the GitHub API that the issue comment actually exists and carries this round's nonce.
#
# It does NOT detect who wrote the comment, parse its body for findings, or track state.
# The endpoint repos/{o}/{r}/issues/comments/{id} distinguishes the form by construction:
# an issue comment resolves here; a PR-body edit produces no comment id at all; an inline
# review comment lives under pulls/comments/{id} and does not resolve here — both surface
# as MISSING.
#
# Run via Bash with dangerouslyDisableSandbox: true (gh api needs TLS to api.github.com).
#
#   REPO_NWO=acme/widgets COMMENT_ID=1234567890 NONCE=abc-def-1234 [SINCE=2026-07-26T..Z] \
#     bash <path-to-skill-dir>/verify-comment.sh
#
#   REPO_NWO    required — owner/repo of the PR.
#   COMMENT_ID  required — the id the worker captured from `gh pr comment ... | grep -oE '[0-9]+$'`.
#   NONCE       required — the round nonce; the comment body must contain it (round-bound).
#   SINCE       optional — ISO 8601 timestamp; if set, the comment's created_at must be >= it.
#
# Output (one line; the caller reads the line, not the exit code which is always 0):
#   VERIFIED <id>      the issue comment exists, carries the nonce, and (if SINCE set) is new enough.
#   MISSING            no such issue comment (the worker skipped it, edited the PR body, or passed a
#                      review-comment / foreign id). The caller must STOP before fixes.
#   STALE_NONCE        the comment exists but its body lacks this round's nonce (old / foreign comment).
#   STALE_TIMESTAMP    the comment exists and has the nonce but predates SINCE (reused old comment).
#   ERROR <reason>     the GitHub API could not be read after a few tries (outage / auth). The caller
#                      must STOP and NOT proceed — an outage must never look like VERIFIED.

set -uo pipefail

: "${REPO_NWO:?set REPO_NWO}"; : "${COMMENT_ID:?set COMMENT_ID}"; : "${NONCE:?set NONCE}"
SINCE="${SINCE:-}"
FAIL_MAX=3

# Fetch the issue comment object. Retry a couple of times so a transient API blip does not
# look like MISSING (which would wrongly STOP the cycle) or ERROR (which also STOPs).
i=0
RAW=""
while [ "$i" -lt "$FAIL_MAX" ]; do
  if RAW=$(gh api "repos/$REPO_NWO/issues/comments/$COMMENT_ID" 2>/dev/null); then
    break
  fi
  i=$(( i + 1 ))
  [ "$i" -lt "$FAIL_MAX" ] && sleep 5
done

if [ -z "$RAW" ]; then
  # Network/Auth failure path: gh api printed nothing (the 2>/dev/null swallowed stderr).
  # A real 404 prints a JSON body on stdout with HTTP exit 0 (see below), so empty output
  # here means the API itself was unreachable — report ERROR, not MISSING.
  echo "ERROR could not read comment $COMMENT_ID (gh api empty output — check gh auth status / network)"
  exit 0
fi

# gh api prints the JSON body on stdout and exits 0 even for a 404 (the error JSON has
# {"message":"Not Found","status":"404"}). Detect that: a real issue-comment object has an
# integer "id"; a 404/403 error object does not.
ID_FIELD=$(jq -r '.id // empty' <<<"$RAW" 2>/dev/null)
if [ -z "$ID_FIELD" ]; then
  # Could be a genuine 404 (MISSING) or a sustained API outage returning an error envelope.
  # Probe a cheap known-good endpoint to tell them apart.
  if gh api "repos/$REPO_NWO" >/dev/null 2>&1; then
    echo "MISSING"
  else
    echo "ERROR API unreachable while verifying comment $COMMENT_ID (check gh auth status / network)"
  fi
  exit 0
fi

BODY=$(jq -r '.body // ""' <<<"$RAW")
CREATED=$(jq -r '.created_at // ""' <<<"$RAW")

# The comment body must carry this round's nonce — proves it is THIS cycle's comment, not a
# reused/old one. (The step-6 local template puts the nonce in the heading.)
case "$BODY" in
  *"$NONCE"*) ;;
  *) echo "STALE_NONCE"; exit 0 ;;
esac

# If SINCE is set, the comment must have been created at/after it — defeats reuse of an old
# comment of a previous round that happened to carry a matching nonce substring.
if [ -n "$SINCE" ] && [ -n "$CREATED" ] && [ "$CREATED" \< "$SINCE" ]; then
  echo "STALE_TIMESTAMP"
  exit 0
fi

echo "VERIFIED $COMMENT_ID"
exit 0
