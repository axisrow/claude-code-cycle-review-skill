#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-skills/cycle-review/verify-comment.sh}"

fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $desc — expected '$expected', got '$actual'"
    fail=1
  fi
}

run() {
  local gh_stub="$1"; shift
  local tmp
  tmp=$(mktemp -d)
  printf '#!/usr/bin/env bash\n%s\n' "$gh_stub" > "$tmp/gh"
  chmod +x "$tmp/gh"
  PATH="$tmp:$PATH" env "$@" bash "$SCRIPT" 2>/dev/null
  rm -rf "$tmp"
}

# VERIFIED: comment exists, carries the nonce, at/after SINCE
out=$(run '
if [[ "$*" == *"issues/comments/111"* ]]; then
  echo "{\"id\":111,\"body\":\"round abc-123 details\",\"created_at\":\"2026-01-01T00:00:01Z\"}"
fi
' REPO_NWO=o/r COMMENT_ID=111 NONCE=abc-123 SINCE=2026-01-01T00:00:00Z)
check "VERIFIED case" "VERIFIED 111" "$out"

# MISSING: 404 error envelope, but repo endpoint reachable
out=$(run '
if [[ "$*" == *"issues/comments/222"* ]]; then
  echo "{\"message\":\"Not Found\",\"status\":\"404\"}"
elif [[ "$*" == *"repos/o/r"* ]]; then
  echo "{}"
fi
' REPO_NWO=o/r COMMENT_ID=222 NONCE=abc-123)
check "MISSING case" "MISSING" "$out"

# STALE_NONCE: comment exists but body lacks the nonce
out=$(run '
if [[ "$*" == *"issues/comments/333"* ]]; then
  echo "{\"id\":333,\"body\":\"unrelated body\",\"created_at\":\"2026-01-01T00:00:01Z\"}"
fi
' REPO_NWO=o/r COMMENT_ID=333 NONCE=abc-123)
check "STALE_NONCE case" "STALE_NONCE" "$out"

# STALE_TIMESTAMP: nonce matches but predates SINCE
out=$(run '
if [[ "$*" == *"issues/comments/444"* ]]; then
  echo "{\"id\":444,\"body\":\"round abc-123\",\"created_at\":\"2025-01-01T00:00:00Z\"}"
fi
' REPO_NWO=o/r COMMENT_ID=444 NONCE=abc-123 SINCE=2026-01-01T00:00:00Z)
check "STALE_TIMESTAMP case" "STALE_TIMESTAMP" "$out"

# ERROR: gh api unreachable (empty stdout every attempt)
out=$(run '
exit 1
' REPO_NWO=o/r COMMENT_ID=555 NONCE=abc-123)
case "$out" in
  ERROR*) ;;
  *) echo "FAIL: ERROR case — expected ERROR prefix, got '$out'"; fail=1 ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "PASS: verify-comment.sh branch logic covers VERIFIED/MISSING/STALE_NONCE/STALE_TIMESTAMP/ERROR"
else
  exit 1
fi
