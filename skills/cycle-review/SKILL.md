---
name: cycle-review
description: Automated PR review cycle — request review, fix issues, repeat until approved, then merge. Aliased as /cr.
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
argument-hint: "[pr-numbers...] [--reconfigure]"
---

# Cycle Review

Automated PR review cycle until full approval, with multi-PR merge strategy planning.

PR numbers come from `$ARGUMENTS`. Parse them as a free-form string — accept any format (space-separated, comma-separated, prose like "twenty, twenty-one and twenty-five"). If `$ARGUMENTS` is empty — auto-detect the current PR from the branch via `gh pr view --json number -q .number`. Other authors' PRs are never included automatically; the user must pass their numbers explicitly.

If `$ARGUMENTS` contains the flag `--reconfigure` (or `--onboard`), strip it out before parsing PR numbers and force the onboarding in step 0 to run again, overwriting the saved config.

## Cycle

Run step 0 (onboarding) once at the start of every invocation, then repeat steps 2–6 until the PR has no `FIX` verdicts, then run step 7 (CI) and step 8 (merge).

### 0. Onboarding — which reviewers are available (run once per invocation)

The skill needs to know which review bots the user actually has installed: `@claude`, `@codex`, or both. This drives who gets pinged in step 2 and whose comments/finish-markers we wait for in step 3.

**Config location (global, per user):** `~/.claude/cycle-review/config.json`. It is intentionally global — not committed into the reviewed repo, set once, reused across all projects.

**Schema:**
```json
{
  "reviewers": ["@claude", "@codex"],
  "version": 1
}
```
`reviewers` is a non-empty array of mention handles. Valid handles are `@claude` and `@codex`. Order does not matter.

**Flow:**

1. Decide whether onboarding is needed. It is needed when `--reconfigure` was passed OR the config is missing/invalid. Detect a valid config with:
   ```bash
   CONFIG_FILE="$HOME/.claude/cycle-review/config.json"
   jq -e '.reviewers | type == "array" and length > 0' "$CONFIG_FILE" >/dev/null 2>&1 \
     && echo CONFIGURED || echo NEEDS_ONBOARDING
   ```
   `CONFIGURED` → read the reviewers (next step's read command) and skip to step 1. `NEEDS_ONBOARDING` (missing file, malformed JSON, or empty `reviewers`) → run onboarding.

2. **Run onboarding.** Ask the user which review bots they have, using the `AskUserQuestion` tool — a single question, multi-select, with options `@claude`, `@codex` (the user may pick one or both). Do not free-text-parse this; use the structured picker.

3. **Persist the choice.** Build the file with `jq -n` so the JSON is always well-formed (never hand-concatenate strings). Example for "both":
   ```bash
   CONFIG_DIR="$HOME/.claude/cycle-review"
   CONFIG_FILE="$CONFIG_DIR/config.json"
   mkdir -p "$CONFIG_DIR"
   jq -n '{reviewers: ["@claude", "@codex"], version: 1}' > "$CONFIG_FILE"
   ```
   For a single reviewer, pass a one-element array, e.g. `'{reviewers: ["@claude"], version: 1}'` or `'{reviewers: ["@codex"], version: 1}'`. Confirm to the user what was saved and where.

4. **Read the active reviewers** (always, whether freshly onboarded or already configured) into a list used by steps 2–3:
   ```bash
   jq -r '.reviewers[]' "$HOME/.claude/cycle-review/config.json"
   ```

**Per-reviewer parameters** (used by steps 2–3). Each configured reviewer maps to:

| Handle | Mention (step 2) | Bot login — comment author (step 3 fallback) | Finish marker (step 3 fallback) | Initial wait | Max wait |
|---|---|---|---|---|---|
| `@claude` | `@claude` | `claude[bot]` | `Claude finished` | ~120s | 7 min |
| `@codex` | `@codex` | `chatgpt-codex-connector[bot]` | review posted (a non-progress review/comment appears) | ~300s | 12 min |

**Timing — Codex is slower than Claude.** Claude usually finishes a review in ~2 minutes; Codex typically takes ~5 minutes, so its timeout is longer (12 min vs 7 min). These ceilings are baked into the step 3 waiter (`CLAUDE_MAX` / `CODEX_MAX`); using Claude's tighter window for Codex would falsely time it out while it is still working. When both are configured, each waits on its own schedule.

The `@claude` row is confirmed. The `@codex` bot login and finish marker are best-effort defaults — Codex's exact comment-author login and completion signal can vary by integration. On the first real Codex run, verify the actual login via `gh api repos/{owner}/{repo}/issues/{PR}/comments --jq '[.[].user.login] | unique'` and, if it differs, tell the user and use the observed value for that session.

### 1. Multi-PR strategy (run once per invocation)

Skip this step only when there is exactly one PR to handle (single-PR run, no other open PRs by the same author).

1. **Build the PR set:**
   - If `$ARGUMENTS` lists explicit PR numbers — use exactly those (this is the only way other authors' PRs enter the queue).
   - Otherwise — current PR plus the author's other open PRs:
     ```
     gh pr list --author "@me" --state open --json number,title,createdAt,headRefName,baseRefName --jq 'sort_by(.createdAt)'
     ```

2. **If the set has exactly one PR** — proceed to step 2.

3. **Build the file-overlap map.** For each PR fetch its changed files:
   ```
   gh pr diff <PR> --name-only
   ```
   Treat PR-A and PR-B as overlapping if any of these holds:
   - their changed-file sets intersect;
   - `baseRefName(A) == headRefName(B)` or vice versa (PR stack);
   - `baseRefName(A)` is not the repo's default branch AND differs from `baseRefName(B)` (potential indirect stack).

   When in doubt — mark them as overlapping. False positives are safer than missed conflicts.

4. **Decide the merge strategy autonomously**, then announce it to the user before proceeding (do not block waiting for an answer):
   - **No overlap anywhere** → all independent. Process the queue from the earliest `createdAt` to the latest.
   - **Some overlap** → sequential by `createdAt` (earliest first). Overlapping PRs must merge in order; non-overlapping ones can interleave but the skill still walks the queue linearly within one session.

   Print a short summary like:
   ```
   Found 3 open PRs: #20, #21, #25.
   Overlap: #20 ↔ #21 (shared src/foo.py); #25 independent.
   Plan: #20 → #21 → #25.
   ```

   The user can interrupt and override; otherwise the plan stands.

5. After each successful merge in step 8, return here: pop the merged PR from the queue, recompute file overlap for the rest (the codebase has changed), and continue with the next PR.

### 2. Request review

Ping **all configured reviewers in a single comment** — concatenate every configured mention, space-separated, at the start of the body. The mention string depends on the active reviewers list from step 0:

| Configured reviewers | Mention string `<MENTIONS>` |
|---|---|
| both `@claude` and `@codex` | `@claude @codex` |
| only `@claude` | `@claude` |
| only `@codex` | `@codex` |

Then post one comment:
```
gh pr comment <PR> --body "<MENTIONS> review. Focus on critical issues: bugs, security vulnerabilities, logical errors, data loss risks, performance problems. Do NOT nitpick style, naming conventions, minor formatting, or subjective preferences — only flag issues that could break functionality or cause real harm in production."
```
For example, with both configured the body starts with `@claude @codex review.`; with only Codex it starts with `@codex review.`. Run via `Bash` with `dangerouslyDisableSandbox: true`.

### 3. Wait for reviewer response

**Use ONE waiter for every case — do not invent a new loop each time.** Run the committed driver `wait-for-reviews.sh`, which sits **next to this `SKILL.md`** (in the installed skill directory — typically `~/.claude/skills/cycle-review/wait-for-reviews.sh`). It is the single source of truth for waiting: every tick it `sleep`s, re-fetches **all** comments from **all** bots, and decides completion from each bot's **latest comment body** — never from a comment count or "a new comment appeared".

> **Why a body check, never a count.** Claude **always edits its one existing comment in place** — it never posts a second one. So any condition like "wait until the bot has more than one comment" (`… | length > 1`) hangs forever: the count stays 1 even after the review is done. This exact bug stalled PR #642. The waiter only ever looks at the body for the `Claude finished` marker, so an in-place edit is detected correctly.

**How to run it** — via `Bash` with **both** `run_in_background: true` and `dangerouslyDisableSandbox: true` (the sandbox blocks TLS to api.github.com; a leading `sleep N && …` is blocked, but a `sleep` *inside* this loop is fine). Resolve the path relative to this skill (the `wait-for-reviews.sh` beside this file):
```bash
OWNER=<owner> REPO=<repo> PR=<PR> REVIEWERS="<configured>" \
  bash "<path-to-skill-dir>/wait-for-reviews.sh"
```
- `REVIEWERS` is the space-separated set from step 0 with the leading `@` stripped — `"claude codex"`, `"claude"`, or `"codex"`. The waiter waits for exactly those.
- Per-reviewer timing is built in (Codex is slower): Claude max wait 7 min, Codex 12 min. Override with `CLAUDE_MAX` / `CODEX_MAX` (seconds) only if a repo's bots behave unusually. Poll interval defaults to 30s (`POLL`).

**Idempotent per PR — resume, never restart.** The waiter persists its state to `~/.claude/cycle-review/state/<owner>__<repo>__pr<PR>.json` (the original start time + which reviewers already settled). If the loop is interrupted — turn boundary, context compaction, a manual stop, or the background task being lost — **just run the exact same command again**. It resumes: a reviewer already `done`/`limit`/`timeout` in a prior run is not re-awaited (you'll see `EVENT <r> <status> (resumed)`), and the timeout clock counts from the *original* start, not the restart. This is the fix for the old "the run-id is in a background task, please continue waiting from scratch" pain — never re-launch a fresh wait by hand; re-run the same waiter and it picks up where it left off.

**Start a fresh round after pushing fixes.** Each new review round (you applied fixes in step 5, committed/pushed in step 6, and re-requested review in step 2) needs a clean wait — otherwise the previous round's `done` would short-circuit it. Pass `RESET=1` on the **first** waiter call of each new round to wipe that PR's state:
```bash
RESET=1 OWNER=<owner> REPO=<repo> PR=<PR> REVIEWERS="<configured>" \
  bash "<path-to-skill-dir>/wait-for-reviews.sh"
```
Within the same round (a plain resume after an interruption), do NOT pass `RESET` — that would throw away the progress you want to keep.

**Safety net — the waiter auto-invalidates stale state.** Even if you forget `RESET=1`, the waiter compares the saved `start_iso` against the server timestamp of the latest review-request comment. If a newer request was posted since the saved wait (a new round, or a brand-new invocation that re-requested review in step 2), the old `done`/`timeout` statuses belong to a *previous* request, so the waiter discards them and starts fresh (you'll see `EVENT all reset (new review request since last wait)`). This prevents a prior run's completed/aborted status from making the waiter emit `(resumed)` and skip the freshly-requested review — which could otherwise let the cycle proceed to merge without ever reading a review for the current request. A genuine resume within the same round (same request → same timestamp) is unaffected and still resumes.

**Reading its output.** The script streams `EVENT <reviewer> <done|limit|timeout|error>` lines (a `(resumed)` suffix means that status carried over from a prior run) and ends with a `FINAL` block, then a `STATE <path>` line pointing at the persisted state file:
```
FINAL
claude=done       # review body contained "Claude finished"
codex=done        # a settled (non-progress) Codex review appeared
STATE /Users/you/.claude/cycle-review/state/acme__widgets__pr642.json
```
Possible per-reviewer statuses:
- `done` → the review is complete; include that bot's comments in triage (step 4).
- `timeout` → the bot didn't finish within its max wait; take whatever it posted as final and tell the user the review may be incomplete.
- `limit` (Claude only) → Claude hit its usage cap (its body matched `usage limit` / `Max usage limit` / `rate limit` / `quota`). Handle per step 3.1 below.
- `error` → a **sustained GitHub API outage** (auth expired, rate-limited, network/TLS failure) prevented the reviews from being read at all — the waiter could not fetch comments for `FETCH_FAIL_MAX` consecutive ticks. This is **not** "no findings". Do **NOT** triage-as-empty and do **NOT** proceed to merge: tell the user the review could not be obtained (and why, e.g. check `gh auth status`) and **stop the cycle**. `error` is fail-closed; `timeout` is fail-soft. Never collapse the two.

When all configured reviewers reach a terminal status the waiter exits. If any reviewer is `error`, stop per the rule above. Otherwise proceed to step 4 using only the comments of reviewers whose status is `done` (or the partial body of a `timeout`ed one).

Optionally, if a single Claude Action workflow run is what you're tracking, `gh run watch <RUN_ID> --exit-status` (via `Bash + dangerouslyDisableSandbox`) is a native blocking watch — but the waiter above already covers review completion and is the default path.

#### 3.1. Claude usage-limit handling
When the waiter reports `claude=limit`, branch on whether `@codex` is in the configured reviewers list:
- **Codex is configured** → do NOT wait for Claude's limit to reset. Notify the user that Claude hit its usage limit and that this run continues on Codex only, then drop Claude from triage and proceed once Codex's status is `done` (the waiter is already only waiting on Codex at that point).
- **Codex is NOT configured** → do nothing and do not wait for the limit to reset. Notify the user that Claude's usage limit is exhausted and stop the cycle. The user can re-run later (or add Codex via `--reconfigure`).

The `wait-for-reviews.sh` source lives next to this skill; read it if you need to adjust detection markers or timing.

**Anti-patterns — do NOT use:**
- **Waiting on a comment count / "a new comment appeared"** (`… | select(.user.login==BOT) | length > N`). Claude edits its single comment in place, so the count never grows — this hangs forever (the PR #642 stall). Always check the **body**, which is exactly what `wait-for-reviews.sh` does.
- **Re-inventing the wait loop inline each time.** There is one waiter; run it. Don't hand-roll a fresh `until gh api …` per invocation — that is how subtly-wrong conditions (like the count check above) creep back in.
- `Bash("sleep 120 && gh ...")` — a *leading* `sleep` is blocked by the runtime. (`sleep` *inside* the waiter loop is fine.)
- `Bash("sleep 60 && sleep 60 && ...")` — chained short sleeps are blocked too.
- `Monitor("until gh api ...; do sleep 30; done")` — `gh api` fails inside the sandbox because of TLS interception.
- Any `gh ...` call without `dangerouslyDisableSandbox: true`.

**Decision table:**

| What we wait for | Tool |
|---|---|
| Any reviewer (Claude and/or Codex) to finish | **`wait-for-reviews.sh`** via `Bash + run_in_background + dangerouslyDisableSandbox` |
| A specific GitHub Actions workflow run to finish | `gh run watch <RUN_ID> --exit-status` via `Bash + dangerouslyDisableSandbox` (optional; the waiter already covers review completion) |
| Just "N seconds" with no condition | `ScheduleWakeup`, not a leading `sleep` |

### 4. Analyze and triage comments

Read all comments and review comments from **all reviewers** (bot and human). Fetch both issue comments and PR review comments:
```bash
# Issue comments (Claude edits its single one here):
gh api repos/{owner}/{repo}/issues/{PR}/comments --jq '[.[] | {id, user: .user.login, body, created_at}]'
# PR review objects — body/state/author (Codex posts its review summary here):
gh pr view <PR> --json reviews --jq '.reviews'
# PR INLINE review comments — line-level findings on the diff. CRITICAL: Codex (and
# Claude's inline notes) post actionable issues HERE, and `gh pr view --json reviews`
# does NOT return them. The step-3 waiter already uses this surface as a completion
# signal, so a reviewer can be `done` purely on an inline finding — triage MUST read it
# too, or a real FIX is silently skipped before merge:
gh api repos/{owner}/{repo}/pulls/{PR}/comments --jq '[.[] | {id, user: .user.login, path, line, body, created_at}]'
```
Process comments from **all three surfaces** and from every reviewer, not just `claude[bot]`. An inline review comment with an actionable finding is a first-class triage input, exactly like an issue comment.

Launch a subagent (Agent tool) to triage each comment. The subagent must:
- Read the current code of files referenced in the comments
- Check whether the issue was already fixed in previous commits (compare with what the reviewer is requesting)
- Assess severity: critical (bug, security, logical error) vs cosmetic (style, naming, formatting)
- Check relevance: does the comment actually relate to this PR's code? The reviewer may be mistaken — referencing non-existent files, confusing function names, or providing feedback that clearly belongs to a different project/PR. Mark such comments as `IRRELEVANT`
- Check consistency: does the comment contradict previous comments from the same or another reviewer? If the reviewer asks for X now but asked for not-X in the previous cycle — mark as `CONFLICTING`
- **Verify every claim before assigning `FIX`**: for each comment, read the actual files and grep the codebase to confirm that every statement the reviewer makes is true. Do not take any claim at face value — LLM reviewers routinely hallucinate: non-existent functions, wrong line numbers, incorrect patterns, false project-wide conventions (e.g. "only English comments", "this method doesn't exist", "this pattern is used everywhere"). A `FIX` verdict is only valid when the underlying claim is confirmed by reading the actual code. If any claim is false — mark as `HALLUCINATION`
- Return a list of comments with a verdict: `FIX` (needs fixing), `ALREADY_FIXED` (already resolved), `SKIP` (cosmetic), `IRRELEVANT` (unrelated to this PR), `CONFLICTING` (contradicts previous comments), `HALLUCINATION` (reviewer's factual claim about the codebase is verifiably false)

Only fix comments with the `FIX` verdict. For other verdicts — leave a reply comment on the PR with an explanation:
- `ALREADY_FIXED` — specify which commit already addressed the issue
- `SKIP` — explain why the comment is cosmetic and does not affect functionality
- `IRRELEVANT` — politely note that the comment does not relate to this PR's code
- `CONFLICTING` — quote the contradicting previous comment and ask the reviewer to clarify
- `HALLUCINATION` — show concrete evidence from the codebase (grep results, file contents) that disproves the reviewer's claim

**Decide whether to finalize:**
- **Any reviewer status is `error`** (from step 3) → do NOT finalize. A sustained API outage means the review was never actually read, so "no `FIX` verdicts" here is meaningless — it only reflects an empty fetch, not an approval. Notify the user and stop; never let an outage become a silent merge.
- **No `FIX` verdicts** in the triage result (and no `error`) → post the replies above for any non-`FIX` comments and proceed to step 7. Do not require an explicit `APPROVED` review state — bot reviewers (e.g. `claude[bot]`) rarely emit it; the absence of blocking issues IS the approval signal.
- **At least one `FIX`** → proceed to step 5.

### 5. Fix issues
- Only fix comments with the `FIX` verdict from step 4
- Read the files referenced in the comments
- Apply fixes
- Run linter: `ruff check src/ tests/`
- Run tests: `pytest tests/ -v`

### 6. Commit and push
- Commit fixes with a meaningful message (conventional commits style)
- Push to remote
- Return to step 2. This begins a **new review round**, so the first step-3 waiter call of this round must pass `RESET=1` (a new request deserves a fresh wait; otherwise the prior round's `done` short-circuits it).

### 7. Check CI before merge

Before merging, verify that all CI checks pass:
```bash
gh pr checks <PR> --watch --interval 10
```
Run via `Bash` with `dangerouslyDisableSandbox: true`. `gh pr checks --watch` is a native blocking watch — no custom loop needed.

If any check has failed — read the logs of the failed run:
```bash
gh run list --branch <HEAD_BRANCH> --limit 5 --json databaseId,name,status,conclusion --jq '.[] | select(.conclusion == "failure")'
gh run view <RUN_ID> --log-failed
```
Identify the root cause, apply fixes to the code, commit and push (follow the commit style from step 6), then return to step 7. Only proceed to step 8 once all checks pass (or the PR has no CI configured).

If the same CI check fails more than 2 times after fixes — notify the user and stop: do not merge a broken build.

### 8. Finalization

When the PR has no remaining `FIX` verdicts and CI is green:
```bash
gh pr merge <PR> --squash --delete-branch
git checkout main
git pull
```

If a multi-PR queue was built in step 1 and PRs remain:
- pop the merged PR from the queue;
- recompute the file-overlap map for the remaining PRs (the codebase changed after the merge);
- return to step 2 with the next PR.

## Important
- Reviewers are configured once via onboarding (step 0) and stored globally at `~/.claude/cycle-review/config.json`. Re-run onboarding with the `--reconfigure` flag. Never hardcode `@claude` — always drive steps 2–3 from the configured reviewers list.
- When both reviewers are configured, ping them in **one** comment whose body starts with `@claude @codex`. With a single reviewer, use just that mention.
- Codex is slower than Claude (~5 min vs ~2 min): use the per-reviewer initial wait / max wait from the step 0 table, never Claude's window for Codex.
- If Claude hits its usage limit (step 3.4): when Codex is configured, drop Claude for this run and continue on Codex; when Codex is not configured, just notify the user the limit is exhausted and stop — do **not** wait for the limit to reset.
- All `gh` commands (and any other GitHub API calls) must be run via Bash with `dangerouslyDisableSandbox: true`, as the sandbox blocks TLS connections to api.github.com
- Do not skip critical comments — fix all with the `FIX` verdict. Cosmetic comments (`SKIP`) can be skipped with a reply
- Every commit must have a meaningful message following conventional commits style
- Run lint and tests before every commit
- If tests fail after fixes — fix them before pushing
- If the `wait-for-reviews.sh` driver returns `timeout` for every configured reviewer (no review body ever appeared within the max wait) — notify the user and stop: the reviewer bot may be misconfigured or unavailable. If it returns `error` for any reviewer, stop per step 3 (a sustained API outage — never merge on an unread review).
