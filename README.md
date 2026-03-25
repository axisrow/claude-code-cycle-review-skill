# Review Cycle — Claude Code Plugin

> [Русская версия](README.ru.md)

Automated PR review cycle for Claude Code. Requests a code review, intelligently triages reviewer comments (from bots and humans), applies fixes, and repeats until approval — then squash-merges.

## Installation

```bash
git clone https://github.com/axisrow/claude-code-review-cycle-skill.git
cp -r claude-code-review-cycle-skill/skills/review-cycle ~/.claude/skills/
```

### Prerequisites

- [GitHub CLI](https://cli.github.com/) (`gh`) authenticated with your account
- Claude Code with GitHub Actions reviewer (`claude[bot]`) or any other PR reviewer

## Usage

```
/cycle-review (cr) [pr-number]
```

If no PR number is provided, the skill auto-detects it from the current branch.

## How It Works

The skill runs a 7-step automated loop:

### 1. Check for earlier open PRs

Before starting, checks if there are open PRs with lower numbers. If found — asks you whether to merge earlier PRs first, review in parallel, or skip the check.

### 2. Request review

Posts a comment on the PR asking the reviewer to focus on critical issues only (bugs, security, logic errors, data loss, performance). Cosmetic nitpicks are explicitly discouraged.

### 3. Wait for reviewer response

Instead of a fixed timeout, the skill **polls the reviewer's comment by ID**:
- Finds the latest comment from `claude[bot]` via GitHub API
- Polls every 30 seconds, checking the body for the `Claude finished` marker
- The review is considered complete when the progress checklist disappears and the finish marker appears
- Timeout: 7 minutes from comment creation

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

### 5. Fix issues

Applies fixes for `FIX` verdicts only. Runs linter and tests before proceeding.

### 6. Commit & push

Conventional commit message, push to remote, return to step 2.

### 7. Finalize

When approved with no outstanding comments — squash-merge and clean up the branch.

## Key Features

- **Smart polling** — tracks the reviewer's comment by ID instead of waiting a fixed time
- **Multi-reviewer support** — processes comments from all reviewers, not just the bot
- **Earlier PR check** — warns about open PRs with lower numbers before starting
- **Claim verification** — verifies every reviewer claim against the actual codebase before fixing
- **Hallucination detection** — catches non-existent functions, wrong line numbers, false conventions
- **Contradiction handling** — detects conflicting requests between review cycles
- **Cosmetic skip** — skips style nitpicks with polite explanations
- **Lint & test gate** — runs `ruff` and `pytest` before every push

## License

MIT
