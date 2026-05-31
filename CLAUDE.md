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
- Per-reviewer timing: Codex is slower (~5 min vs Claude's ~2 min) — max wait 12 min vs 7 min for Claude (env `CODEX_MAX` / `CLAUDE_MAX`)
- Claude usage-limit handling (step 3.1): if Codex is configured, drop Claude for that run and continue on Codex; if not, notify the user the limit is exhausted and stop — never wait for the limit to reset
- **Step 3 waiting is unified in one committed driver** `skills/cycle-review/wait-for-reviews.sh`. It loops with `sleep`, re-reads ALL comments from ALL bots each tick, and detects completion from the comment **body** — never from a comment count. Critical: Claude **always edits its single comment in place**, so any count-based / "new comment" wait hangs forever (the PR #642 stall). The skill must run this driver, not re-invent a loop. Portable to bash 3.2 (no associative arrays)
- **The waiter is idempotent per PR**: state persists to `~/.claude/cycle-review/state/<owner>__<repo>__pr<PR>.json` (`CR_STATE_DIR` overrides the dir). Re-running the same command after an interruption RESUMES — already-settled reviewers are not re-awaited, timeout counts from the original start. Pass `RESET=1` to start a fresh wait at the beginning of each new review round (after pushing fixes). This fixes the old "continue the wait from scratch, run-id is in a background task" failure mode
- All `gh` commands need `dangerouslyDisableSandbox: true` (sandbox blocks TLS to api.github.com)
- Skill uses Agent tool for comment triage (subagent)
- Language: skill prompts in English, responds in user's language
