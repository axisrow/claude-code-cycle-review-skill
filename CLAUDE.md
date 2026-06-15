# CLAUDE.md

## Project Overview

Claude Code plugin providing the `/cycle-review` skill (with `/cr` alias) — an automated PR review loop with **two modes**. On first run it onboards the user to pick which review bots they have (`@claude`, `@codex`, or both) and a default review **mode** (`cloud`/`local`). Plans a multi-PR merge strategy when several PRs are open, verifies each PR implements its linked issue 100% before requesting review (step 1.5), gets a review, triages comments/findings (FIX / SKIP / HALLUCINATION / IRRELEVANT / CONFLICTING / ALREADY_FIXED), applies fixes, and repeats until approval.

- **Cloud mode** (default, original behavior): pings the configured GitHub bots in a PR comment, waits for them via `wait-for-reviews.sh`, then runs autonomously through CI + squash-merge.
- **Local mode** (Claude Code only — Codex has no local plugin): an in-process Claude subagent (Agent tool) reviews `gh pr diff` directly — no bot ping, no GitHub wait. It records each round's verdicts as a PR summary comment, fixes, commits, and pushes, but is **review-only on merge**: it never merges on its own; the user triggers merge explicitly.

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
- **Two review modes (step 0.1):** `cloud` (default) and `local`. Selection precedence: a leading `local`/`cloud` (or `--local`/`--cloud`) token in `$ARGUMENTS` overrides the saved `mode`; with neither, default to `cloud` (backward-compatible, incl. v1 configs without a `mode` field). The token is stripped before PR-number parsing, same as `onboard`. Local mode reviews with a Claude Agent subagent, posts a triage-summary comment per round, and **never auto-merges** (review-only on merge — user triggers it). Cloud mode is the original autonomous-through-merge path
- Onboarding (step 0): one-time, asks TWO AskUserQuestion questions — reviewers (multi-select `@claude`/`@codex`, used by cloud) and default mode (single-select `cloud`/`local`). Stored globally at `~/.claude/cycle-review/config.json` (`{"reviewers": [...], "mode": "cloud", "version": 2}`). A `version: 1` config without `mode` stays valid and means cloud. Re-run with `/cr onboard` (legacy: `--onboard` / `--reconfigure`). Cloud steps 2–3 are driven by the reviewers list — never hardcode `@claude`
- Both configured → one ping comment starting `@claude @codex`; single reviewer → just that mention
- **Step 3 waiting is a deliberately dumb driver** `skills/cycle-review/wait-for-reviews.sh` (~50 lines). It just `sleep`s a fixed window (`WAIT`, default 300s) then probes that the API is reachable, and prints one line: `DONE` (wait elapsed, API up → triage) or `ERROR` (sustained API outage → stop, don't merge). It does NOT detect who finished, parse bodies, track per-reviewer state, or resume — ALL interpretation (who replied, relevance, hallucination, Claude usage-limit) happens in the step-4 triage, which reads every comment from every surface itself. No state file, no `RESET`. Run via Bash with `run_in_background: true` + `dangerouslyDisableSandbox: true` (leading foreground `sleep` is blocked; `sleep` inside the backgrounded script is fine). This replaced an over-engineered ~290-line version whose completion-detection/round-scoping/resume machinery kept generating its own bugs
- Claude usage-limit is handled in triage, not a separate step: a usage-limit message means "Claude did not review" (not a finding); proceed on Codex if it reviewed, else stop. Never wait for the limit to reset
- Safety invariant lives in step-4 finalize: never merge unless at least one reviewer actually reviewed this round; `ERROR` from step 3 or bot silence ⇒ stop (an empty triage is not approval)
- Completeness gate (step 1.5): before requesting review, verify each PR implements its linked issue's design 100% (read the issue, checklist the design, verify the diff, close gaps test-first). Bots check code correctness, not completeness against the issue — don't burn a review round on a half-finished PR
- Final cleanup pass (step 6.5): the round with no `FIX` verdicts is the last cycle. Before CI+merge, apply ALL accumulated minor findings — every genuine `SKIP` plus reasonable nice-to-haves — gathered from EVERY prior round (not just the last), de-duped; exclude `HALLUCINATION`/`IRRELEVANT`/`CONFLICTING`/`ALREADY_FIXED`. Lint+test+commit, then go straight to merge — no extra review round for the cleanup
- Max 3 cycles per PR (one cycle = one steps 2–6 round). If a 3rd cycle still has `FIX` verdicts, stop instead of looping a 4th time: summarize the open findings and ask the user to narrow scope (move some out of scope into a follow-up issue/PR, or rethink). Cap only bites when findings persist; a clean 1st/2nd round finalizes normally
- All `gh` commands need `dangerouslyDisableSandbox: true` (sandbox blocks TLS to api.github.com)
- Skill uses Agent tool for comment triage (subagent)
- Language: skill prompts in English, responds in user's language
