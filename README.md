# Cycle Review — Claude Code Plugin

> [Русская версия](README.ru.md)

Automated PR review cycle for Claude Code. On first run it asks which review bots you have (`@claude`, `@codex`, or both). Plans a merge strategy when several PRs are open, verifies each PR implements its linked issue 100% before review, requests a code review from every configured reviewer, intelligently triages reviewer comments (from bots and humans), applies fixes, and repeats until approval — then squash-merges.

## Installation

```bash
git clone https://github.com/axisrow/claude-code-cycle-review-skill.git
cp -r claude-code-cycle-review-skill/skills/cycle-review ~/.claude/skills/
cp -r claude-code-cycle-review-skill/commands ~/.claude/
```

### Prerequisites

- [GitHub CLI](https://cli.github.com/) (`gh`) authenticated with your account
- [`jq`](https://jqlang.github.io/jq/) — for reading and writing the onboarding config
- Claude Code with GitHub Actions reviewer (`claude[bot]`), Codex (`@codex`), or any other PR reviewer

### Setup

Before using the skill, run the setup command once:

```
/install-github-app
```

This sets up the GitHub App and CI so Claude Code can review code and edit comments on pull requests.

## Usage

```
/cycle-review [pr-numbers...] [onboard]
/cr           [pr-numbers...] [onboard]
```

Both forms are equivalent — `/cr` is a short alias.

If no PR numbers are provided, the skill auto-detects the current PR from the branch and additionally enumerates your other open PRs to plan a merge strategy. Numbers can be passed in any free-form format (`/cr 20 21 25`, `/cr 20, 21, 25`, etc.). Other authors' PRs are never auto-included; pass them explicitly to opt in.

## Reviewer onboarding

On **first run** the skill asks which review bots you have installed: `@claude`, `@codex`, or both. The choice is stored globally (once per user) at:

```
~/.claude/cycle-review/config.json
```

```json
{
  "reviewers": ["@claude", "@codex"],
  "version": 1
}
```

From then on the skill silently uses this list: it pings each configured reviewer in the review-request step and waits for each of them to respond. To change the choice later, run the short command:

```
/cr onboard
```

The legacy `--onboard` and `--reconfigure` forms remain supported.

The file is global (not in the reviewed repo), so it never clutters your projects and is reused across all repositories.

## How It Works

The skill runs an onboarding step plus an 8-step automated loop:

### 0. Reviewer onboarding (one-time)

When no config exists (or `onboard` is passed), asks which bots are available (`@claude` / `@codex` / both) and saves the choice to `~/.claude/cycle-review/config.json`. If a config already exists, this step is skipped.

### 1. Multi-PR strategy

When several of your PRs are open, the skill maps file overlaps and PR stacks, then announces the merge order autonomously (earliest first when overlapping; any order when independent). You can interrupt and override.

### 1.5. Verify the issue is implemented 100% (before review)

Before pinging the bots, the skill checks that each PR actually implements its linked issue's full design — not just that the code compiles. It reads the linked issue (`Closes #N`), turns the design into a checklist, and verifies every deliverable (each output format, flag, marker, edge case) is present in the diff. Any gap is closed test-first and pushed **before** the review starts.

Why up front: review bots judge whether the *code* is correct, not whether it's *complete* against the issue — both bots can approve a PR that ships only half the design. Catching that here avoids burning a review round (or merging an incomplete issue). If the gap is large or the design is ambiguous, the skill surfaces the missing deliverables and asks how to proceed.

### 2. Request review

Pings **all configured reviewers in a single comment** — the body starts with every configured mention (`@claude @codex` when both are on, or just one), asking them to focus on critical issues only (bugs, security, logic errors, data loss, performance). Cosmetic nitpicks are explicitly discouraged.

### 3. Wait for reviewer response

Waiting is handled by **one unified driver** (`skills/cycle-review/wait-for-reviews.sh`) instead of an ad-hoc loop reinvented each run. Every tick it `sleep`s, re-reads **all** comments from **all** bots, and detects completion from each bot's latest comment **body** — never from a comment count.

- **Why body, not count**: Claude **always edits its single comment in place** rather than posting a new one. A count-based wait ("until the bot has more than one comment") therefore hangs forever — the exact bug that once stalled a PR. The body check (`Claude finished`) handles the in-place edit correctly.
- **Idempotent per PR**: the wait state is persisted (keyed by `owner/repo/PR`). If the loop is interrupted — a turn boundary, context compaction, a lost background task — re-running the same command **resumes** instead of restarting: reviewers already settled aren't re-awaited and the timeout counts from the original start. A `RESET=1` flag begins a fresh wait for the next review round.
- **Per-reviewer timing** (Codex is slower, ~5 min vs ~2 min): Claude times out at 7 min, Codex at 12 min. Poll interval 30s. All configurable via env.
- **Codex completion**: a settled review/comment appearing instead of a progress placeholder.
- **Claude usage limit**: if Claude's review fails because the account hit its usage cap, then — if Codex is configured — the run drops Claude and continues on Codex only; if Codex is not configured, it notifies you that the limit is exhausted and stops (it never waits for the limit to reset).

Run via the background, sandbox-disabled `Bash` (the GitHub API isn't reachable from the sandbox); a leading `sleep N && …` is blocked, but the `sleep` *inside* the driver loop is fine.

### 4. Analyze and triage comments

Collects comments from **all reviewers** (bot and human) — both issue comments and PR review comments. A subagent triages each comment by reading the actual code:

| Verdict | Action |
|---|---|
| `FIX` | Apply the fix (only after verifying the claim against actual code) |
| `ALREADY_FIXED` | Reply with the commit that addressed it |
| `SKIP` | Reply explaining it's cosmetic |
| `IRRELEVANT` | Reply noting it doesn't relate to the PR |
| `CONFLICTING` | Quote the contradicting comment, ask for clarification |
| `HALLUCINATION` | Reply with evidence from the codebase disproving the claim |

When no `FIX` verdicts remain, this is the **final cycle** — the skill does not require an explicit `APPROVED` review state, since bot reviewers rarely emit it. It posts replies for the non-`FIX` comments and moves on to the final cleanup pass (step 6.5) before merging.

**Hard cap of 3 cycles.** A cycle is one review-request → triage → fix round. If a 3rd cycle still surfaces `FIX` verdicts, the skill stops instead of looping a 4th time — three rounds with findings still open means the PR isn't converging. It hands back to you with a summary of the still-open findings and a suggestion to narrow scope: move some out of scope into a follow-up issue/PR so the core change can merge, or rethink the approach. The cap only triggers when findings persist; a clean 1st or 2nd round finalizes normally.

### 5. Fix issues

Applies fixes for `FIX` verdicts only. Runs linter and tests before proceeding.

### 6. Commit & push

Conventional commit message, push to remote, return to step 2.

### 6.5. Final cleanup pass (last cycle)

Reached only on the final cycle — when a round has no `FIX` verdicts. Since there's no review round after this one, the skill spends one pass applying **all the minor findings deferred across every previous round** (not just the last): every genuine `SKIP` cosmetic/style/naming nitpick plus any reasonable nice-to-have suggestion the reviewers made. It excludes the verdicts with nothing to fix (`HALLUCINATION` / `IRRELEVANT` / `CONFLICTING` / `ALREADY_FIXED`), de-dups findings that recurred across rounds, lints + tests, commits the cleanup, and proceeds straight to CI — **without** requesting another review. A PR that never accrued any minor findings makes this a no-op.

### 7. Check CI before merge

Uses `gh pr checks --watch` to wait for all checks to finish. If any check fails — reads the failed run's logs, fixes the cause, commits the fix, and re-checks (back to this step). Stops after 2 failed attempts on the same check.

### 8. Finalize

When approved with no outstanding comments and CI green — squash-merge and clean up the branch. If a multi-PR queue is active, recompute overlaps and continue with the next PR.

## Key Features

- **Reviewer onboarding** — on first run asks `@claude` / `@codex` / both, stores the choice globally at `~/.claude/cycle-review/config.json`, re-runnable with `/cr onboard`
- **Unified, body-based waiting** — one committed driver reads all bot comments each tick and detects completion by comment body, so Claude's in-place comment edits never cause the count-based hang
- **Resumable waiting** — wait state is persisted per PR, so an interrupted cycle continues where it left off instead of restarting the wait from scratch
- **Per-reviewer timing** — knows Codex is slower than Claude (~5 min vs ~2 min) and waits on each reviewer's own schedule
- **Claude usage-limit fallback** — if Claude hits its usage cap, continues on Codex when configured, otherwise notifies and stops without waiting for the limit to reset
- **Multi-PR planning** — detects file overlap and PR stacks, picks merge order
- **Sandbox-aware waiting** — uses `gh run watch` and background polling; never relies on blocked `sleep N && ...` patterns
- **Smart polling** — tracks the reviewer's comment by ID instead of waiting a fixed time
- **Multi-reviewer support** — processes comments from all reviewers, not just the bot
- **Claim verification** — verifies every reviewer claim against the actual codebase before fixing
- **Hallucination detection** — catches non-existent functions, wrong line numbers, false conventions
- **Contradiction handling** — detects conflicting requests between review cycles
- **Cosmetic skip** — skips style nitpicks with polite explanations
- **Lint & test gate** — runs `ruff` and `pytest` before every push
- **CI gate** — waits for green CI before merge, debugs failures automatically

## License

MIT
