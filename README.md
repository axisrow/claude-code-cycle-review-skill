# Cycle Review — Claude Code Plugin

> [Русская версия](README.ru.md)

Automated PR review cycle for Claude Code. Plans a merge strategy when several PRs are open, requests a code review, intelligently triages reviewer comments (from bots and humans), applies fixes, and repeats until approval — then squash-merges.

## Installation

```bash
git clone https://github.com/axisrow/claude-code-cycle-review-skill.git
cp -r claude-code-cycle-review-skill/skills/cycle-review ~/.claude/skills/
cp -r claude-code-cycle-review-skill/commands ~/.claude/
```

### Prerequisites

- [GitHub CLI](https://cli.github.com/) (`gh`) authenticated with your account
- Claude Code with GitHub Actions reviewer (`claude[bot]`) or any other PR reviewer

### Setup

Before using the skill, run the setup command once:

```
/install-github-app
```

This sets up the GitHub App and CI so Claude Code can review code and edit comments on pull requests.

## Usage

```
/cycle-review [pr-numbers...]
/cr           [pr-numbers...]
```

Both forms are equivalent — `/cr` is a short alias.

If no PR numbers are provided, the skill auto-detects the current PR from the branch and additionally enumerates your other open PRs to plan a merge strategy. Numbers can be passed in any free-form format (`/cr 20 21 25`, `/cr 20, 21, 25`, etc.). Other authors' PRs are never auto-included; pass them explicitly to opt in.

## How It Works

The skill runs an 8-step automated loop:

### 1. Multi-PR strategy

When several of your PRs are open, the skill maps file overlaps and PR stacks, then announces the merge order autonomously (earliest first when overlapping; any order when independent). You can interrupt and override.

### 2. Request review

Posts a comment on the PR asking the reviewer to focus on critical issues only (bugs, security, logic errors, data loss, performance). Cosmetic nitpicks are explicitly discouraged.

### 3. Wait for reviewer response

Sandbox-aware waiting:
- **Primary**: `gh run watch` — a native blocking watch on the Claude Action workflow, no custom loop needed.
- **Fallback**: comment polling by ID — finds the latest `claude[bot]` comment, polls every 30s for the `Claude finished` marker. Runs in the background to avoid blocked `sleep N && ...` patterns.
- Timeout: 7 minutes from comment creation.

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

Finalization happens when no `FIX` verdicts remain — the skill does not require an explicit `APPROVED` review state, since bot reviewers rarely emit it.

### 5. Fix issues

Applies fixes for `FIX` verdicts only. Runs linter and tests before proceeding.

### 6. Commit & push

Conventional commit message, push to remote, return to step 2.

### 7. Check CI before merge

Uses `gh pr checks --watch` to wait for all checks to finish. If any check fails — reads the failed run's logs, fixes the cause, returns to step 6. Stops after 2 failed attempts on the same check.

### 8. Finalize

When approved with no outstanding comments and CI green — squash-merge and clean up the branch. If a multi-PR queue is active, recompute overlaps and continue with the next PR.

## Key Features

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
