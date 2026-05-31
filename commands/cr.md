---
description: Alias for /cycle-review — automated PR review cycle (request review, triage, fix, merge)
argument-hint: "[pr-numbers...] [onboard]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

Run the `cycle-review` skill with these arguments: $ARGUMENTS

Follow the full procedure defined in `skills/cycle-review/SKILL.md` exactly — reviewer onboarding (step 0, one-time, stored at `~/.claude/cycle-review/config.json`; pass `onboard` to redo it, as in `/cr onboard`), multi-PR strategy planning (step 1), review request to every configured reviewer, waiting for reviews via the `wait-for-reviews.sh` driver (step 3 — it waits a fixed window then returns `DONE`/`ERROR`; triage reads all comments itself), comment triage, fixes, commit/push, and finalization. Do not invent shortcuts: this command exists only as a short alias for `/cycle-review`.
