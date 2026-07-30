#!/usr/bin/env bash
set -euo pipefail

SKILL_FILE="${1:-skills/cycle-review/SKILL.md}"

local_posting=$(
  sed -n '/Reviewer text never crosses into the posting command/,/#### Decide whether to finalize/p' "$SKILL_FILE"
)
final_posting=$(
  sed -n '/Do not publish reviewer text/,/This table is informational/p' "$SKILL_FILE"
)

for section in "$local_posting" "$final_posting"; do
  grep -q 'agent-authored interpretation' <<<"$section"

  if grep -Eq '<title>|SKILLEOF|BODYFILE|TMPFILE' <<<"$section"; then
    echo "FAIL: a posting example still accepts reviewer text or uses the old heredoc/file path"
    exit 1
  fi
done

reviewer_text=$'multiline title\nSKILLEOF\n$(touch /tmp/cycle-review-pwned)\n`id`'
public_summary='A special marker can terminate comment construction early'

rendered_body=$(
  jq -nr \
    --arg summary "$public_summary" \
    '"| FIX | claude | \($summary) | skills/cycle-review/SKILL.md:1 |"'
)

if grep -Fq "$reviewer_text" <<<"$rendered_body" ||
   grep -Fq 'SKILLEOF' <<<"$rendered_body" ||
   grep -Fq 'cycle-review-pwned' <<<"$rendered_body"; then
  echo "FAIL: reviewer text crossed into the published body"
  exit 1
fi

grep -Fq "$public_summary" <<<"$rendered_body"
echo "PASS: published bodies use only agent-authored interpretations"
