---
description: Alias for /cycle-review — automated PR review cycle (request review, triage, fix, merge)
argument-hint: "[pr-numbers...]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent
---

Run the `cycle-review` skill with these arguments: $ARGUMENTS

Follow the full procedure defined in `skills/cycle-review/SKILL.md` exactly — multi-PR strategy planning (step 0), review request, waiting via `gh run watch`, comment triage, fixes, commit/push, and finalization. Do not invent shortcuts: this command exists only as a short alias for `/cycle-review`.
