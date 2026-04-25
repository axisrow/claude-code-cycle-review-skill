---
name: cycle-review
description: Automated PR review cycle — request review, fix issues, repeat until approved, then merge. Aliased as /cr.
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent
argument-hint: "[pr-numbers...]"
---

# Cycle Review

Automated PR review cycle until full approval, with multi-PR merge strategy planning.

PR numbers come from `$ARGUMENTS`. Parse them as a free-form string — accept any format (space-separated, comma-separated, prose like "twenty, twenty-one and twenty-five"). If `$ARGUMENTS` is empty — auto-detect the current PR from the branch via `gh pr view --json number -q .number`. Other authors' PRs are never included automatically; the user must pass their numbers explicitly.

## Cycle

Repeat steps 2–6 until the PR has no `FIX` verdicts, then run step 7 (CI) and step 8 (merge).

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

Leave a comment on the PR instructing the reviewer to focus on significant issues:
```
gh pr comment <PR> --body "@claude review. Focus on critical issues: bugs, security vulnerabilities, logical errors, data loss risks, performance problems. Do NOT nitpick style, naming conventions, minor formatting, or subjective preferences — only flag issues that could break functionality or cause real harm in production."
```

### 3. Wait for reviewer response

The naive `Bash("sleep N && gh ...")` pattern is blocked by the runtime, and `Monitor` cannot reach `api.github.com` because it runs sandboxed. Use one of the two strategies below.

**Primary — `gh run watch`** (preferred when the Claude Action workflow is detectable):
```
RUN_ID=$(gh run list --limit 1 --json databaseId,headBranch,status \
  --jq "[.[] | select(.headBranch==\"<branch>\")] | .[0].databaseId")
gh run watch "$RUN_ID" --exit-status
```
Run via `Bash` with `dangerouslyDisableSandbox: true`. `gh run watch` is a native blocking watch — no custom loop needed.

**Fallback — comment polling by ID** (when no workflow is found, e.g. Claude Action disabled or not yet started):

#### 3.1. Find the bot's comment
After ~120 seconds (reviewers rarely finish in under 2 minutes), fetch issue comments and find the latest one from `claude[bot]`:
```bash
gh api repos/{owner}/{repo}/issues/{PR}/comments --jq '[.[] | select(.user.login == "claude[bot]")] | last | {id, created_at, body}'
```
Save the `COMMENT_ID` and `created_at` timestamp. If no comment — wait 30 more seconds and retry (max 3 attempts). Still nothing → notify the user and stop.

To wait those 120/30 seconds without `sleep N && ...`, run the lookup in a background loop with both `run_in_background: true` AND `dangerouslyDisableSandbox: true`:
```bash
until gh api repos/{owner}/{repo}/issues/{PR}/comments \
  --jq '[.[] | select(.user.login=="claude[bot]")] | length' | grep -q -v '^0$'; do sleep 30; done
```

#### 3.2. Poll the comment body
Every 30 seconds, check the comment body:
```bash
gh api repos/{owner}/{repo}/issues/comments/{COMMENT_ID} --jq '.body'
```
The review is complete when the body contains the string `Claude finished` (the progress checklist with checkboxes disappears at that point). Run the polling loop in the background, same flags.

#### 3.3. Timeout
Maximum wait: 7 minutes from the comment's `created_at`. If `Claude finished` hasn't appeared by then — take the current body as final and proceed to step 4. Notify the user that the review may be incomplete.

**Anti-patterns — do NOT use:**
- `Bash("sleep 120 && gh ...")` — leading `sleep` is blocked by the runtime.
- `Bash("sleep 60 && sleep 60 && ...")` — chained short sleeps are blocked too.
- `Monitor("until gh api ...; do sleep 30; done")` — `gh api` fails inside the sandbox because of TLS interception.
- Any `gh ...` call without `dangerouslyDisableSandbox: true`.

**Decision table:**

| What we wait for | Tool |
|---|---|
| GitHub Actions workflow finishes | `gh run watch` via `Bash + dangerouslyDisableSandbox` |
| New `claude[bot]` comment / `Claude finished` marker | `Bash + run_in_background + dangerouslyDisableSandbox` with until-loop |
| Just "N seconds" with no condition | `ScheduleWakeup`, not `sleep` |

### 4. Analyze and triage comments

Read all comments and review comments from **all reviewers** (bot and human). Fetch both issue comments and PR review comments:
```bash
gh api repos/{owner}/{repo}/issues/{PR}/comments --jq '[.[] | {id, user: .user.login, body, created_at}]'
gh pr view <PR> --json reviews --jq '.reviews'
```
Process comments from every reviewer, not just `claude[bot]`.

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
- **No `FIX` verdicts** in the triage result → post the replies above for any non-`FIX` comments and proceed to step 7. Do not require an explicit `APPROVED` review state — bot reviewers (e.g. `claude[bot]`) rarely emit it; the absence of blocking issues IS the approval signal.
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
- Return to step 2

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
- All `gh` commands (and any other GitHub API calls) must be run via Bash with `dangerouslyDisableSandbox: true`, as the sandbox blocks TLS connections to api.github.com
- Do not skip critical comments — fix all with the `FIX` verdict. Cosmetic comments (`SKIP`) can be skipped with a reply
- Every commit must have a meaningful message following conventional commits style
- Run lint and tests before every commit
- If tests fail after fixes — fix them before pushing
- If `gh run watch` finds no run id and the fallback comment polling makes no progress after 3 attempts — notify the user and stop: the reviewer bot may be misconfigured or unavailable
