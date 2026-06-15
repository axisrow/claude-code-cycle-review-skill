---
description: Alias for /cycle-review — automated PR review cycle (request review, triage, fix, merge). Cloud (GitHub bots) or local (in-process Claude subagent) mode.
argument-hint: "[local|cloud] [pr-numbers...] [onboard]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

Run the `cycle-review` skill with these arguments: $ARGUMENTS

Follow the full procedure defined in `skills/cycle-review/SKILL.md` exactly — onboarding (step 0: reviewers + default mode, one-time, stored at `~/.claude/cycle-review/config.json`; pass `onboard` to redo it, as in `/cr onboard`), mode resolution (step 0.1: a leading `local`/`cloud` flag overrides the saved default), multi-PR strategy planning (step 1), review (cloud: ping every configured reviewer and wait via the `wait-for-reviews.sh` driver; local: review with an in-process Claude subagent — no bot ping, no GitHub wait, never auto-merges), comment/finding triage, fixes, commit/push, and — cloud only — CI + merge. Do not invent shortcuts: this command exists only as a short alias for `/cycle-review`.
