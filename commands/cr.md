---
description: Alias for /cycle-review — automated PR review cycle (request review, triage, fix, merge)
argument-hint: "[pr-numbers...] [--reconfigure]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

Run the `cycle-review` skill with these arguments: $ARGUMENTS

Follow the full procedure defined in `skills/cycle-review/SKILL.md` exactly — reviewer onboarding (step 0, one-time, stored at `~/.claude/cycle-review/config.json`; pass `--reconfigure` to redo it), multi-PR strategy planning (step 1), review request to every configured reviewer, waiting for reviews via the unified `wait-for-reviews.sh` driver (step 3 — never re-invent the loop or substitute `gh run watch`, which misses Codex's PR-review surface and the stateful multi-reviewer waiting), comment triage, fixes, commit/push, and finalization. Do not invent shortcuts: this command exists only as a short alias for `/cycle-review`.
