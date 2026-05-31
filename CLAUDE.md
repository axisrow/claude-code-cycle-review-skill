# CLAUDE.md

## Project Overview

Claude Code plugin providing the `/cycle-review` skill (with `/cr` alias) — an automated PR review loop. On first run it onboards the user to pick which review bots they have (`@claude`, `@codex`, or both). Plans a multi-PR merge strategy when several PRs are open, requests a code review from every configured reviewer, triages reviewer comments (FIX / SKIP / HALLUCINATION / IRRELEVANT / CONFLICTING / ALREADY_FIXED), applies fixes, and repeats until approval, then squash-merges.

## Structure

```
.claude-plugin/plugin.json            # plugin manifest
skills/cycle-review/SKILL.md          # skill definition
skills/cycle-review/wait-for-reviews.sh  # unified reviewer-wait driver (step 3)
commands/cr.md                        # /cr alias for /cycle-review
```

## Key Details

- Single skill plus a short slash-command alias (`/cr`)
- Requires `gh` CLI authenticated with GitHub, plus `jq` for reading/writing the onboarding config
- Reviewer onboarding (step 0): one-time, multi-select (`@claude` / `@codex`), stored globally at `~/.claude/cycle-review/config.json` (`{"reviewers": [...], "version": 1}`). Re-run with `--reconfigure`. Steps 2–3 are driven by this list — never hardcode `@claude`
- Both configured → one ping comment starting `@claude @codex`; single reviewer → just that mention
- **Step 3 waiting is a deliberately dumb driver** `skills/cycle-review/wait-for-reviews.sh` (~50 lines). It just `sleep`s a fixed window (`WAIT`, default 300s) then probes that the API is reachable, and prints one line: `DONE` (wait elapsed, API up → triage) or `ERROR` (sustained API outage → stop, don't merge). It does NOT detect who finished, parse bodies, track per-reviewer state, or resume — ALL interpretation (who replied, relevance, hallucination, Claude usage-limit) happens in the step-4 triage, which reads every comment from every surface itself. No state file, no `RESET`. Run via Bash with `run_in_background: true` + `dangerouslyDisableSandbox: true` (leading foreground `sleep` is blocked; `sleep` inside the backgrounded script is fine). This replaced an over-engineered ~290-line version whose completion-detection/round-scoping/resume machinery kept generating its own bugs
- Claude usage-limit is handled in triage, not a separate step: a usage-limit message means "Claude did not review" (not a finding); proceed on Codex if it reviewed, else stop. Never wait for the limit to reset
- Safety invariant lives in step-4 finalize: never merge unless at least one reviewer actually reviewed this round; `ERROR` from step 3 or bot silence ⇒ stop (an empty triage is not approval)
- All `gh` commands need `dangerouslyDisableSandbox: true` (sandbox blocks TLS to api.github.com)
- Skill uses Agent tool for comment triage (subagent)
- Language: skill prompts in English, responds in user's language
