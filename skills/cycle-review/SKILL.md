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

**Where each reviewer posts** (useful for triage in step 4 — the step-3 waiter ignores this and just waits a fixed window):

| Handle | Mention (step 2) | Bot login | Where its review lands |
|---|---|---|---|
| `@claude` | `@claude` | `claude[bot]` | edits a single **issue comment** in place; finishes with the marker `Claude finished` |
| `@codex` | `@codex` | `chatgpt-codex-connector[bot]` | a **PR review** object plus **inline review comments** (not issue comments) |

**Timing.** Claude usually finishes in ~2 min, Codex in ~5 min. The step-3 waiter uses one fixed window (`WAIT`, default 5 min) that covers both — no per-reviewer clocks.

The `@codex` bot login is a best-effort default and can vary by integration. On the first real Codex run, verify the actual login via `gh api repos/{owner}/{repo}/issues/{PR}/comments --jq '[.[].user.login] | unique'` (and `pulls/{PR}/reviews`), and if it differs, tell the user and use the observed value for that session.

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

Give the bots a fixed window to respond, then move on. The waiter does **not** try to
detect "who finished" — that's triage's job (step 4 reads every comment and decides).
It just waits, then confirms the API is reachable so an outage can't masquerade as
"no findings".

Run the committed driver `wait-for-reviews.sh` (beside this `SKILL.md`) via `Bash` with
**both** `run_in_background: true` and `dangerouslyDisableSandbox: true` — the sandbox
blocks TLS to api.github.com, and a *leading* `sleep N && …` is blocked by the runtime,
but the `sleep` *inside* this backgrounded script is fine:
```bash
OWNER=<owner> REPO=<repo> PR=<PR> WAIT=300 \
  bash "<path-to-skill-dir>/wait-for-reviews.sh"
```
- `WAIT` defaults to 300s (5 min), which covers Codex (~5 min) and Claude (~2 min). Raise
  it for unusually slow bots.
- The script prints exactly **one** line:
  - `DONE` → the window elapsed and the API is reachable. Proceed to step 4 and triage
    whatever comments exist.
  - `ERROR <reason>` → the PR's comments could not be read after several tries (a sustained
    API outage — expired auth, rate limit, network). This is **not** "no findings". Stop
    the cycle, tell the user (e.g. check `gh auth status`), and do **not** merge.

There is no per-reviewer status, no state file, and nothing to resume — each new round just
posts a fresh request (step 2) and runs the waiter again. If the background run is lost,
re-run the same command; a fresh wait is harmless.

**Anti-patterns — do NOT use:**
- `Bash("sleep 120 && gh ...")` — a *leading* `sleep` is blocked by the runtime. The `sleep` inside the backgrounded waiter is fine.
- `Bash("sleep 60 && sleep 60 && ...")` — chained short sleeps are blocked too.
- `Monitor("until gh api ...; do sleep 30; done")` — `gh api` fails inside the sandbox because of TLS interception.
- Any `gh ...` call without `dangerouslyDisableSandbox: true`.

### 4. Analyze and triage comments

Read all comments and review comments from **all reviewers** (bot and human). Fetch both issue comments and PR review comments:
```bash
# Issue comments (Claude edits its single one here):
gh api repos/{owner}/{repo}/issues/{PR}/comments --jq '[.[] | {id, user: .user.login, body, created_at}]'
# PR review objects — body/state/author (Codex posts its review summary here):
gh pr view <PR> --json reviews --jq '.reviews'
# PR INLINE review comments — line-level findings on the diff. CRITICAL: Codex (and
# Claude's inline notes) post actionable issues HERE, and `gh pr view --json reviews`
# does NOT return them. Miss this surface and a real FIX is silently skipped before merge:
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

**Decide whether to finalize** — check these in order:
- **Step 3 returned `ERROR`** → do NOT finalize. The comments could not be read (a sustained API outage), so an empty triage is meaningless, not approval. Notify the user and stop; never let an outage become a silent merge.
- **No reviewer was actually heard from this round** → do NOT finalize. If the configured bots posted nothing new for this round (the bots were slow, or Claude shows a usage-limit message instead of a review and no other reviewer responded), then no review happened — "no `FIX` verdicts" only reflects silence, not an approval. Treat a Claude usage-limit message as "Claude did not review" (not a finding). If Codex is configured and reviewed, you may proceed on Codex alone; if nobody reviewed, notify the user and stop. This must be checked BEFORE interpreting the absence of `FIX` verdicts.
- **No `FIX` verdicts**, and at least one reviewer actually reviewed → post the replies above for any non-`FIX` comments and proceed to step 7. Do not require an explicit `APPROVED` review state — bot reviewers (e.g. `claude[bot]`) rarely emit it; given a real review, the absence of blocking issues IS the approval signal.
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
- Return to step 2. This begins a **new review round**: post a fresh review request, then run the step-3 waiter again (it always waits a clean fixed window — nothing to reset).

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
- Never merge without a real review. Finalize only if at least one configured reviewer actually posted a review this round (see the finalize gate in step 4). If the bots stayed silent, or Claude only showed a usage-limit message and no one else reviewed, or step 3 returned `ERROR` (a sustained API outage) — notify the user and stop. An empty triage from silence or an outage is not an approval.
