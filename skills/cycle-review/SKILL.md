---
name: cycle-review
description: Automated PR review cycle — request review, fix issues, repeat until approved, then merge. Cloud mode pings GitHub review bots; local mode reviews with an in-process Claude subagent. Aliased as /cr.
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
argument-hint: "[local|cloud] [pr-numbers...] [onboard]"
---

# Cycle Review

Automated PR review cycle until full approval, with multi-PR merge strategy planning.

PR numbers come from `$ARGUMENTS`. Parse them as a free-form string — accept any format (space-separated, comma-separated, prose like "twenty, twenty-one and twenty-five"). If `$ARGUMENTS` is empty — auto-detect the current PR from the branch via `gh pr view --json number -q .number`. Other authors' PRs are never included automatically; the user must pass their numbers explicitly.

If `$ARGUMENTS` contains the standalone command token `onboard`, or the legacy flags `--onboard` / `--reconfigure`, strip that token out before parsing PR numbers and force the onboarding in step 0 to run again, overwriting the saved config. Treat `onboard` as the preferred user-facing form, e.g. `/cr onboard`.

## Review mode: cloud vs local

The skill has **two review modes**. Pick the active one in step 0.1 before anything else, then branch on it at step 2/3/4.

| Mode | Who reviews | Network to bots? | Use when |
|---|---|---|---|
| **cloud** (default, original behavior) | GitHub bots `@claude` / `@codex` pinged in a PR comment | yes — waits for the bots to post on GitHub | you want the same reviewers a human teammate would see on the PR, and a fully autonomous loop through merge |
| **local** | an in-process **Claude subagent** (Agent tool) reading `gh pr diff` directly — like the inline review the main loop does itself | no bot ping, no GitHub wait; only posts the findings as a PR comment afterwards | you want a fast review without waiting on GitHub bots, or the bots aren't installed. **Claude Code only** — Codex has no equivalent local plugin, so local mode never involves Codex |

**Mode selection — flag overrides config, config is the default:**
- A standalone leading token `local` or `cloud` in `$ARGUMENTS` (also accept `--local` / `--cloud`) forces that mode for this run and is stripped out before parsing PR numbers — exactly like the `onboard` token.
- Otherwise the mode comes from `mode` in the saved config (step 0).
- If neither a flag nor a saved `mode` is present, default to `cloud` (backward-compatible).

**Local mode is review-only on merge:** it runs the full triage→reply→fix→commit→push loop, but it **never merges on its own**. It stops after pushing and hands back to the user; merge happens only when the user explicitly asks. Cloud mode keeps the original autonomous merge (step 8).

## Cycle

Run step 0 (onboarding) and step 0.1 (resolve mode) once at the start of every invocation. Then, for each PR, run step 1.5 (verify the PR implements its linked issue 100% — fix any gap BEFORE asking for review), repeat steps 2–6 until the PR has no `FIX` verdicts — **but no more than 3 cycles**; if a 3rd cycle still has `FIX`s, stop and hand back to the user to narrow scope. Once a round is clean, run step 6.5 (final cleanup pass — apply the minor findings deferred across all earlier rounds). Then: **cloud mode** runs step 7 (CI) and step 8 (merge); **local mode** stops and reports — it does not auto-merge.

### 0. Onboarding — reviewers + default mode (run once per invocation)

The skill needs two things from the user, stored once: which review bots they have installed (`@claude`, `@codex`, or both — drives cloud mode), and the **default review mode** (`cloud` or `local`). The reviewers list drives who gets pinged in step 2 and whose comments we wait for in step 3 (cloud only). The mode is the default when no `local`/`cloud` flag is passed (step 0.1).

**Config location (global, per user):** `~/.claude/cycle-review/config.json`. It is intentionally global — not committed into the reviewed repo, set once, reused across all projects.

**Schema:**
```json
{
  "reviewers": ["@claude", "@codex"],
  "mode": "cloud",
  "version": 2
}
```
`reviewers` is a non-empty array of mention handles (valid: `@claude`, `@codex`; order irrelevant) — used by cloud mode. `mode` is `"cloud"` or `"local"` — the default review mode. `version` is `2` since the `mode` field was added; a `version: 1` config (no `mode`) is still valid and is treated as `mode: "cloud"` until re-onboarded.

**Flow:**

1. Decide whether onboarding is needed. It is needed when `onboard`, `--onboard`, or `--reconfigure` was passed OR the config is missing/invalid. Detect a valid config with (note: `mode` is NOT required for validity — a v1 config without it stays valid and means cloud):
   ```bash
   CONFIG_FILE="$HOME/.claude/cycle-review/config.json"
   jq -e '.reviewers | type == "array" and length > 0' "$CONFIG_FILE" >/dev/null 2>&1 \
     && echo CONFIGURED || echo NEEDS_ONBOARDING
   ```
   `CONFIGURED` → read the reviewers and mode (step 4's read commands) and skip to step 0.1. `NEEDS_ONBOARDING` (missing file, malformed JSON, or empty `reviewers`) → run onboarding.

2. **Run onboarding.** Ask the user TWO `AskUserQuestion` questions (one tool call, two questions):
   - **Reviewers** (multi-select): `@claude`, `@codex` — which review bots they have (one or both). Used by cloud mode.
   - **Default mode** (single-select): `cloud` (ping GitHub review bots, autonomous through merge) vs `local` (in-process Claude subagent reviews the diff, no bot ping, never auto-merges). This is just the default — a `local`/`cloud` flag always overrides it per run.

   Do not free-text-parse either answer; use the structured picker.

3. **Persist the choice.** Build the file with `jq -n` so the JSON is always well-formed (never hand-concatenate strings). Example for "both reviewers, cloud default":
   ```bash
   CONFIG_DIR="$HOME/.claude/cycle-review"
   CONFIG_FILE="$CONFIG_DIR/config.json"
   mkdir -p "$CONFIG_DIR"
   jq -n '{reviewers: ["@claude", "@codex"], mode: "cloud", version: 2}' > "$CONFIG_FILE"
   ```
   For a single reviewer, pass a one-element array (`["@claude"]` or `["@codex"]`); for a local default, set `mode: "local"`. Confirm to the user what was saved and where.

4. **Read the active config** (always, whether freshly onboarded or already configured):
   ```bash
   jq -r '.reviewers[]' "$HOME/.claude/cycle-review/config.json"          # reviewers, one per line (cloud mode)
   jq -r '.mode // "cloud"' "$HOME/.claude/cycle-review/config.json"      # default mode; "cloud" when absent (v1 config)
   ```

### 0.1. Resolve the active review mode (run once per invocation, right after step 0)

Decide cloud vs local for this run, then remember it — every later branch (steps 2, 3, 4, 6.5, 7, 8) reads it.

1. **Flag wins.** If `$ARGUMENTS` had a standalone leading `local` / `cloud` (or `--local` / `--cloud`) token, use that mode and remember it was stripped from PR-number parsing.
2. **Else config.** Use the `mode` read in step 0.4 (`"cloud"` when the field is absent).
3. **Announce it** so the run is self-documenting, e.g. `Review mode: local (in-process Claude subagent; will not auto-merge).` or `Review mode: cloud (pinging @claude @codex).`

In **local** mode the reviewers list is irrelevant (no bots are pinged) — local review is always a Claude subagent and never Codex.

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

### 1.5. Verify the PR implements its linked issue 100% (before any review)

Run this **once per PR, before step 2** — do NOT ask the bots to review a half-finished PR. Review bots check whether the *code* is correct, not whether it is *complete* relative to the issue's design; a PR can be approved by both bots and still ship only half of what the issue asked for. Catch that here, up front, not after a wasted review round (or after merging an incomplete issue).

1. **Find the linked issue.** A repo convention may require a closing keyword (`Closes #N`) in every PR. Read the PR body and the structured closing references:
   ```bash
   gh pr view <PR> --json body,closingIssuesReferences \
     --jq '{body, issues: [.closingIssuesReferences[].number]}'
   ```
   If there is no linked issue (e.g. a pure refactor/chore with none) — skip this step and go to step 2.

2. **Read the issue's design in full:**
   ```bash
   gh issue view <N> --json title,body --jq '{title, body}'
   ```
   Extract every concrete deliverable the design specifies — each output format, flag, marker, edge case, file the issue names. Treat the design section as a checklist, not a vibe.

3. **Confirm each deliverable is actually implemented.** Read the changed code and `grep` the repo to verify every item on that checklist is present in this PR's diff (not merely planned, not "mostly"). A design that lists two markers/flags/outputs and a PR that ships one is a **gap**, even if the shipped half is flawless.

4. **If a gap exists — close it now (before review):**
   - Implement the missing pieces test-first (write the failing test, then the code), following the repo's conventions.
   - Run the repo's linter and full test suite green.
   - Commit (conventional-commits style) and push to the PR branch.
   - Only then proceed to step 2. The bots now review a complete PR in one pass.

   If the gap is large or the issue's design is ambiguous, surface it to the user (with the specific missing deliverables) and ask how to proceed rather than guessing.

5. If the PR fully implements the issue — proceed to step 2.

### 2. Request review

**Branch on the active mode (step 0.1).**

#### 2a. Cloud mode — ping the bots

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
For example, with both configured the body starts with `@claude @codex review.`; with only Codex it starts with `@codex review.`. Run via `Bash` with `dangerouslyDisableSandbox: true`. Then go to step 3a (wait).

#### 2b. Local mode — review with an in-process Claude subagent

No bot is pinged and no GitHub wait happens. Instead, spawn a review **subagent** with the Agent tool (this is the same engine cloud mode uses for triage, pointed at the diff). The subagent must:

- Read the PR metadata and the full diff with `gh pr view <PR> --json title,body,...` and `gh pr diff <PR>` (run via Bash with `dangerouslyDisableSandbox: true`; the diff is read-only GitHub access).
- Read the **current** contents of every file the diff touches (not just the patch hunks) so claims are grounded in real code, and `grep` the repo to confirm any cross-file assertion.
- Review for the same critical-only bar as cloud mode: bugs, security vulnerabilities, logical errors, data-loss risks, performance problems. Do NOT nitpick style/naming/formatting/subjective preferences as `FIX`-level; note genuine minor improvements separately (they feed the step-6.5 cleanup pass).
- Return a structured list of findings, each with: a short title, the `path` and `line` (when locatable), severity (`critical` vs `minor`), the concrete claim, and the evidence it was verified against. The subagent does its own claim-verification before emitting a finding — a finding whose underlying claim it could not confirm in the code must be dropped or marked unverified, never surfaced as critical.

These findings are the local equivalent of "reviewer comments" — carry them straight into step 4's triage as the comment set (they are already claim-checked, but step 4 still assigns the `FIX`/`SKIP`/… verdicts and is the single place merge-readiness is decided). Skip step 3 entirely in local mode and go to step 4.

For thorough or explicitly adversarial reviews you may spawn more than one subagent with different lenses (correctness / security / does-it-implement-the-issue) and merge their findings before triage — optional, scale to the request.

### 3. Wait for reviewer response — **cloud mode only**

Local mode has nothing to wait for (the subagent in step 2b already returned its findings synchronously) — skip this step and go to step 4.

#### 3a. Cloud wait

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

**Comment source depends on the mode (step 0.1):**
- **Cloud** — the reviewer comments fetched from GitHub (the three surfaces below).
- **Local** — the findings the review subagent returned in step 2b. They are already claim-checked, but triage is still where each gets a `FIX`/`SKIP`/… verdict and where merge-readiness is decided. Treat each finding exactly like a reviewer comment (its `path`/`line` map to a comment's `path`/`line`); you do not re-fetch GitHub comments to obtain them, though a human may also have left comments — read those too if present.

#### 4a. Fetch comments (cloud mode)

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

#### 4b. Triage (both modes)

Launch a subagent (Agent tool) to triage each comment (cloud) or each subagent finding (local). The subagent must:
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

In **cloud** mode those replies attach to the bot's existing comments. In **local** mode the subagent findings have no GitHub comment to reply to, so instead **post one summary comment** on the PR recording this round's triage results — the local review is the reviewer of record, so its verdicts must land on the PR:
```bash
gh pr comment <PR> --body "$(cat <<'EOF'
## 🔍 Local review (cycle N)
Reviewed in-process (Claude subagent), no bots pinged.

| Verdict | Finding | Location |
|---|---|---|
| FIX | <title> | path:line |
| SKIP | <title> | path:line |
...
EOF
)"
```
Run via `Bash` with `dangerouslyDisableSandbox: true`. This is the comment the user asked local mode to record before fixing — write it every round, then proceed to fix the `FIX` items.

**Decide whether to finalize** — check these in order (the first two gates are **cloud-only** — they guard against bot silence/outage, which can't happen in local mode where the subagent returns synchronously):
- **(cloud only) Step 3 returned `ERROR`** → do NOT finalize. The comments could not be read (a sustained API outage), so an empty triage is meaningless, not approval. Notify the user and stop; never let an outage become a silent merge.
- **(cloud only) No reviewer was actually heard from this round** → do NOT finalize. If the configured bots posted nothing new for this round (the bots were slow, or Claude shows a usage-limit message instead of a review and no other reviewer responded), then no review happened — "no `FIX` verdicts" only reflects silence, not an approval. Treat a Claude usage-limit message as "Claude did not review" (not a finding). If Codex is configured and reviewed, you may proceed on Codex alone; if nobody reviewed, notify the user and stop. This must be checked BEFORE interpreting the absence of `FIX` verdicts. (In local mode the subagent always returns a review, so this gate is satisfied by construction.)
- **No `FIX` verdicts**, and a real review happened (cloud: at least one reviewer reviewed; local: the subagent returned) → this is the **final cycle**. Do not require an explicit `APPROVED` review state — bot reviewers (e.g. `claude[bot]`) rarely emit it; given a real review, the absence of blocking issues IS the approval signal. Post the replies/summary above for any non-`FIX` comments, then go to **step 6.5** (final cleanup pass — apply the accumulated minor findings). After 6.5: **cloud** proceeds to CI (step 7) + merge (step 8); **local** stops and reports — it does NOT run step 7/8 or merge on its own (see step 8).
- **At least one `FIX`, and this is the 3rd cycle** → STOP, do not start a 4th. Three full review rounds with findings still outstanding means the PR isn't converging on its own — looping further wastes review budget. Notify the user: summarize the still-open `FIX` findings and propose narrowing scope — e.g. move some findings **out of scope** into a follow-up issue/PR so the core change can merge, or have the user rethink the approach. Wait for the user's decision; do not merge and do not auto-loop. (Count a "cycle" as one completed round of steps 2–6, i.e. one review request + triage. The round that produced this 3rd batch of `FIX`s is the 3rd.)
- **At least one `FIX`, and this is cycle 1 or 2** → proceed to step 5.

The cycle counter lives only in your working memory across a long conversation, so make it observable: at the end of every triage, **explicitly state the current cycle number** to the user (e.g. "Triage of cycle 2/3 complete: 1 FIX, 2 SKIP"). This keeps the 3-cycle cap self-checkable instead of relying on hidden state.

### 5. Fix issues
- Only fix comments with the `FIX` verdict from step 4
- Read the files referenced in the comments
- Apply fixes
- Run linter: `ruff check src/ tests/`
- Run tests: `pytest tests/ -v`

### 6. Commit and push
- Commit fixes with a meaningful message (conventional commits style)
- Push to remote
- Return to step 2 ONLY if fewer than 3 cycles have run. This begins a **new review round**: **cloud** posts a fresh review request and runs the step-3 waiter again (it always waits a clean fixed window — nothing to reset); **local** re-spawns the review subagent (step 2b) against the now-updated diff, no wait. Keep a running count of completed cycles (one cycle = one steps 2–6 round). **Hard cap: 3 cycles.** If the round you just triaged was the 3rd and it still had `FIX` verdicts, do NOT loop again — stop and hand back to the user per the step-4 "3rd cycle" gate (summarize the open findings, propose moving some out of scope into a follow-up issue/PR, or rethinking the approach). The cap only bites when findings persist; a clean 1st or 2nd round finalizes normally.

### 6.5. Final cleanup pass (last cycle — apply the accumulated minor findings)

Reached only on the **final cycle** — when a round has no `FIX` verdicts (step 4) and a real review happened. This is the last cycle: there will be **no further review round** after it. Before finalizing, spend this one pass cleaning up everything that was correct-but-not-blocking and was therefore deferred across the earlier rounds, so nothing useful is left on the table.

1. **Gather the minor findings from EVERY previous review round, not just the last one.** Re-read all findings across the whole PR history — **cloud**: all three GitHub surfaces (issue comments, PR reviews, inline review comments — same fetch as step 4); **local**: the subagent findings from every round (and any human comments on the PR). Collect every finding that is real and actionable but was not a `FIX`:
   - all `SKIP` (genuine cosmetic/style/naming/minor-improvement findings), and
   - any reasonable nice-to-have the reviewers suggested (e.g. "add a clarifying comment", "rename for clarity", "tidy this helper", "add a migration note") — even when previously deferred as non-blocking.

   Explicitly EXCLUDE the verdicts that have nothing to fix: `HALLUCINATION` (claim is false), `IRRELEVANT` (not this PR's code), `CONFLICTING` (contradictory — ask, don't guess), and `ALREADY_FIXED` (already done). De-dup findings that recurred across rounds by their substance (use `path` + `line` when present, as on Codex inline comments; otherwise the gist of the body — Claude's single issue comment has no path/line), and skip any that a later commit already addressed.

2. **Apply all of them.** Make the edits, keeping each change minimal and faithful to the reviewer's intent. If a suggested change would be risky, change behavior, or contradicts the repo's conventions, do NOT force it — leave a short reply explaining why it was left out (this is the only thing that may remain unfixed).

3. **Lint and test green**, same as step 5 (`ruff check src/ tests/`, `pytest tests/ -v` — or the repo's equivalents).

4. **Commit and push** (conventional-commits style, e.g. `chore: apply non-blocking review nitpicks before merge`). On the PR, briefly note that the deferred minor findings were applied in `<sha>`.

5. **Do NOT return to step 2.** This pass does not request another review. **Cloud** proceeds directly to step 7 (CI) and step 8 (merge) — the cleanup commit rides the same CI run. **Local** stops here: it does not run step 7/8 and does not merge. Report to the user that the review cycle is complete (summary of what was fixed across rounds and the cleanup `<sha>`), and that merge is theirs to trigger.

If, after re-reading every round, there are genuinely no minor findings to apply (a clean PR that never accrued any `SKIP`/nice-to-have), this step is a no-op — cloud proceeds to step 7; local proceeds to its stop-and-report.

### 7. Check CI before merge — **cloud mode only**

Local mode never reaches this step (it stops at the end of step 6.5). Steps 7 and 8 run only in cloud mode.

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

### 8. Finalization — **cloud mode only**

**Local mode does not merge.** It is review-only on merge by design (the user triggers merge explicitly). After step 6.5 in local mode, stop and report — do not run the commands below.

Cloud mode: when the PR has no remaining `FIX` verdicts and CI is green:
```bash
gh pr merge <PR> --squash --delete-branch
git checkout main
git pull
```

If the user later asks to merge a PR that was reviewed in local mode, this is the step to run (after confirming CI is green via step 7).

If a multi-PR queue was built in step 1 and PRs remain:
- pop the merged PR from the queue;
- recompute the file-overlap map for the remaining PRs (the codebase changed after the merge);
- return to step 2 with the next PR.

## Important
- **Two modes (step 0.1).** `cloud` (default) pings GitHub bots and runs autonomously through merge; `local` reviews with an in-process Claude subagent (no bot ping, no GitHub wait) and is **review-only on merge** — it loops triage→reply/summary→fix→commit→push but stops after cleanup and never merges on its own. A leading `local`/`cloud` flag overrides the saved `mode`; with neither, default to cloud. Local mode is Claude-only — never Codex.
- **Local review records its verdicts on the PR.** Because there is no bot comment to reply to, local mode posts one triage-summary comment per round before fixing (step 4), so the PR has a durable record of what the local reviewer found.
- **Verify completeness before review (step 1.5).** For every PR with a linked issue, confirm the PR implements the issue's design 100% BEFORE requesting a review. Bots check code correctness, not completeness against the issue — they will happily approve a PR that ships only half the design. Read the issue, turn its design into a checklist, verify each item in the diff, and close any gap (test-first) before step 2. Never start the review loop on a half-finished issue.
- **Final cleanup pass before merge (step 6.5).** The round with no `FIX` verdicts is the LAST cycle — there is no review round after it. On that pass, apply ALL the accumulated minor findings (every genuine `SKIP` plus any reasonable nice-to-have suggestion) gathered from **every previous review round**, not just the last one — they were deferred with a reply during the loop, but the final pass actually fixes them. Exclude only `HALLUCINATION` / `IRRELEVANT` / `CONFLICTING` / `ALREADY_FIXED` (nothing to fix there). Lint + test + commit the cleanup, then go straight to CI + merge — do NOT request another review for it.
- **Max 3 review cycles per PR.** One cycle = one steps 2–6 round (review request + triage + fix). If a 3rd cycle still surfaces `FIX` verdicts, STOP — do not start a 4th. Three rounds with blocking findings still open means the PR isn't converging; looping further wastes review budget. Hand back to the user: summarize the still-open findings and propose narrowing scope (move some out of scope into a follow-up issue/PR so the core change can merge, or rethink the approach). Don't merge and don't auto-loop past the cap. The cap only triggers when findings persist — a clean 1st or 2nd round finalizes normally.
- When both reviewers are configured, ping them in **one** comment whose body starts with `@claude @codex`. With a single reviewer, use just that mention.
- Codex is slower than Claude (~5 min vs ~2 min): use the per-reviewer initial wait / max wait from the step 0 table, never Claude's window for Codex.
- If Claude hits its usage limit (step 3.4): when Codex is configured, drop Claude for this run and continue on Codex; when Codex is not configured, just notify the user the limit is exhausted and stop — do **not** wait for the limit to reset.
- All `gh` commands (and any other GitHub API calls) must be run via Bash with `dangerouslyDisableSandbox: true`, as the sandbox blocks TLS connections to api.github.com
- Do not skip critical comments — fix all with the `FIX` verdict. During the review loop, `SKIP` (cosmetic) comments are answered with a reply; on the FINAL pass (step 6.5) they are actually applied, not skipped.
- Every commit must have a meaningful message following conventional commits style
- Run lint and tests before every commit
- If tests fail after fixes — fix them before pushing
- Never merge without a real review. Finalize only if at least one configured reviewer actually posted a review this round (see the finalize gate in step 4). If the bots stayed silent, or Claude only showed a usage-limit message and no one else reviewed, or step 3 returned `ERROR` (a sustained API outage) — notify the user and stop. An empty triage from silence or an outage is not an approval.
