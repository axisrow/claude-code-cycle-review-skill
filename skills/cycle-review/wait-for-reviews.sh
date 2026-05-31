#!/usr/bin/env bash
# wait-for-reviews.sh — give the review bots a fixed amount of time, then hand back.
#
# Deliberately dumb. It does NOT know about @claude/@codex, completion markers, usage
# limits, or per-reviewer state. It just waits, then confirms the GitHub API is reachable
# so the caller doesn't mistake an outage for "no findings". ALL interpretation — who
# replied, whether it's relevant, hallucinated, or usage-limited — happens in the step-4
# triage, which reads every comment from every surface itself.
#
# This replaces an earlier ~290-line version whose completion-detection / round-scoping /
# resume machinery kept generating its own bugs. Waiting blindly for a fixed window and
# letting triage read everything is simpler and has far less to get wrong.
#
# Run via Bash with run_in_background: true AND dangerouslyDisableSandbox: true.
# A *leading* `sleep N && …` is blocked by the runtime, but a `sleep` inside this
# backgrounded script is fine; the sandbox blocks TLS to api.github.com, hence the flag.
#
#   OWNER=acme REPO=widgets PR=642 WAIT=300 \
#     bash <path-to-skill-dir>/wait-for-reviews.sh
#
#   WAIT      seconds to wait before handing back (default 300 = 5 min; covers Codex ~5m
#             and Claude ~2m). The caller then reads ALL comments and triages them.
#   FAIL_MAX  consecutive failed API reads before failing closed (default 3).
#
# Output (one line; the caller reads the line, not the exit code which is always 0):
#   DONE            wait elapsed and the API is reachable — collect comments and triage.
#   ERROR <reason>  the comments could not be read after FAIL_MAX tries — a sustained
#                   outage, NOT "no findings". The caller must stop and NOT merge.

set -uo pipefail

: "${OWNER:?set OWNER}"; : "${REPO:?set REPO}"; : "${PR:?set PR}"
WAIT="${WAIT:-300}"
FAIL_MAX="${FAIL_MAX:-3}"

# Give the reviewers time to respond. One plain sleep — works because this whole script
# runs backgrounded (only a leading foreground sleep is blocked).
sleep "$WAIT"

# Fail-closed liveness probe: confirm we can actually read the PR's comments. A sustained
# API failure must surface as ERROR, never as a silent empty read that looks mergeable.
i=0
while [ "$i" -lt "$FAIL_MAX" ]; do
  if gh api "repos/$OWNER/$REPO/issues/$PR/comments" >/dev/null 2>&1; then
    echo "DONE"
    exit 0
  fi
  i=$(( i + 1 ))
  [ "$i" -lt "$FAIL_MAX" ] && sleep 5
done

echo "ERROR could not read PR comments after $FAIL_MAX attempts (check gh auth status / network)"
exit 0
