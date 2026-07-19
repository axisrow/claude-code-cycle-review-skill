# Cycle Review — Claude Code Plugin

> [Русская версия](README.ru.md)

Automated PR review cycle for Claude Code, with **two review modes**:

- **Cloud** (default) — pings the GitHub review bots you have (`@claude`, `@codex`, or both), waits for them to post on the PR, triages their comments, fixes, and runs autonomously through CI and squash-merge.
- **Local** — reviews with the buit-in `/review` comand that reads the PR diff directly (no bot ping, no waiting on GitHub). The `/review` always runs; when `@codex` is in your reviewers list, **Codex also reviews locally** via its companion script (run in parallel, findings merged before triage). It records each round's verdicts as a PR comment, fixes, commits, and pushes — but is **review-only on merge**: it never merges on its own; you trigger the merge when you're ready. If `@codex` is configured but Codex isn't installed/logged in, local mode stops and asks you to `codex login` rather than silently reviewing with Claude alone (fail-closed).

On first run it asks which review bots you have and your default mode. It also plans a merge strategy when several PRs are open, verifies each PR implements its linked issue 100% before review, intelligently triages reviewer comments (from bots and humans), applies fixes, and repeats until approval.

## Installation

```bash
git clone https://github.com/axisrow/claude-code-cycle-review-skill.git
cp -r claude-code-cycle-review-skill/skills/cycle-review ~/.claude/skills/
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
/cycle-review [local|cloud] [pr-numbers...] [onboard]
```

If no PR numbers are provided, the skill auto-detects the current PR from the branch and additionally enumerates your other open PRs to plan a merge strategy. Numbers can be passed in any free-form format (`/cycle-review 20 21 25`, `/cycle-review 20, 21, 25`, etc.). Other authors' PRs are never auto-included; pass them explicitly to opt in.

A leading `local` or `cloud` token (also `--local` / `--cloud`) forces that mode for the run, overriding your saved default — e.g. `/cycle-review local 58` reviews PR #58 locally, `/cycle-review 58` uses your default mode.

## Onboarding (reviewers + default mode)

On **first run** the skill asks two things and stores them globally (once per user):

1. **Which review bots you have** — `@claude`, `@codex`, or both (used by cloud mode).
2. **Your default review mode** — `cloud` (ping GitHub bots, autonomous through merge) or `local` (in-process Claude subagent, never auto-merges).

```
~/.claude/cycle-review/config.json
```

```json
{
  "reviewers": ["@claude", "@codex"],
  "mode": "cloud",
  "version": 2
}
```

The saved `mode` is just the default — a `local`/`cloud` flag always overrides it per run. To change either choice later, run:

```
/cycle-review onboard
```

The legacy `--onboard` and `--reconfigure` forms remain supported. A pre-existing `version: 1` config (no `mode` field) stays valid and is treated as `cloud` until you re-onboard.

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

**Cloud:** pings **all configured reviewers in a single comment** — the body starts with every configured mention (`@claude @codex` when both are on, or just one), asking them to focus on critical issues only (bugs, security, logic errors, data loss, performance). Cosmetic nitpicks are explicitly discouraged.

**Local:** spawns an in-process **Claude subagent** (Agent tool) that reads `gh pr diff` and the current contents of the touched files, reviews to the same critical-only bar, verifies each claim against the real code, and returns structured findings. When `@codex` is configured, it *also* runs Codex locally in parallel — its companion script reviews the PR diff (`adversarial-review --base <PR base>`) in the background while the subagent works, and both sets of findings are merged before triage (Codex's claims are re-verified in triage, not trusted). No bot is pinged and there's no GitHub wait — step 3 is skipped and the findings go straight to triage (step 4). If `@codex` is configured but Codex is unavailable, local mode stops (fail-closed) and asks you to `codex login`.

### 3. Wait for reviewer response *(cloud mode only)*

Waiting is handled by **one small committed driver** (`skills/cycle-review/wait-for-reviews.sh`, ~50 lines) instead of an ad-hoc loop reinvented each run. It is a deliberately dumb waiter: it just `sleep`s a single fixed window (`WAIT`, default 300s — covers Codex's ~5 min and Claude's ~2 min), then probes that the GitHub API is reachable, and prints exactly one line:

- `DONE` — the window elapsed and the API is up. Triage (step 4) then reads every comment itself and decides what actually happened.
- `ERROR` — the PR's comments couldn't be read after several tries (a sustained API outage — expired auth, rate limit, network). This is **not** "no findings": the cycle stops and you're told to check e.g. `gh auth status`. An outage is never allowed to masquerade as approval.

It does **not** detect who finished, parse comment bodies, track per-reviewer state, or resume — there is no state file and nothing to reset. **All** interpretation (who replied, relevance, hallucinations, a Claude usage-limit message) happens in the step-4 triage, which reads all three comment surfaces itself. Each new round just posts a fresh request (step 2) and runs the waiter again; if the background run is lost, re-running it is harmless. This replaced an over-engineered ~290-line version whose completion-detection/resume machinery kept generating its own bugs (for instance a count-based wait once hung forever, because Claude edits its single comment in place rather than posting a new one).

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

In **local** mode the subagent findings have no GitHub comment to reply to, so each round the skill posts **one triage-summary comment** on the PR recording the verdicts — the local review is the reviewer of record.

When no `FIX` verdicts remain, this is the **final cycle** — the skill does not require an explicit `APPROVED` review state, since bot reviewers rarely emit it. It posts replies (cloud) or the summary (local) for the non-`FIX` comments and moves on to the final cleanup pass (step 6.5). After cleanup, **cloud** proceeds to CI and merge; **local** stops and reports — it does not auto-merge.

**Hard cap of 3 cycles.** A cycle is one review-request → triage → fix round. If a 3rd cycle still surfaces `FIX` verdicts, the skill stops instead of looping a 4th time — three rounds with findings still open means the PR isn't converging. It hands back to you with a summary of the still-open findings and a suggestion to narrow scope: move some out of scope into a follow-up issue/PR so the core change can merge, or rethink the approach. The cap only triggers when findings persist; a clean 1st or 2nd round finalizes normally.

### 5. Fix issues

Applies fixes for `FIX` verdicts only. Runs linter and tests before proceeding.

### 6. Commit & push

Conventional commit message, push to remote, return to step 2.

### 6.5. Final cleanup pass (last cycle)

Reached only on the final cycle — when a round has no `FIX` verdicts. Since there's no review round after this one, the skill spends one pass applying **all the minor findings deferred across every previous round** (not just the last): every genuine `SKIP` cosmetic/style/naming nitpick plus any reasonable nice-to-have suggestion the reviewers made. It excludes the verdicts with nothing to fix (`HALLUCINATION` / `IRRELEVANT` / `CONFLICTING` / `ALREADY_FIXED`), de-dups findings that recurred across rounds, lints + tests, commits the cleanup, and proceeds straight to CI — **without** requesting another review. A PR that never accrued any minor findings makes this a no-op.

### 7. Check CI before merge *(cloud mode only)*

Uses `gh pr checks --watch` to wait for all checks to finish. If any check fails — reads the failed run's logs, fixes the cause, commits the fix, and re-checks (back to this step). Stops after 2 failed attempts on the same check. Local mode never reaches this step.

### 8. Finalize *(cloud mode only)*

**Cloud:** when approved with no outstanding comments and CI green — squash-merge and clean up the branch. If a multi-PR queue is active, recompute overlaps and continue with the next PR.

**Local:** does **not** merge — it's review-only on merge by design. After the cleanup pass it stops and reports what was fixed; you trigger the merge yourself when ready.

## Key Features

- **Two review modes** — `cloud` (GitHub bots, autonomous through merge) and `local` (in-process Claude subagent + Codex companion when `@codex` is configured, never auto-merges). Saved as a default in the config and overridable per run with a leading `local`/`cloud` flag
- **Reviewer onboarding** — on first run asks `@claude` / `@codex` / both plus a default mode, stores the choice globally at `~/.claude/cycle-review/config.json`, re-runnable with `/cycle-review onboard`
- **Simple fixed-window waiting (cloud)** — one ~50-line committed driver waits a single window then probes the API, printing only `DONE` / `ERROR`; it tracks no per-reviewer state and never resumes — all interpretation lives in triage. An outage (`ERROR`) is never mistaken for "no findings"
- **Claude usage-limit fallback** — if Claude hits its usage cap, continues on Codex when configured, otherwise notifies and stops without waiting for the limit to reset
- **Multi-PR planning** — detects file overlap and PR stacks, picks merge order
- **Sandbox-aware waiting** — runs the waiter and `gh` calls in the background with the sandbox disabled; never relies on blocked leading `sleep N && ...` patterns
- **Multi-reviewer support** — processes comments from all reviewers, not just the bot
- **Claim verification** — verifies every reviewer claim against the actual codebase before fixing
- **Hallucination detection** — catches non-existent functions, wrong line numbers, false conventions
- **Contradiction handling** — detects conflicting requests between review cycles
- **Cosmetic skip** — skips style nitpicks with polite explanations
- **Lint & test gate** — runs `ruff` and `pytest` before every push
- **CI gate** — waits for green CI before merge, debugs failures automatically

## License

MIT
