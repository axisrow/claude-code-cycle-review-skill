---
name: cycle-review
description: Automated PR review cycle — request review, fix issues, repeat until approved, then hand back to you for merge. Cloud mode pings GitHub review bots; local mode reviews with the built-in /review command, plus Codex locally when @codex is configured.
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, Skill, AskUserQuestion, BashOutput, Monitor
argument-hint: "[local|cloud] [pr-numbers...] [onboard]"
---

# Cycle Review

Automated PR review cycle until full approval, with multi-PR merge strategy planning.

PR numbers come from `$ARGUMENTS`. Parse them as a free-form string — accept any format (space-separated, comma-separated, prose like "twenty, twenty-one and twenty-five"). If `$ARGUMENTS` is empty — auto-detect the current PR from the branch via `gh pr view --json number -q .number`. Other authors' PRs are never included automatically; the user must pass their numbers explicitly.

If `$ARGUMENTS` contains the standalone command token `onboard`, or the legacy flags `--onboard` / `--reconfigure`, strip that token out before parsing PR numbers and force step 0 (onboarding) to run again, overwriting the saved config. Treat `onboard` as the preferred user-facing form, e.g. `/cycle-review onboard`.

## Review mode: cloud vs local

The skill has **two review modes**. Pick the active one in step 1 before anything else, then branch on it at steps 4/5/6/9/10/11.

| Mode | Who reviews | Network to bots? | Use when |
|---|---|---|---|
| **cloud** (default) | GitHub bots `@claude` / `@codex` pinged in a PR comment | yes — waits for the bots to post on GitHub | you want the same reviewers a human teammate would see on the PR, and a review cycle that hands back to you for merge (review-only on merge in both modes — see step 11) |
| **local** | the built-in **`/review`** command (Agent-tool-free — Claude Code's own PR-review mechanic) reviewing the PR, **plus Codex (local companion) when `@codex` is configured** | no bot ping, no GitHub wait; only posts the findings as a PR comment afterwards | you want a fast review without waiting on GitHub bots, or the bots aren't installed. `/review` **always** runs; **if `@codex` is in your reviewers list, Codex also reviews locally** via its companion script (run in parallel, findings merged). No GitHub bot ping either way |

**Mode selection — flag overrides config, config is the default:**
- A standalone leading token `local` or `cloud` in `$ARGUMENTS` (also accept `--local` / `--cloud`) forces that mode for this run and is stripped out before parsing PR numbers — exactly like the `onboard` token.
- Otherwise the mode comes from `mode` in the saved config (step 0).
- If neither a flag nor a saved `mode` is present, default to `cloud` (backward-compatible).

**Both modes are review-only on merge.** Each mode runs the full triage→reply→fix→commit→push loop, then watches CI (`gh pr checks --watch`, step 10 — read-only) and auto-fixes a red CI, then **stops and reports**. The skill **never merges on its own** — merge is a user action. A **Manual merge recipe** (step 11) is provided for when the user later asks to merge, but the cycle does not walk into it. (Previously cloud mode merged autonomously at step 11; removed in 0.5.2.)

**Dev mode (codex-fork only):** when the installed codex plugin is the fork (the companion path contains a `-fork/` segment, e.g. `.../codex-fork/1.0.6-fork.3/...`), onboarding (step 0) additionally asks for a default **Codex model** and **effort**, stored in config and passed to the companion every round as `--model`/`--effort` (step 4) — so you stop setting them ad-hoc. Per-run override: `--model <v>` / `--effort <v>` in the arguments (step 1). Upstream `codex` (no `-fork/` in the path) ignores both; behavior is unchanged.

## Cycle

Run step 0 (onboarding) and step 1 (resolve mode) once at the start of every invocation. Then, for each PR, run step 3 (verify the PR implements its linked issue 100% — fix any gap BEFORE asking for review), repeat steps 4–8 until the PR has no `FIX` verdicts — **but no more than 3 cycles**; if a 3rd cycle still has `FIX`s, stop and hand back to the user to narrow scope. Deferred minor findings (`SKIP`/nice-to-have) are applied **inside step 7**, alongside that round's `FIX`es, so they never trail a clean round. Once a round is clean, run step 9 — **normally a no-op final gate**: it re-checks for any *still-unapplied* deferred finding (there usually isn't one, since step 7 already applied them) and posts the roll-up summary. Only if something genuinely slipped through does step 9 apply it, and that triggers one bounded re-review of the same cycle (not a new cycle — see step 8). Then **both modes** run step 10 (CI — read-only `gh pr checks --watch`, auto-fix a red CI in your own PR) and **stop and report** (the skill never merges; merge is a user action — see the manual-merge recipe in step 11).

### 0. Onboarding — reviewers + default mode (optional, run once per invocation)

The skill needs two things from the user, stored once: which review bots they have installed (`@claude`, `@codex`, or both — drives cloud mode), and the **default review mode** (`cloud` or `local`). The reviewers list drives who gets pinged in step 4 and whose comments we wait for in step 5 (cloud only). The mode is the default when no `local`/`cloud` flag is passed (step 1).

If a **codex-fork** is the installed codex plugin (the companion path contains a `-fork/` segment, e.g. `.../codex-fork/1.0.6-fork.3/...` — see the detect in step 4), a **dev mode** unlocks two extra onboarding fields: a default **Codex model** and **effort** that are passed to the companion every round so you stop setting them ad-hoc in code. Upstream `codex` (no `-fork/` in the path) does not support these flags and the fields stay absent. **Dev-mode fields are written only during onboarding** — an existing v1/v2 config is not auto-upgraded; to enable dev mode on an existing install, re-run `/cycle-review onboard` (the step-0 detect will then offer the model/effort questions).

**Config location (global, per user):** `~/.claude/cycle-review/config.json`. It is intentionally global — not committed into the reviewed repo, set once, reused across all projects.

**Schema:**
```json
{
  "reviewers": ["@claude", "@codex"],
  "mode": "cloud",
  "version": 3,
  "codex_model": "sol",
  "codex_effort": "xhigh"
}
```
`reviewers` is a non-empty array of mention handles (valid: `@claude`, `@codex`; order irrelevant) — used by cloud mode. `mode` is `"cloud"` or `"local"` — the default review mode. `version` is `3`; older configs (v1 without `mode`, v2 without the codex fields) stay valid — `mode` absent means `cloud`, `codex_model`/`codex_effort` absent means "let the companion pick" (the pre-dev-mode behavior). `codex_model`/`codex_effort` are only ever written under dev mode (codex-fork installed); they are optional and absent on upstream codex.

**Flow:**

1. Decide whether onboarding is needed. It is needed when `onboard`, `--onboard`, or `--reconfigure` was passed OR the config is missing/invalid. Detect a valid config with (note: `mode`, `codex_model`, `codex_effort` are NOT required for validity — a v1/v2 config without them stays valid):
   ```bash
   CONFIG_FILE="$HOME/.claude/cycle-review/config.json"
   jq -e '.reviewers | type == "array" and length > 0' "$CONFIG_FILE" >/dev/null 2>&1 \
     && echo CONFIGURED || echo NEEDS_ONBOARDING
   ```
   `CONFIGURED` → read the reviewers and mode (the read commands below) and skip to step 1. `NEEDS_ONBOARDING` (missing file, malformed JSON, or empty `reviewers`) → run onboarding.

2. **Detect dev mode (codex-fork).** Run the companion resolver from step 4.1 and check the version segment of the resolved path:
   ```bash
   CODEX_FORK=false
   [ -n "$COMPANION" ] && case "$COMPANION" in *-fork/*) CODEX_FORK=true;; esac
   ```
   (`codex-fork/1.0.6-fork.3/...` → matches `*-fork/*` → `CODEX_FORK=true`. Upstream `codex/1.0.6/...` → `false`. If no codex plugin is installed, `$COMPANION` is empty → `false`, and the dev-mode questions are skipped.)

3. **Run onboarding — first `AskUserQuestion` (always):** reviewers + default mode (one tool call, two questions):
   - **Reviewers** (multi-select): `@claude`, `@codex` — which review bots they have (one or both). Used by cloud mode.
   - **Default mode** (single-select): `cloud` (ping GitHub review bots) vs `local` (the built-in `/review` reviews the PR, no bot ping). Both modes are review-only on merge — see step 11. This is just the default — a `local`/`cloud` flag always overrides it per run.

   Do not free-text-parse either answer; use the structured picker.

4. **Run onboarding — second `AskUserQuestion` (dev mode only).** Only when `CODEX_FORK=true`. One tool call, two questions — each question capped at **four** options (Claude Code's `AskUserQuestion` limit):
   - **Codex model** (single-select, 4 options): `spark` (gpt-5.3-codex-spark — fast, lightweight) / `sol` (gpt-5.6-sol — biggest, recommended for code review) / `terra` (gpt-5.6-terra — smaller than sol) / `luna` (gpt-5.6-luna — the smallest). Passed to the companion as `--model`.
   - **Codex effort** (single-select, 4 options): `low` / `medium` / `high` / `xhigh` (recommended `xhigh` — best for adversarial code review). Passed as `--effort`. (The companion accepts the full set `none`/`minimal`/`low`/`medium`/`high`/`xhigh`/`max`/`ultra`, but the picker offers only the realistic four — `max`/`ultra` stay reachable via the per-run `--effort` override in step 1.)

   Skip this call entirely when `CODEX_FORK=false` — config gets no `codex_model`/`codex_effort`. (Values are validated by the companion itself; the skill just forwards them. A bad value surfaces as a companion stderr error → step 6 fail-closed.)

5. **Persist the choice.** Build the file with `jq -n` so the JSON is always well-formed (never hand-concatenate strings). Base for "both reviewers, cloud default":
   ```bash
   CONFIG_DIR="$HOME/.claude/cycle-review"
   CONFIG_FILE="$CONFIG_DIR/config.json"
   mkdir -p "$CONFIG_DIR"
   jq -n '{reviewers: ["@claude", "@codex"], mode: "cloud", version: 3}' > "$CONFIG_FILE"
   ```
   Then, **only under dev mode**, add the two fields (example `sol`/`xhigh`):
   ```bash
   jq '. + {codex_model: "sol", codex_effort: "xhigh"}' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
   ```
   For a single reviewer, pass a one-element array (`["@claude"]` or `["@codex"]`); for a local default, set `mode: "local"`. Confirm to the user what was saved and where (and whether dev mode was detected).

6. **Read the active config** (always, whether freshly onboarded or already configured):
   ```bash
   jq -r '.reviewers[]' "$HOME/.claude/cycle-review/config.json"          # reviewers, one per line (cloud mode)
   jq -r '.mode // "cloud"' "$HOME/.claude/cycle-review/config.json"      # default mode; "cloud" when absent (v1 config)
   jq -r '.codex_model // empty' "$HOME/.claude/cycle-review/config.json" # dev mode only; empty when absent
   jq -r '.codex_effort // empty' "$HOME/.claude/cycle-review/config.json"# dev mode only; empty when absent
   ```

### 1. Resolve the active review mode

Decide cloud vs local for this run, then remember it — every later branch (steps 4, 5, 6, 9, 10, 11) reads it.

1. **Flag wins.** If `$ARGUMENTS` had a standalone leading `local` / `cloud` (or `--local` / `--cloud`) token, use that mode and remember it was stripped from PR-number parsing.
2. **Else config.** Use the `mode` read in step 0 (`"cloud"` when the field is absent).
3. **Announce it** so the run is self-documenting, e.g. `Review mode: local (built-in /review).` or `Review mode: cloud (pinging @claude @codex).` (Both modes are review-only on merge — see step 11.)

4. **Dev-mode per-run override (codex-fork only).** Parse and strip these tokens from `$ARGUMENTS` before PR-number parsing, exactly like the `local`/`cloud`/`onboard` tokens:
   - `--model <v>` (or `model=<v>`) → `RUN_MODEL=<v>` — overrides `codex_model` for this run.
   - `--effort <v>` (or `effort=<v>`) → `RUN_EFFORT=<v>` — overrides `codex_effort` for this run.

   These overrides apply **only under dev mode** (step 0 detected `CODEX_FORK=true`). On upstream codex they are ignored with a one-line note ("`--model`/`--effort` ignored — upstream codex doesn't accept them"). The resolved values (`RUN_MODEL`/`RUN_EFFORT`, else the config fields) are consumed in step 4.1 when building the companion flags.

In **local** mode no bots are pinged, but the **reviewers list still matters**: the built-in `/review` always runs, and if the list contains `@codex`, Codex also reviews locally via its companion script (step 4). `@claude`-only stays `/review`-only. (The reviewers list read in step 0 is consulted by local step 4 too, not only cloud — no extra read is needed.)

The `@codex` bot login is a best-effort default and can vary by integration. On the first real Codex run, verify the actual login via `gh api repos/{owner}/{repo}/issues/{PR}/comments --jq '[.[].user.login] | unique'` (and `pulls/{PR}/reviews`), and if it differs, tell the user and use the observed value for that session.

### 2. Multi-PR strategy (run once per invocation)

**Ownership gate (runs before any PR-controlled code executes).** The trust predicate throughout the skill is **ownership** (`author == @me`), NOT review mode — cloud is the default and legitimately reviews your own PRs, so mode is not a trust signal. For **each** PR, resolve ownership once; the rest of the skill (steps 3/4/6/7/9/10) gates local execution on it. **Fail-closed**: if either lookup fails or returns empty (auth/rate-limit/outage), `OWN_PR` defaults to `false` — never `true` on missing data:
```bash
set -euo pipefail
ME=$(gh api user --jq .login)                                            # Bash, dangerouslyDisableSandbox: true
PR_AUTHOR=$(gh pr view <PR> --json author -q .author.login)
# Fail-closed: OWN_PR=true ONLY when both are non-empty AND match.
# Empty-but-successful lookups (API quirk) → "" != "" is false → OWN_PR=false.
test -n "$ME" && test -n "$PR_AUTHOR" && [ "$PR_AUTHOR" = "$ME" ] && OWN_PR=true || OWN_PR=false
```
Additionally, if `ACTIVE_MODE = local` and `OWN_PR = false`, force this PR's mode to **cloud** (local mode won't run `/review`/Codex/repro on a foreign PR anyway). But note: **a foreign PR in cloud mode still must not have its code executed locally** — steps 3/7/9/10 gate local edits/test/lint/repro/CI-fix on `OWN_PR`, not on mode. `OWN_PR=false` ⇒ no local execution of PR-controlled code anywhere, regardless of mode. `OWN_PR=true` ⇒ local execution is allowed (it's your own code), in whichever mode is active.

Skip the rest of this step only when there is exactly one PR to handle (single-PR run, no other open PRs by the same author).

1. **Build the PR set:**
   - If `$ARGUMENTS` lists explicit PR numbers — use exactly those (this is the only way other authors' PRs enter the queue).
   - Otherwise — current PR plus the author's other open PRs:
     ```
     gh pr list --author "@me" --state open --json number,title,createdAt,headRefName,baseRefName --jq 'sort_by(.createdAt)'
     ```

2. **If the set has exactly one PR** — proceed to step 3.

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

5. Multi-PR planning stays — but the skill no longer merges, so the queue is popped only when the **user** merges a PR (manually or via the step-11 recipe on request). After a user merge, return here: pop the merged PR from the queue, recompute file overlap for the rest (the codebase has changed), and continue with the next PR.

### 3. Verify the PR implements its linked issue 100% (before any review)

Run this **once per PR, before step 4** — do NOT ask the bots to review a half-finished PR. Review bots check whether the *code* is correct, not whether it is *complete* relative to the issue's design; a PR can be approved by both bots and still ship only half of what the issue asked for. Catch that here, up front, not after a wasted review round (or after merging an incomplete issue).

**Ownership-aware (do not execute PR-controlled code for a foreign PR).** The gap-closing work in step 3.4 (implement missing pieces, run the repo's test suite/linter, commit, push) is **only for a PR you own** (`OWN_PR=true`, `author == @me`, per the step-2 gate). For a **foreign PR** (`OWN_PR=false`), this step is **read-only**: read the linked issue and check the diff for completeness, but do **not** write code into the PR, do **not** run its test suite / linter / hooks on your machine. If a foreign PR has a completeness gap, surface it to the user and stop — don't fix someone else's PR locally.

1. **Find the linked issue.** A repo convention may require a closing keyword (`Closes #N`) in every PR. Read the PR body and the structured closing references:
   ```bash
   gh pr view <PR> --json body,closingIssuesReferences \
     --jq '{body, issues: [.closingIssuesReferences[].number]}'
   ```
   If there is no linked issue (e.g. a pure refactor/chore with none) — skip this step and go to step 4.

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
   - Only then proceed to step 4. The bots now review a complete PR in one pass.

   If the gap is large or the issue's design is ambiguous, surface it to the user (with the specific missing deliverables) and ask how to proceed rather than guessing.

5. If the PR fully implements the issue — proceed to step 4.

### 4. Request review

**Local mode is for your own PRs only.** Resolve the author for **each** PR (including every PR in a multi-PR queue) and force cloud mode for anything you didn't author (ownership gate + isolation rationale in step 2):
```bash
ME=$(gh api user --jq .login)                                            # Bash, dangerouslyDisableSandbox: true
PR_SNAPSHOT=$(gh pr view <PR> --json author,headRefOid,baseRefName,baseRefOid)
PR_AUTHOR=$(jq -r '.author.login' <<<"$PR_SNAPSHOT")
if [ "$ACTIVE_MODE" = "local" ] && [ "$PR_AUTHOR" != "$ME" ]; then
  ACTIVE_MODE=cloud
  echo "PR #<PR> is authored by $PR_AUTHOR, not $ME — forcing cloud mode (local review is for your own PRs only)."
fi
```
For a foreign PR, do **not** launch `/review`, the local Codex companion, or any local executable reproduction. If cloud review then cannot run, stop.

**Bind this review round to both sides of the reviewed diff** (head **and** base — base advancement is normal repo activity, and a review against a stale base must not authorize a merge). Resolve all four once, at round start; all review collection, static verification, scratch-worktree reproduction, and triage in this round apply only to this snapshot:
```bash
ROUND_HEAD_SHA=$(jq -r '.headRefOid' <<<"$PR_SNAPSHOT")
ROUND_BASE_REF=$(jq -r '.baseRefName' <<<"$PR_SNAPSHOT")
ROUND_BASE_SHA=$(jq -r '.baseRefOid'  <<<"$PR_SNAPSHOT")
test -n "$ROUND_HEAD_SHA" && test -n "$ROUND_BASE_SHA" || { echo "Could not resolve PR head/base SHA; stop."; exit 1; }
```
Create any scratch worktree at exactly `ROUND_HEAD_SHA`; do not resolve a newer SHA per-finding. (The per-run review-binding record — `author`, `reviewed_head_sha`, `reviewed_base_ref`, `reviewed_base_sha` — is written only in step 6's terminal-success transition and consumed in step 11; nothing is written here.)

**Branch on the active mode (step 1).**

**Cloud:** ping the configured bots. **Local:** run the built-in `/review` (plus Codex when `@codex` is configured). In both modes, launch everything that runs in parallel up front, then step 5 waits (cloud) or step 6 collects (local).

#### Cloud — ping the bots (SHA-attested)

**Record object-ID floors before the request** so step 6 can tell this round's reviews from older ones (defeats reuse of an old review of the same SHA). Resolve `REPO_NWO` **first** (it's used by both queries), then run them under `set -euo pipefail` so a failed `gh api` (outage/rate-limit) **aborts** instead of silently leaving a floor at `0` (which would make old objects look new):
```bash
set -euo pipefail
REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner)                 # Bash, dangerouslyDisableSandbox: true
ROUND_REVIEW_ID_FLOOR=$(gh api --paginate "repos/$REPO_NWO/pulls/$PR/reviews?per_page=100" | jq -s '[(add // [])[]? | .id] | max // 0')
ROUND_INLINE_ID_FLOOR=$(gh api --paginate "repos/$REPO_NWO/pulls/$PR/comments?per_page=100" | jq -s '[(add // [])[]? | .id] | max // 0')
```
Ping **all configured reviewers in a single comment** — concatenate every configured mention, space-separated, at the start of the body, **and name the exact head SHA** so reviewers (and step 6) bind the review to `ROUND_HEAD_SHA`:

| Configured reviewers | Mention string `<MENTIONS>` |
|---|---|
| both `@claude` and `@codex` | `@claude @codex` |
| only `@claude` | `@claude` |
| only `@codex` | `@codex` |

Then post one comment:
```
gh pr comment <PR> --body "<MENTIONS> review PR #<PR> at exact head <ROUND_HEAD_SHA> (round <ROUND_NONCE>). Focus on critical issues: bugs, security vulnerabilities, logical errors, data loss risks, performance problems. Do NOT nitpick style, naming conventions, minor formatting, or subjective preferences — only flag issues that could break functionality or cause real harm in production."
```
For example, with both configured the body starts with `@claude @codex review PR #<PR> at exact head <ROUND_HEAD_SHA> (round <ROUND_NONCE>).`. Run via `Bash` with `dangerouslyDisableSandbox: true`. **Generate a unique round nonce and capture the request comment's ID + timestamp** (step 6 needs them for causally-bound completion — the nonce proves a reviewer's response is for *this* round, not a delayed edit from the previous one):
```bash
ROUND_NONCE=$(uuidgen | tr 'A-Z' 'a-z')   # cryptographically unique per round — no collision possible across concurrent rounds (date/PID-based nonces collide on macOS where %N is unsupported and subshells share $$)
REQUEST_COMMENT_ID=$(gh pr comment <PR> --body "<MENTIONS> review PR #<PR> at exact head <ROUND_HEAD_SHA> (round $ROUND_NONCE). ..." | grep -oE '[0-9]+$')
ROUND_START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```
Then go to step 5 (wait).

**Attestation (applied in step 6):** GitHub review objects and inline comments carry a `commit_id`. Step 6 accepts, as *this round's* reviewer output, only **new** objects (`id > floor`) whose `commit_id == ROUND_HEAD_SHA`. Issue comments have no `commit_id` — they may supply findings (re-verified against `ROUND_HEAD_SHA`) and **may count as a reviewer completion through the round-bound nonce + timestamp check** (`claude[bot]` issue comment with `updated_at > ROUND_START_TS` AND body contains `ROUND_NONCE` = heard from).

#### Local — built-in `/review` plus Codex when configured

No bot is pinged and no GitHub wait happens. The **built-in `/review` always runs**; if `@codex` is in the reviewers list (step 0), **Codex also reviews locally, in parallel**, and its findings are merged with `/review`'s before triage. (`@codex`-only still runs `/review` too — local mode always includes Claude; the reviewers list only *adds* Codex.)

**Launch both in parallel, then step 6 collects both.**

**Attest reviewer invocation to `ROUND_HEAD_SHA` (local).** Local mode is checked out on the PR branch, so the reviewers' input is the local tree — attest the local checkout is exactly `ROUND_HEAD_SHA` before any reviewer runs, and again after they finish. Immediately before **each** reviewer invoke (Codex companion AND `/review`) and again after all reviewers finish, run these checks in one bash:
```bash
test "$(git rev-parse HEAD)" = "$ROUND_HEAD_SHA" || { echo "Local HEAD != ROUND_HEAD_SHA; discard round."; exit 1; }   # Bash, dangerouslyDisableSandbox: true
test -z "$(git status --porcelain --untracked-files=all)" || { echo "Working tree dirty; discard round."; exit 1; }
```
Any mismatch before an invoke → do **not** invoke that reviewer; discard the round and stop or restart step 4. Any mismatch after the reviewers finish → ignore all local results from this round and stop or restart step 4. Tag each accepted local reviewer result `reviewed_sha: ROUND_HEAD_SHA`. (These checks attest the launch decision; they do not sandbox or redesign the vendor reviewer. Base-binding is re-verified from the GitHub PR object in step 6 before persisting — local refs can drift, so the authoritative base is `gh pr view`, not the local checkout.)

1. **Start Codex first (background) when `@codex` is configured**, so it runs while `/review` works:
   - **Resolve the companion path — manual override first, then the installed-plugins manifest; never hardcode the source namespace or path layout.** If `CYCLE_REVIEW_CODEX_COMPANION_PATH` is set and points at an existing file, use it directly as `$COMPANION` and skip the manifest resolver. This is the escape hatch for installs the manifest structurally cannot see — most commonly a manual dev symlink (e.g. `~/.claude/skills/codex` → a local git clone) that never went through `/plugin install`. Setting this var is an explicit, deliberate act by the user in their own shell profile — that intent is what authorizes running the resolved script with `dangerouslyDisableSandbox: true`, same basis as an `installed_plugins.json` hit. A set-but-broken override (non-empty but the file doesn't exist) fails closed — it does not silently fall back to the manifest resolver, since that would mask the user's typo.

     Otherwise, resolve from `~/.claude/plugins/installed_plugins.json`, the canonical plugin→installPath index (`{ "version": 2, "plugins": { "<name>@<marketplace>": [{ installPath, version, scope, projectPath, lastUpdated, ... }] } }`). Filter carefully, because the chosen script runs with `dangerouslyDisableSandbox: true` (network) — a wrong pick can execute an unrelated plugin impersonating the reviewer:
     1. **Only `scope: "user"` entries.** A `user`-scoped install is globally enabled and valid in any repo. `local`/`project` entries are tied to another repo's `projectPath` and must NOT be eligible outside it — never run a plugin the user only enabled for a different project.
     2. **Explicit codex names only.** Match the plugin name (the part before `@`) against an allowlist of known codex plugins — `codex` (upstream `codex@openai-codex`) and `codex-fork` (`codex-fork@etopro-plugins`). A loose substring match (`codex`) risks catching an unrelated plugin whose name merely contains it.
     3. **Newest `lastUpdated` first.** Among the surviving entries, order by `lastUpdated` descending — that is the actively installed version, NOT the newest version sitting in the file cache (the cache holds leftovers the GC sweeps away; `.in_use/` PID-markers only protect from sweep, they don't pick the version).
     4. **Probe both path layouts, first existing wins** (preserving the timestamp order above — do NOT re-sort by path): the fork is a meta-plugin wrapping a `codex` sub-plugin (`<installPath>/plugins/codex/scripts/codex-companion.mjs`); the upstream direct plugin is `<installPath>/scripts/codex-companion.mjs`.

     Run both checks in one bash invocation (plain shell, no network — does not itself need `dangerouslyDisableSandbox`; only the companion invocation further below does):
     ```bash
     COMPANION=""
     OVERRIDE_BROKEN=false
     if [ -n "${CYCLE_REVIEW_CODEX_COMPANION_PATH:-}" ]; then
       if [ -f "$CYCLE_REVIEW_CODEX_COMPANION_PATH" ]; then
         COMPANION="$CYCLE_REVIEW_CODEX_COMPANION_PATH"
       else
         OVERRIDE_BROKEN=true
         echo "CYCLE_REVIEW_CODEX_COMPANION_PATH is set but does not point at an existing file: $CYCLE_REVIEW_CODEX_COMPANION_PATH" >&2
       fi
     fi
     if [ -z "$COMPANION" ] && [ "$OVERRIDE_BROKEN" = false ]; then
       COMPANION=$(jq -r '
           .plugins | to_entries[]
           | select(.key | split("@")[0] | test("^codex(-fork)?$"))
           | .value[]
           | select(.scope == "user")
           | select(.installPath and (.installPath | length > 0))
           | "\(.lastUpdated // "")\t\(.installPath)"
         ' "$HOME"/.claude/plugins/installed_plugins.json 2>/dev/null \
         | sort -r | while IFS=$'\t' read -r _ ip; do
             for cand in "$ip/plugins/codex/scripts/codex-companion.mjs" "$ip/scripts/codex-companion.mjs"; do
               [ -f "$cand" ] && { echo "$cand"; break 2; }
             done
           done)
     fi
     ```
     **`OVERRIDE_BROKEN` gates the manifest resolver, not just an empty `$COMPANION`** — a broken explicit override must fail closed, never silently fall through to a different executable the user didn't name. If `$COMPANION` is empty because `OVERRIDE_BROKEN=true`, stop with the broken-override message (step 6) — do NOT consult the manifest. If `$COMPANION` is empty and `OVERRIDE_BROKEN=false` (override unset), the codex plugin is **not installed** at user scope via the marketplace — treat as the plugin-not-found fail-closed case in step 6.

     > Why not `${CLAUDE_PLUGIN_ROOT}`? That env var is substituted by Claude Code only inside the *owning* plugin's commands/hooks — in a cycle-review session it points at cycle-review (or is unset), so it can't address a sibling plugin. `installed_plugins.json` is the only cross-plugin source of truth for install paths.
   - **Base for the review is the round's immutable base SHA** (`ROUND_BASE_SHA` from step 4) — pass that, **not** the mutable branch name. The companion resolves `--base` via local `git merge-base`/`git diff`, so a mutable name (e.g. `main`) would let a stale local ref review the wrong diff while the record stores the current remote base SHA.
   - **Detect dev mode (codex-fork) from the resolved path**, then build the optional `--model`/`--effort` flags from config + per-run override. Dev mode is on when the companion path contains a `-fork/` segment:
     ```bash
     CODEX_FORK=false
     case "$COMPANION" in *-fork/*) CODEX_FORK=true;; esac
     CODEX_FLAGS=""
     if [ "$CODEX_FORK" = true ]; then
       CODEX_MODEL=$(jq -r '.codex_model // empty' "$HOME/.claude/cycle-review/config.json" 2>/dev/null)
       CODEX_EFFORT=$(jq -r '.codex_effort // empty' "$HOME/.claude/cycle-review/config.json" 2>/dev/null)
       [ -n "$RUN_MODEL" ]  && CODEX_MODEL="$RUN_MODEL"     # per-run override from step 1
       [ -n "$RUN_EFFORT" ] && CODEX_EFFORT="$RUN_EFFORT"
       [ -n "$CODEX_MODEL" ]  && CODEX_FLAGS="$CODEX_FLAGS --model $CODEX_MODEL"
       [ -n "$CODEX_EFFORT" ] && CODEX_FLAGS="$CODEX_FLAGS --effort $CODEX_EFFORT"
     fi
     ```
     `CODEX_FLAGS` is left empty on upstream codex (`CODEX_FORK=false`) and when no model/effort is configured — the companion then uses its own defaults (the pre-dev-mode behavior). Values are not re-validated here; the companion validates `--model`/`--effort` itself and a bad value surfaces as stderr → step 6 fail-closed.
   - **Invoke the companion in the background, JSON output, against the PR base:**
     ```bash
     node "$COMPANION" adversarial-review --wait --json --base "$ROUND_BASE_SHA" $CODEX_FLAGS \
       "Critical-only review of PR #<PR>: bugs, security vulnerabilities, logical errors, data-loss risks, performance problems. Do NOT nitpick style, naming, formatting, or subjective preferences."
     ```
     Run via **`Bash` with `run_in_background: true`** *and* `dangerouslyDisableSandbox: true` (Codex needs network). `--wait` keeps it blocking *inside* the backgrounded bash, so the background handle completes only when Codex is done. **Record the returned background shell id** as `$CODEX_SHELL_ID` — it is consumed by the live-progress Monitor in step 4.3, which streams Codex's stderr to the user while it runs (Codex otherwise runs silently in the background).

2. **Run the Claude review by invoking the built-in `/review` via the `Skill` tool** — do NOT spawn a custom review subagent. `/review` is the canonical Claude Code PR-review command (read-only, single-pass; maintained upstream), and this skill rides on its improvements instead of re-implementing review logic. Because Codex is already running in the background, the two reviews overlap.
   - **Invoke via the `Skill` tool.** Call `Skill({ skill: "review", args: "<PR#>" })`. This is the ONLY programmatic path — do not try to type a literal `/review <PR>` into the chat (the model can't do that), do not shell out via Bash, do not spawn an Agent. `/review` is one of the built-ins explicitly exposed through the `Skill` tool (per `/skills` docs: `/init`, `/review`, `/security-review`). `Skill` is in this skill's `allowed-tools` for exactly this call.
   - **Read the review directly — no parser, no steering, no format contract.** `/review` is read-only and posts nothing to GitHub; it writes its review as an assistant message in THIS skill's own context (verified empirically). You — the agent running the cycle — read that review with your own judgment and extract its findings into the common finding shape exactly the way you read any reviewer comment: each distinct issue the review raises → a finding with whatever `path`/`line` the review points at (often none), a short `title`, the concrete `claim`, and `evidence: "/review-reported; re-verify in triage"`. Tag each `reviewer: claude`. Do NOT try to coerce `/review` into a fixed line format — it writes free-form prose with sections/bullets, and that is fine; you triage prose the same way you triage a human or bot comment in step 6.

3. **Stream Codex's live progress to the user, then collect the output** (only if Codex was launched). The complaint this step fixes: a backgrounded Codex runs silently — the user sees nothing and waits on "who knows what." Codex actually writes its progress to stderr as it runs (`[codex] Thinking.`, `[codex] Running command: …`, `[codex] Turn completed.`), so **stream that progress to the user while Codex is running**, and only then collect the final result.

   **(a) Live-progress Monitor (run it while `/review` is working too — the two overlap).** Start a `Monitor` over `$CODEX_SHELL_ID` that polls `BashOutput` roughly every 10s, prints each line not yet shown (track a "last-seen-line" cursor so you don't re-print), and stops once the background task's status flips to `completed`/`exited`. **The background shell id is a Claude Code task id, NOT a unix PID** — do not use `kill -0` to test liveness; read the status reported by `BashOutput`/the task. After it exits, drain the final buffer once more so the trailing `[codex]` lines aren't lost. Pseudocode:
   ```
   # Monitor loop, ~10s cadence, while the Codex task is still running:
     out  = BashOutput($CODEX_SHELL_ID)
     print(out.lines_after(last_seen_cursor))   # the new [codex] … lines → user sees the review happen
     last_seen_cursor = out.line_count
     if out.status in {completed, exited}: break
     sleep 10
   # task ended — one last drain for the tail
   print(BashOutput($CODEX_SHELL_ID).remaining_lines)
   ```
   (One `Monitor` call, an `until`/`sleep` loop of `BashOutput`, or the runtime's equivalent — `BashOutput` and `Monitor` are in `allowed-tools` for this.)

   **(b) Collect the final output (after the Monitor ends / the shell exits).** Read the full `BashOutput` of `$CODEX_SHELL_ID`: the JSON is on **stdout**, the progress log on **stderr**, and the shell's **exit code** is reported in the background-task status. Capture the stdout JSON → step 4.5 maps it to findings. **Do not proceed until the background shell has exited** — a still-running Codex is not a result. (If the `Skill` `/review` call errored, see the fail-closed in step 6 regardless of Codex's result.)

4. **Fail-closed check (Codex configured but did not return a verdict).** **Detection is one rule, cause-agnostic: if Codex returned no parseable `.result` this round — companion missing, non-zero exit, or exit-0 with empty/`.parseError`/absent `.result` — it is silent, and silence is not approval** (root invariant in `## Important`). Every silent shape stops the same way; do NOT continue on `/review` alone. The cause only shapes the *user-facing message*:
   - **Companion not found** (`$COMPANION` empty): if `OVERRIDE_BROKEN=true` (the resolver printed a `CYCLE_REVIEW_CODEX_COMPANION_PATH ... does not point at an existing file` line to stderr), surface that exact message and stop — the manifest resolver was deliberately **not** consulted (fail-closed on the override, not a fallback), so do not run a manifest-found companion instead. Otherwise (`OVERRIDE_BROKEN=false`, override unset): the codex plugin is not installed at user scope and no override was set: tell the user both remediation paths in one message — "Codex plugin not found. If you installed it via `/plugin`, check it's user-scoped (not local/project). If you're running a manual/dev install not registered in `installed_plugins.json`, set `CYCLE_REVIEW_CODEX_COMPANION_PATH=/path/to/codex-companion.mjs` in your shell profile and re-run." Do **NOT** suggest `codex login` here — nothing to log in to yet.
   - **Non-zero exit** — read stderr for the message (the stop decision does not depend on it): install/login text (e.g. `npm install -g @openai/codex`, `codex login`) → ask to install/log in; upstream/server text (5xx, `503`, `circuit_open`, throttling, timeout) → tell the user Codex's upstream is unavailable; anything else → report the exact stderr. (This list is a heuristic for the message, not a detection allow-list — `any other non-zero exit` is still silent.)
   - **Exit-0 but no parseable `.result`** (empty stdout, `.parseError`, or `.result` absent): Codex ran but returned nothing usable — silent, not clean. (Overlaps step 4.5's parse check; both must stop.)

   Do **NOT** finalize or tell the user the PR is ready. This step **detects** silence; the cycle's *reaction* (retry the round up to 2×, then STOP — with the optional user-gated cloud fallback in step 6.x offered first when `ACTIVE_MODE=local` and `OWN_PR=true`) is defined at the finalize gate (step 6). (When `@codex` is *not* configured, there is no Codex run and nothing to fail-closed on.)

   **`/review` fail-closed (single rule):** if the `Skill` call errored or `/review` produced no review at all (empty / refused), no Claude review happened — STOP, do NOT finalize. A review that lists no issues is a clean review (proceed); a review that didn't happen is silence (stop). The invariant: **never finalize on silence** — a missing review is not a clean review.

5. **Parse Codex JSON and map to the common finding shape.** The companion's `--json` stdout is an object whose **`.result`** field holds `{ verdict, summary, findings[], next_steps[] }`. Read `.result.findings[]` (e.g. `<json> | jq '.result.findings'`). If `.result` is absent but `.parseError` is set, surface that Codex produced unparseable output and treat it like an unavailable reviewer (fail-closed — do not silently drop). Map each Codex finding to the same common shape you read `/review`'s findings into (the `/review` block above) so step 6 triages them uniformly:
   | Codex field | Common finding field |
   |---|---|
   | `title` | `title` |
   | `file` | `path` |
   | `line_start` (use `line_start`; `line_end` only for range display) | `line` |
   | `severity`: `critical`/`high` → `critical`; `medium`/`low` → `minor` | `severity` |
   | `body` (+ `recommendation` appended) | `claim` |
   | "Codex-reported; re-verify in triage" | `evidence` |

   Tag each mapped finding with its source (`reviewer: codex`) so the step-6 summary can attribute it.

6. **Merge** the Codex-mapped findings with the `/review` findings into one list. De-dup obvious overlaps by `path`+`line`+gist (keep the higher severity; note both reviewers flagged it). This merged list is the local "comment set" carried into step 6.

7. **Persist this round's merged findings to a per-run file in the OS temp dir** (so step 9 can re-read findings from EVERY prior round — `/review`'s output lives only in chat and is otherwise lost once the conversation moves on, and Codex's JSON stdout is ephemeral). Use `${TMPDIR:-/tmp}/cycle-review/` (OS-standard temp — macOS `$TMPDIR`, Linux `/tmp`; these are ephemeral run artifacts, not user config). After the merge above, write the merged findings to `${TMPDIR:-/tmp}/cycle-review/<PR>-round<N>.json` where `<PR>` is the PR number and `<N>` is the current cycle number (1/2/3 — same counter the step-6 finalize gate tracks). Build it with `jq -n` so the JSON is always well-formed; one object per round:
   ```json
   {
     "pr": <PR>, "round": <N>, "timestamp": "<ISO 8601 from date -u +%Y-%m-%dT%H:%M:%SZ>",
     "findings": [
       {"reviewer": "claude", "path": "<path>", "line": <int>, "title": "<title>", "claim": "<claim>", "severity": "minor"},
       {"reviewer": "codex",  "path": "<path>", "line": <int>, "title": "<title>", "claim": "<claim>", "severity": "<critical|minor>"}
     ]
   }
   ```
   `mkdir -p "${TMPDIR:-/tmp}/cycle-review/"`. Tag every finding with its `reviewer` (`claude` for `/review`, `codex` for Codex) so step 9 and the step-6 summary can attribute. Do NOT clean these files up at the end of the run — they are how step 9 reconstructs prior rounds; if a re-run repeats a round number, overwrite that file in place (the latest triage of round N wins). (Config stays at `~/.claude/cycle-review/config.json` — only run artifacts move to temp.)

These merged findings are the local equivalent of "reviewer comments" — carry them straight into step 6's triage. Step 6 still assigns the `FIX`/`SKIP`/… verdicts and is the single place merge-readiness is decided; it re-verifies every claim there. Codex's findings are **not** exempt from claim-verification — treat a Codex `claim` exactly like a bot comment that may hallucinate. Skip step 5 entirely in local mode and go to step 6.

`/review` is a read-only single-pass review (NOT the multi-agent, confidence-scored `/code-review` skill — a different command). Do not add extra Claude review subagents on top of it: rely on `/review`'s findings plus Codex's. Only if the user explicitly asks for an extra adversarial pass would you spawn additional review subagents and merge their findings alongside `/review`'s and Codex's before triage — optional, scale to the request.

### 5. Wait for reviewer response — **cloud mode only**

**Local** has no GitHub bot to wait for, and `/review` is synchronous (its assistant message lands as soon as the `Skill` call returns — there is nothing to poll). The only asynchronous bit — the backgrounded Codex run — is already collected in step 4.3. So in local mode skip step 5 and go to step 6.

**Cloud** — give the bots a fixed window to respond, then move on. The waiter does **not** try to detect "who finished" — that's triage's job (step 6 reads every comment and decides). It just waits, then confirms the API is reachable so an outage can't masquerade as "no findings".

Run the committed driver `wait-for-reviews.sh` (beside this `SKILL.md`) via `Bash` with **both** `run_in_background: true` and `dangerouslyDisableSandbox: true` — the sandbox blocks TLS to api.github.com, and a *leading* `sleep N && …` is blocked by the runtime, but the `sleep` *inside* this backgrounded script is fine:
```bash
OWNER=<owner> REPO=<repo> PR=<PR> WAIT=300 \
  bash "<path-to-skill-dir>/wait-for-reviews.sh"
```
- `WAIT` defaults to 300s (5 min), which covers Codex (~5 min) and Claude (~2 min). Raise it for unusually slow bots.
- The script prints exactly **one** line:
  - `DONE` → the window elapsed and the API is reachable. Proceed to step 6 and triage whatever comments exist.
  - `ERROR <reason>` → the PR's comments could not be read after several tries (a sustained API outage — expired auth, rate limit, network). This is **not** "no findings". Stop the cycle, tell the user (e.g. check `gh auth status`), and do **not** merge.

There is no per-reviewer status, no state file, and nothing to resume — each new round just posts a fresh request (step 4) and runs the waiter again. If the background run is lost, re-run the same command; a fresh wait is harmless.

**Where each bot posts** (useful for triage in step 6 — the waiter ignores this and just waits a fixed window):

| Handle | Mention (step 4) | Bot login | Where its review lands | Clean signal (no blocking issues) |
|---|---|---|---|---|
| `@claude` | `@claude` | `claude[bot]` | edits a single **issue comment** in place; starts with `Claude finished @<user>'s task` | text: `No critical issues found` / `Новальных критических проблем нет`; after fixes: `Все замечания устранены корректно` + `Новальных критических проблем нет` |
| `@codex` | `@codex` | `chatgpt-codex-connector[bot]` | a **PR review** object (`### 💡 Codex Review`) + inline comments with severity badges (`P1`/`P2`), OR an issue comment `Didn't find any major issues. Hooray!` | **absence** of review-object (👍 reaction), OR issue comment with `Didn't find any major issues` |

**Anti-patterns — do NOT use:**
- `Bash("sleep 120 && gh ...")` — a *leading* `sleep` is blocked by the runtime. The `sleep` inside the backgrounded waiter is fine.
- `Bash("sleep 60 && sleep 60 && ...")` — chained short sleeps are blocked too.
- `Monitor("until gh api ...; do sleep 30; done")` — `gh api` fails inside the sandbox because of TLS interception.
- Any `gh ...` call without `dangerouslyDisableSandbox: true`.

### 6. Analyze and triage

**Comment source depends on the mode (step 1):**
- **Cloud** — the reviewer comments fetched from GitHub (the three surfaces below).
- **Local** — the **merged** findings (`/review` + Codex when `@codex` is configured) produced in step 4. `/review`'s findings are the issues you read out of its review (free-form prose — no fixed format; you extract them by judgment, like any reviewer comment); Codex findings from its JSON. You do not re-fetch GitHub comments to obtain the findings, though a human may also have left comments — read those too if present.

#### Fetch comments (cloud mode)

Read all comments and review comments from **all reviewers** (bot and human), **attested to this round's `ROUND_HEAD_SHA`**. Review objects and inline comments carry `commit_id`; accept only **new** ones (`id > floor`) with `commit_id == ROUND_HEAD_SHA`. Issue comments have no `commit_id` — they supply findings (re-verified against `ROUND_HEAD_SHA`) and **may count as a reviewer completion through the round-bound nonce + timestamp check** (`claude[bot]` issue comment with `updated_at > ROUND_START_TS` AND body contains `ROUND_NONCE`). Fetch under **`set -euo pipefail`** so that a failed `gh api` **aborts the whole triage** (not just sets a non-zero status that later commands ignore). Without `set -e`, `pipefail` alone lets a later successful fetch mask an earlier failure → silently dropped surface → merge authorizes without critical findings:
```bash
set -euo pipefail
# Issue comments (Claude edits its single one here) — no commit_id; findings + round-bound completion via updated_at:
gh api --paginate repos/{owner}/{repo}/issues/{PR}/comments | jq -s '[.[][] | {id, user: .user.login, body, created_at, updated_at}]'
# PR review objects attested to ROUND_HEAD_SHA (Codex posts its review summary here). Accept only id > ROUND_REVIEW_ID_FLOOR and commit_id == ROUND_HEAD_SHA (paginate; pipe — gh api does NOT forward jq --arg/--argjson):
gh api --paginate repos/{owner}/{repo}/pulls/{PR}/reviews | jq --arg sha "$ROUND_HEAD_SHA" --argjson floor "$ROUND_REVIEW_ID_FLOOR" -s '[(.[][] ) | select((.id > $floor) and (.commit_id == $sha) and (.state != "PENDING")) | {id, user: .user.login, state, commit_id, body}]'
# PR INLINE review comments — line-level findings on the diff. CRITICAL: Codex (and Claude's inline notes) post actionable issues HERE, and the review-objects fetch above does NOT return them. Attest: id > ROUND_INLINE_ID_FLOOR and commit_id == ROUND_HEAD_SHA (paginate; pipe):
gh api --paginate repos/{owner}/{repo}/pulls/{PR}/comments | jq --arg sha "$ROUND_HEAD_SHA" --argjson floor "$ROUND_INLINE_ID_FLOOR" -s '[(.[][]) | select((.id > $floor) and (.commit_id == $sha)) | {id, user: .user.login, path, line, commit_id, body, created_at}]'
```
Process comments from **all three surfaces** and from every reviewer, not just `claude[bot]`. An inline review comment with an actionable finding is a first-class triage input, exactly like an issue comment.

#### Triage (both modes)

Launch a **triage** subagent (Agent tool — this is the triage engine, distinct from any review subagent) to triage each comment (cloud) or each finding (local, from `/review` + Codex). The subagent must:
- Read the current code of files referenced in the comments
- Check whether the issue was already fixed in previous commits (compare with what the reviewer is requesting)
- Assess severity: critical (bug, security, logical error) vs cosmetic (style, naming, formatting)
- Check relevance: does the comment actually relate to this PR's code? The reviewer may be mistaken — referencing non-existent files, confusing function names, or providing feedback that clearly belongs to a different project/PR. Mark such comments as `IRRELEVANT`
- Check consistency: does the comment contradict previous comments from the same or another reviewer? If the reviewer asks for X now but asked for not-X in the previous cycle — mark as `CONFLICTING`
- **Verify every claim before assigning `FIX`** — and pick the verification tool that matches the claim's type. Decompose each finding into:
  - **FACTUAL premises** (state of the repo: "function doesn't exist", "operator is `==`", "import missing", "line N is X") — decidable from Read/Grep/static tooling. Confirm or refute by reading the code. A true factual premise is **not by itself a defect** — also identify the violated contract/invariant/reachable impact. If a material factual claim is demonstrably false → `HALLUCINATION`.
  - **BEHAVIORAL conclusions** (runtime: "crashes on empty input", "race under X", "off-by-one at boundary", "returns wrong value for Y") — grep confirms the code *looks* that way but does **not** prove it's a bug. Requires a stated **oracle** (spec, invariant, compatibility contract, established behavior) **plus** runtime evidence. Apply the TDD evidence gate below.
- **Executable evidence gate for BEHAVIORAL claims — conservative execution, not isolation.** A prompt-only skill is **not** a security boundary. A scratch worktree separates files and pins a revision; it does **not** sandbox execution. An allowlisted command name does not make execution safe either — `pytest` may load PR-controlled `conftest.py` and plugins, and repo test runners / build files / package hooks / config may execute arbitrary PR-controlled code.
  - **Before executing any reproducer, make an explicit trust decision.** Treat every repo test command as arbitrary code execution from the PR. Run it only when **all** of these are true:
    1. **The PR is authored by you** (`author == @me`, the authenticated user) — this is the only accepted trust basis; there is no "known collaborator" carve-out. (Secondary check — step 2 already forced foreign PRs to cloud.) **Executable evidence (local reproduction) is for your own PRs only.** For any other PR, do not run a reproducer at all — the behavioral claim is `UNVERIFIED`, which blocks finalization; the PR must be reviewed in **cloud** mode (vendor runner provides the isolation/atomicity the skill can't — see step 4).
    2. Executing arbitrary code from the pinned PR SHA with the current process's ambient filesystem, credentials, and network access would be acceptable.
    3. The PR contains **no** suspicious or unexpected changes to test bootstraps, `conftest.py`, test plugins, runner scripts, build/package hooks, dependency-install paths, or command config.
    4. The reproducer uses only the repo's already-established, allowlisted test command. It requires **no** dependency install, bootstrap script, arbitrary PR-supplied script, elevated privilege, secret, external service, or destructive operation.
    5. Safety does not depend on a filesystem/credential/network/process restriction that this prompt cannot enforce. If a real sandbox would be required to make execution acceptable, do **not** execute.
  - If any condition is false or uncertain → **do not run the reproducer**. Assign **`UNVERIFIED`**, record which trust/execution condition prevented runtime verification, and let the existing `UNVERIFIED` gate stop finalization. **Never** downgrade "can't execute safely" into `HALLUCINATION`.
  - If execution is permitted: use the scratch worktree only for revision pinning and working-tree separation (create it at the round's `ROUND_HEAD_SHA` from step 4 — see below). Run **exactly** the allowlisted test command against that pinned SHA, record command + SHA + oracle + result, and clean up the worktree after. Do **not** describe the execution as isolated or sandboxed unless the runtime independently enforces such a boundary.
  - Outcomes:
    - A **deterministic red** result against a valid oracle → supports `FIX` (carry the test patch into step 7).
    - A result **positively disproving** the complete claim → `HALLUCINATION`.
    - An **inconclusive** result, an unsafe execution decision, a missing environment, or a missing deterministic test seam → `UNVERIFIED`.
    - A red test **alone is not proof** of a bug — require both the failing behavior and a violated spec/invariant/compatibility-contract/established-behavior before `FIX`.
  - **When executable evidence doesn't apply** (textual/docs/style/naming/architecture findings with no executable acceptance criterion, a repo with no test framework, or an untrusted PR where the trust conditions above fail) — fall back to factual/static verification; do not force an execution.
  - The skill does not configure, emulate, or redesign runtime sandboxing — real isolation belongs to the runtime (per the vendor-mechanic principle in `## Important`). This gate decides only whether executing PR-controlled code is acceptable; otherwise it fails closed as `UNVERIFIED`.
- Return a list of comments with a verdict: `FIX` (needs fixing), `ALREADY_FIXED` (already resolved), `SKIP` (cosmetic), `IRRELEVANT` (unrelated to this PR), `CONFLICTING` (contradicts previous comments), `HALLUCINATION` (a material claim is demonstrably false), `UNVERIFIED` (claim could not be confirmed or refuted with the evidence the cycle can produce — needs a reproducer/environment it doesn't have)
- For every result, write a separate `public_summary`: a neutral, one-line interpretation of the verified issue in the triage agent's own words. It is new agent-authored text, not a quote, excerpt, truncation, sanitization, or lightly edited version of the reviewer-provided `title`, `claim`, or body. Reviewer text remains analysis input only. Never copy reviewer-derived text into `public_summary`, even when the source looks harmless.

Triage is still where each gets a `FIX`/`SKIP`/… verdict and where merge-readiness is decided. Treat each finding exactly like a reviewer comment. Codex findings carry `reviewer: codex` and are claim-verified here exactly like bot comments — do not trust Codex's `claim` at face value. `/review` is a single-pass review with NO upstream confidence filtering, so verify each `/review` claim here just as rigorously (LLM reviews hallucinate: non-existent functions, wrong line numbers).

Only fix comments with the `FIX` verdict. For other verdicts — leave a reply comment on the PR with an explanation:
- `ALREADY_FIXED` — specify which commit already addressed the issue
- `SKIP` — explain why the comment is cosmetic and does not affect functionality
- `IRRELEVANT` — politely note that the comment does not relate to this PR's code
- `CONFLICTING` — describe the contradiction in your own words and ask the reviewer to clarify; do not quote either comment
- `HALLUCINATION` — show concrete evidence from the codebase (grep results, file contents) that disproves the reviewer's claim
- `UNVERIFIED` — a behavioral claim that couldn't be confirmed or refuted with the evidence the cycle can produce (no deterministic test seam, missing environment/deps). State what reproducer/environment is missing and that the cycle stopped because of it — do **not** treat it as approved.

In **cloud** mode those replies attach to the bot's existing comments. In **local** mode the findings have no GitHub comment to reply to, so instead **post one summary comment** on the PR recording this round's triage results — the local review is the reviewer of record, so its verdicts must land on the PR. When Codex also ran, attribute each finding to its source (the `Reviewer` column); when `@codex` was not configured, drop that column and the heading's "+ Codex companion".

**Posting the comment is a verified gate, not a soft instruction** — a text "post the comment" is too easy to skip or to satisfy by editing the PR body (`gh pr edit --body`), which is NOT a comment. So: capture the comment id and have `verify-comment.sh` confirm the issue comment actually exists and carries this round's nonce. Local mode has no round nonce yet (step 4 generates one only for cloud pings), so generate it here for the comment marker.

**Reviewer text never crosses into the posting command.** The original reviewer `title`, `claim`, and body are analysis input only. Do not quote, copy, truncate, escape, sanitize, or otherwise transform them for publication. The table's `Finding` cells contain only the triage agent's independently written `public_summary`. This is the security boundary: no reviewer-derived string is ever placed in shell source, a shell variable used for the comment, or a `gh pr comment` argument.

Build the comment directly from agent-authored summaries; no intermediate body file is needed. The nonce is ordinary trusted run data and must remain expanded (an escaped `\$ROUND_NONCE` would land literally and the verifier would return `STALE_NONCE`).
```bash
# Generate (or reuse) the round nonce + start timestamp for the local comment marker.
ROUND_NONCE="${ROUND_NONCE:-$(uuidgen | tr 'A-Z' 'a-z')}"     # Bash, dangerouslyDisableSandbox: true
ROUND_START_TS="${ROUND_START_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
# Each summary below is written independently by the triage agent. It is NOT sourced from
# or derived by copying/editing a reviewer title, claim, or body.
COMMENT_BODY=$(jq -nr \
  --arg nonce "$ROUND_NONCE" \
  --arg summary_1 '<agent-authored interpretation of verified issue 1>' \
  --arg summary_2 '<agent-authored interpretation of verified issue 2>' \
  '"## 🔍 Local review (cycle N) — round \($nonce)
Reviewed locally (`/review` + Codex companion), no bots pinged.

| Verdict | Reviewer | Finding | Location |
|---|---|---|---|
| FIX | claude | \($summary_1) | path:line |
| SKIP | codex | \($summary_2) | path:line |
..."')
SUMMARY_COMMENT_ID=$(gh pr comment <PR> --body "$COMMENT_BODY" | grep -oE '[0-9]+$')
```
The heading MUST include `round <nonce-value>` — `verify-comment.sh` checks the comment body carries that nonce (round-bound, not a reused/old comment). Then immediately verify the comment exists:
```bash
RESULT=$(REPO_NWO="$REPO_NWO" COMMENT_ID="$SUMMARY_COMMENT_ID" NONCE="$ROUND_NONCE" SINCE="$ROUND_START_TS" \
  bash "<path-to-skill-dir>/verify-comment.sh")   # dangerouslyDisableSandbox: true
case "$RESULT" in
  VERIFIED\ *) echo "Local triage-summary recorded (comment $SUMMARY_COMMENT_ID).";;
  *) echo "Local triage-summary NOT recorded (verify-comment.sh: $RESULT). STOP before fixes — do NOT proceed. \
MISSING = the worker skipped the comment or edited the PR body instead of \`gh pr comment\`; \
STALE_NONCE/STALE_TIMESTAMP = a reused/old comment."; exit 1;;
esac
```
All `Bash` calls above run with `dangerouslyDisableSandbox: true`. Only after `VERIFIED` do you proceed to fix the `FIX` items — the gate exists precisely because the soft "post the comment" instruction was being skipped.

#### Decide whether to finalize

Check these in order. The first gate is the **silence gate** (both modes) — it is the heart of "never finalize on silence". The cloud-specific markers below describe *how* to recognize each bot's silence; in local mode the equivalent is "did each configured reviewer actually return a verdict this round" (step 4.4 for Codex, the `/review` fail-closed in step 4 for Claude).
- **(cloud only) Step 5 returned `ERROR`** → do NOT finalize. The comments could not be read (a sustained GitHub API outage), so an empty triage is meaningless, not approval. Notify the user and stop; never let an outage become a silent merge.
- **Silence gate (both modes): every configured reviewer must have returned a verdict this round.** If any configured reviewer is silent — posted nothing new and round-bound this round (cloud), or did not return a parseable review (local) — then no approval happened, **regardless of what the others said**. "No `FIX` verdicts" from a partial review only reflects the reviewers who answered, not the ones who didn't. **Any configured reviewer that stayed silent — for ANY reason (slow bot, usage-limit message, 503/upstream outage, empty parse, "aliens") — blocks finalization.** This must be checked BEFORE interpreting the absence of `FIX` verdicts.
  - **How to recognize each bot's review/silence (cloud)** (studied from real PR comments — these are the markers to look for in step 6's fetched comments/reviews):
  - **`claude[bot]`** edits a single **issue comment** in place. Its comment starts with the marker `Claude finished @<user>'s task` (always present). A **clean** review (no blocking issues) contains text like `No critical issues found` or `Новальных критических проблем нет` (language varies). After a fix cycle, the clean signal is `Все замечания устранены корректно:` + `### Новых критических проблем нет` (the count of fixed issues is in the body, not in the heading). A **blocking** review has `### Issue N` sections. A **usage-limit** message (no `Claude finished`, just a limit notice) means Claude did not review — treat as silence, not approval.
  - **`chatgpt-codex-connector[bot]`** posts a **PR review object** (`state=COMMENTED`) with the heading `### 💡 Codex Review` + inline comments carrying severity badges (`P1`/`P2`/etc). A **clean** Codex review is either: (a) the **absence** of a review-object — Codex reacts with 👍 on the PR instead of commenting, OR (b) an **issue comment** with text like `Codex Review: Didn't find any major issues. Hooray!` + `Reviewed commit: <sha>` (observed on real PRs). A **usage-limit** message (`You have reached your Codex usage limits for code reviews`) means Codex did not review — treat as silence.
  - A reviewer is "heard from" this round only if its review is **round-bound** — new this round, not an old review of a previous SHA. **`commit_id` attestation covers review-objects and inline comments, but NOT issue comments (Claude) or reactions (Codex 👍).** For these, use a round-bound completion signal:
    - **`claude[bot]`** (issue comment): the comment must satisfy **both** conditions: (1) `updated_at > ROUND_START_TS` (edited after this round started), AND (2) the comment body contains the **round nonce** (`ROUND_NONCE` from step 4 — Claude echoes the request context, including the nonce, in its review). This causal binding prevents a delayed edit from the previous round (which has `updated_at > ROUND_START_TS` but the **old** nonce) from authorizing the current head. An old `Claude finished` without the current nonce does NOT count.
    - **`chatgpt-codex-connector[bot]`** (review-object OR 👍 reaction): a new review-object attested to `ROUND_HEAD_SHA` (via the fetch-filter) = heard from. **If no review-object**: check for a 👍 reaction on the round's request comment — `gh api repos/{owner}/{repo}/issues/comments/$REQUEST_COMMENT_ID/reactions` (paginate). A 👍 from `chatgpt-codex-connector[bot]` = heard from + clean. **Absence of BOTH review-object and 👍 = silence**, not clean.
  - If nobody reviewed at all, notify the user and stop. (Local definition of "heard from": each configured reviewer returned a parseable review this round — `/review` produced a review, AND — when `@codex` is configured — Codex returned a parseable `.result` per step 4.4.)
- **No `FIX` and no `UNVERIFIED` verdicts, AND every configured reviewer returned a verdict this round (no silence)** → this is the **final cycle**. (cloud: all configured bots heard from, round-bound; local: `/review` produced a review AND — when `@codex` is configured — Codex returned a parseable review.) (`UNVERIFIED` blocks finalization just like `FIX` — a behavioral claim we couldn't confirm or refute is not approval.) Do not require an explicit `APPROVED` review state — bot reviewers (e.g. `claude[bot]`) rarely emit it; given ALL reviewers answered, the absence of blocking issues IS the approval signal. **Before declaring final**, re-read the PR and confirm the reviewed snapshot is still intact (author + head + base unchanged since round start — base advancement is normal repo activity and must invalidate the round):
  ```bash
  REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner)            # Bash, dangerouslyDisableSandbox: true
  STATE_DIR="${TMPDIR:-/tmp}/cycle-review/$REPO_NWO"; STATE_FILE="$STATE_DIR/$PR-verified.json"; mkdir -p "$STATE_DIR"
  CURRENT=$(gh pr view <PR> --json author,headRefOid,baseRefName,baseRefOid)
  jq -e --arg me "$ME" --arg head "$ROUND_HEAD_SHA" --arg bref "$ROUND_BASE_REF" --arg bsha "$ROUND_BASE_SHA" \
    '(.author.login == $me or $me == "") and (.headRefOid == $head) and (.baseRefName == $bref) and (.baseRefOid == $bsha)' \
    <<<"$CURRENT" >/dev/null || { rm -f "$STATE_FILE" "$STATE_FILE.tmp"; echo "PR head/base changed during review; restart step 4."; exit 1; }
  umask 077
  jq -n --arg author "${ME:-}" --arg head "$ROUND_HEAD_SHA" --arg bref "$ROUND_BASE_REF" --arg bsha "$ROUND_BASE_SHA" \
    '{author:$author, reviewed_head_sha:$head, reviewed_base_ref:$bref, reviewed_base_sha:$bsha}' > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE" || { rm -f "$STATE_FILE" "$STATE_FILE.tmp"; echo "Could not persist review-binding record; stop."; exit 1; }
  ```
  (The `$me == ""` / `ME:-""` carve-out keeps cloud mode, where `ME` wasn't resolved, working — author-binding is a local-mode concern.) Post the replies/summary above for any non-`FIX` comments, then go to **step 9** (final gate — normally a no-op, since the deferred minor findings were already applied in step 7; posts the roll-up summary). After step 9: **both modes** proceed to step 10 (CI watch, read-only; auto-fix a red CI in a PR you own), then **stop and report** — the cycle does not merge (see the step 11 manual recipe).
- **Any `UNVERIFIED` verdict** → do NOT finalize. The cycle cannot prove or disprove the claim with the evidence it can produce. STOP, report the `UNVERIFIED` finding(s) and what reproducer/environment is missing, and hand back to the user — never let an unresolved behavioral claim look like approval.
- **A configured reviewer is silent (silence gate failed) → retry the round up to 2 times, then STOP.** A silent reviewer is often transient (a 503 blip, throttling, a slow bot). So before handing back to the user, re-run the review round (step 4: re-ping the bots / re-run `/review` + Codex) up to **2** times total, re-checking the silence gate each round. If the silent reviewer comes back — proceed normally (triage the merged findings). If, after 2 retries, a configured reviewer is **still** silent: before STOP, if `ACTIVE_MODE=local` and `OWN_PR=true`, offer the **user-gated cloud fallback** in step 6.x (one targeted ping to the silent handle; never automatic). Otherwise **STOP — do NOT finalize, do NOT propose merge, do NOT tell the user "all clear" / "ready to merge".** Report to the user: which reviewer is silent, the observed cause (503 / usage-limit / timeout / unknown), how many rounds were tried, and that the cycle stopped because approval requires **every** configured reviewer to answer. The user then decides: retry later (when the upstream recovers), re-onboard to drop the silent reviewer from the config and re-run with the rest, or defer.

#### 6.x. User-gated cloud fallback (only when a **local** reviewer is silent after retry×2)

If retry×2 above did not bring a silent local reviewer back, the cycle does **not** fall back automatically and does **not** switch `ACTIVE_MODE`. It asks the user once.

**Run one `AskUserQuestion`** (single-select, 2 options). Offered only when **all** of: (a) `ACTIVE_MODE = local`; (b) `OWN_PR = true` (targeted cloud ping on a PR you don't own is not allowed — the cloud bot would act on someone else's PR); (c) exactly one configured reviewer is silent (the other answered); (d) the silent reviewer is `@claude` (`/review`) or `@codex` (the local companion).
- **Question:** "Local reviewer `<handle>` stayed silent after 2 retries (cause: `<503 / outage / unknown>`). Authorize a **targeted cloud fallback ping** to `<@claude|@codex>` for this round only? It posts one PR comment and waits up to 5 min. It does **not** edit, push, or merge, and does not switch the run to cloud mode."
- **Options:** `Authorize targeted cloud ping` / `Do not authorize`.

On **authorize** → run a **targeted** cloud ping to the silent handle only: if `/review` was silent → ping `@claude`; if the local Codex companion was silent → ping `@codex`. Do **not** re-ping the reviewer that already answered. Reuse the existing cloud-attestation machinery from step 4: fresh `ROUND_NONCE`, fresh floors (`ROUND_REVIEW_ID_FLOOR`/`ROUND_INLINE_ID_FLOOR`), exact `ROUND_HEAD_SHA`, `REQUEST_COMMENT_ID` + `ROUND_START_TS`, and a full `WAIT=300` via `wait-for-reviews.sh`. A successful cloud verdict merges with the round's existing local verdict(s) (only when head/base/tree are unchanged since round start — otherwise the round restarts per step 4). The cloud bot's existing clean/silence markers (step 6 finalize-gate) apply to its answer.

On **do not authorize**, timeout, no cloud bot configured for that handle, the cloud bot itself stays silent, or `OWN_PR=false` → **STOP without re-asking**. Report: which reviewer is silent, the cause, that fallback was offered and declined/unavailable, and that the cycle stopped because approval requires every configured reviewer to answer.

**This fallback authorizes only a ping + wait. It does not authorize edit, push, or merge — those still go through the normal cycle flow.** Do not flip `ACTIVE_MODE` to cloud; the run stays local except for this one targeted ping.

- **At least one `FIX`, and this is the 3rd cycle** → STOP, do not start a 4th. The 3-cycle cap exists not as an arbitrary limit but as a **signal**: if you've reached it, the previous fixes likely closed symptoms, not the root cause, and the reviewer keeps finding new variants of the same bug class. **Before handing back to the user, diagnose:**
  - Are the open findings **variants of one root cause**? If so — the previous fixes patched symptoms. Name the **invariant** the bug violates (the violated contract, not the described case), so the user can fix it at the root and close ALL variants at once.
  - Do the findings reveal a **contradiction in the design itself**? If so — that's a signal to **simplify** (not add more gates/complexity). Ask: *"What does this incident mean for the design as a whole?"* — if the answer is a contradiction (e.g., "a prompt-only skill can't be a security boundary"), propose **simplifying the design**, not layering more checks on top.

  Tell the user: why the 3-cycle rule fired, what was diagnosed (invariant violation or design contradiction), and propose — fix the invariant at the root, simplify the design, or move some findings **out of scope** into a follow-up issue/PR. Wait for the user's decision; do not merge and do not auto-loop. (Count a "cycle" as one completed round of steps 4–8, i.e. one review request + triage. The round that produced this 3rd batch of `FIX`s is the 3rd.)
- **At least one `FIX`, and this is cycle 1 or 2** → proceed to step 7.

The cycle counter lives only in your working memory across a long conversation, so make it observable: at the end of every triage, **explicitly state the current cycle number** to the user (e.g. "Triage of cycle 2/3 complete: 1 FIX, 2 SKIP"). This keeps the 3-cycle cap self-checkable instead of relying on hidden state. When a round is instead a re-review (step 8's "cycles vs. re-reviews" rule — triggered by step 9 or step 10, not by a `FIX`), say so explicitly too (e.g. "re-review of cycle 2 after cleanup commit — not cycle 3") so the user can tell real review cycles apart from head-revalidation passes.

### 7. Fix issues (+ apply deferred minor findings)

Only fix comments with the `FIX` verdict from step 6 — and fix them **properly**, not as throwaway patches. Each `FIX` is a bug; treat it as one and run a real bug-fix pipeline, not "edit until it looks right".

**Ownership-aware.** This step (and its test/lint runs) is **only for a PR you own** (`OWN_PR=true`). For a **foreign PR** (`OWN_PR=false`), do **not** edit the PR or run its test suite / linter / reproduction on your machine — `FIX` verdicts on a foreign PR are surfaced to the user (and to the bots in the next cloud round), not applied locally. Fixing someone else's PR locally would execute PR-controlled code with your ambient credentials. (Note: a PR you own in **cloud** mode is still your PR — `OWN_PR=true` — so this step applies normally; ownership, not mode, gates local execution.)

For **each** `FIX` verdict, in turn:

1. **Reproduce it first (test-first).** If step 6 already produced a confirmed reproducing test for this `FIX` (behavioral claim, reproduced in the scratch worktree), **reuse it** — re-apply to the production tree and confirm it still fails for the right reason. Otherwise write a test that **fails** because of the bug — the test must encode the reviewer's claim (read the file/line, confirm the claim in step 6 already verified it's real) and turn red on the current code. Run it and confirm it fails **for the right reason** (the bug), not for a setup/import error. If the repo has no test framework or the bug genuinely can't be reproduced by a test (e.g. a doc-only issue, an architectural concern, a cross-process/race bug with no test seam) — note that explicitly and fall through to the direct fix below, but do not skip the test by default.
2. **Minimal fix.** Make the smallest change that turns the red test green. No refactors, no "while I'm here" edits, no scope creep — the diff must address the bug and nothing else. (Cosmetic/nice-to-have items are `SKIP`s, handled by the deferred-findings pass below, not here.)
3. **Green.** Run the new test plus the **full** suite. The new test passes; nothing else regressed. If a pre-existing test now fails, that's a signal the fix is wrong or too broad — narrow it, don't loosen the test.
4. **Mutation check.** Revert the fix mentally / tweak it: would the test still pass if the fix were subtly wrong (off-by-one, wrong condition, fixed the symptom not the cause)? If yes, strengthen the test until a wrong fix would fail it. The test must actually guard the bug, not just happen to pass.
5. **Lint.** Run the repo's linter (`ruff check src/ tests/` or the repo's equivalent) on the changed files; fix any lint the fix introduced.

**When test-first isn't possible** (step 1 fallback): make the direct fix, but say *why* no test was added (e.g. "doc-only", "no test seam for this race"), and still run the full suite + lint so the change doesn't silently break something. A `FIX` shipped without a reproducing test is the exception and must be justified inline, not the default.

#### Apply deferred minor findings in the same round

Right after every `FIX` is fixed (and only if this round had at least one `FIX` — a fully clean round has nothing pending here, see step 9), apply the minor findings accumulated across earlier rounds **in this same commit/push**, so cosmetic cleanup never trails behind a clean round and never triggers an extra review round on its own:

1. **Gather the minor findings from EVERY previous review round, not just the last one (including this round's own non-`FIX` verdicts).** Re-read all findings across the whole PR history — **cloud**: all three GitHub surfaces (issue comments, PR reviews, inline review comments — same fetch as step 6); **local**: read each prior round's **per-run findings file** written in step 4.7 (each round's merged `/review` + Codex findings persisted at `${TMPDIR:-/tmp}/cycle-review/<PR>-round<N>.json`), plus any human comments on the PR. For both `/review` and Codex, read only those per-run files — neither is persisted anywhere else. Collect every finding that is real and actionable but was not a `FIX`:
   - all `SKIP` (genuine cosmetic/style/naming/minor-improvement findings), and
   - any reasonable nice-to-have the reviewers suggested (e.g. "add a clarifying comment", "rename for clarity", "tidy this helper", "add a migration note") — even when previously deferred as non-blocking.

   Explicitly EXCLUDE the verdicts that have nothing to fix: `HALLUCINATION` (claim is false), `IRRELEVANT` (not this PR's code), `CONFLICTING` (contradictory — ask, don't guess), `ALREADY_FIXED` (already done), and `UNVERIFIED` (unresolved — not deferred-cosmetic; it blocked the cycle, it's not a cleanup item). De-dup findings that recurred across rounds by their substance (use `path` + `line` when present, as on Codex inline comments; otherwise the gist of the body — Claude's single issue comment has no path/line), and skip any that a later commit already addressed.

2. **Apply all of them.** Make the edits, keeping each change minimal and faithful to the reviewer's intent. If a suggested change would be risky, change behavior, or contradicts the repo's conventions, do NOT force it — leave a short reply explaining why it was left out (this is the only thing that may remain unfixed).

3. **Lint and test green**, folded into the same pass as the `FIX` items above — don't run it twice.

Only after every `FIX` is fixed and every deferred minor finding is applied this way does the round proceed to step 8 (commit + push). The linter/test commands above are the same ones step 8 will run before committing — don't duplicate; just keep them green.


### 8. Commit and push
- Commit fixes (and any deferred minor findings applied alongside them, per step 7) with a meaningful message (conventional commits style)
- Push to remote
- Return to step 4 ONLY if fewer than 3 cycles have run. This begins a **new review round**: **cloud** posts a fresh review request and runs the step-5 waiter again (it always waits a clean fixed window — nothing to reset); **local** re-runs `/review` (step 4) against the now-updated diff, plus Codex if configured. Keep a running count of completed cycles (one cycle = one steps 4–8 round **that triaged at least one `FIX`**). **Hard cap: 3 cycles.** If the round you just triaged was the 3rd and it still had `FIX` verdicts, do NOT loop again — stop and hand back to the user per the step-6 "3rd cycle" gate (summarize the open findings, propose moving some out of scope into a follow-up issue/PR, or rethinking the approach). The cap only bites when findings persist; a clean 1st or 2nd round finalizes normally.

**Cycles vs. re-reviews — the cap counts only rounds with a `FIX`.** A return to step 4 triggered by step 9 (a cleanup commit that slipped past step 7) or step 10 (a CI fix) is a **re-review of the same cycle**, not a new cycle — it exists only to re-validate a head that moved after the reviewed snapshot, not to hunt for new findings. Do not increment the cycle counter for these; announce them to the user as "re-review of cycle N after `<cleanup|CI-fix>`", never as "cycle N+1" (this is what the user-visible bug looked like: three review rounds reported as three cycles, when only two were real `FIX`-bearing cycles). To keep a re-review loop from running forever, allow **at most 2 re-reviews per cycle**; if a 3rd is needed, stop and report to the user instead of looping again (mirrors the "same CI check fails >2 times" stop rule in step 10).

### 9. Final gate (last cycle — normally a no-op, plus the roll-up summary)

Reached only on the **final cycle** — when a round has no `FIX` verdicts (step 6) and a real review happened (silence gate passed — step 6 stops the cycle before here if any reviewer is still silent). By this point step 7 has already applied the deferred minor findings that existed when the fixing round ran, so this step is normally just a gate-check plus the summary post — **it should find nothing left to apply**. It exists to catch the one case step 7 can't cover: a round that was clean *from the start* (no `FIX`, so step 7 never ran) but still has un-applied `SKIP`/nice-to-have findings sitting from earlier rounds.

**Ownership-aware.** Applying any edit here (and running the test suite/linter) is **only for a PR you own** (`OWN_PR=true`). For a **foreign PR** (`OWN_PR=false`), this step is a **no-op**: do not edit the PR or run its tests/linter locally — any remaining `SKIP`/nice-to-have findings are surfaced to the user and the bots, not applied on your machine.

1. **Re-check for any still-unapplied minor finding**, using the exact same gather-and-dedup procedure as step 7's deferred-findings pass (same sources, same include/exclude list, same de-dup by `path`+`line`/gist) — but this time also excluding anything step 7 already applied earlier in this cycle. Two outcomes:
   - **Nothing left (expected case)** — this step is a **no-op**: no commit, no push, the review-binding record stays intact. Tell the user plainly, e.g. "Deferred minor findings were already applied in step 7 of this cycle — nothing left to clean up." Skip straight to the summary post below, then step 10.
   - **Something is still there (only possible when this round had zero `FIX`, so step 7 never ran)** — apply it now, following the same rules step 7 uses:
     2. **Apply all of them.** Make the edits, keeping each change minimal and faithful to the reviewer's intent. If a suggested change would be risky, change behavior, or contradicts the repo's conventions, do NOT force it — leave a short reply explaining why it was left out (this is the only thing that may remain unfixed).
     3. **Lint and test green**, same as step 7 (`ruff check src/ tests/`, `pytest tests/ -v` — or the repo's equivalents).
     4. **Commit and push** (conventional-commits style, e.g. `chore: apply non-blocking review nitpicks before merge`). On the PR, briefly note that the deferred minor findings were applied in `<sha>`.
     5. **A cleanup commit invalidates the review-binding record.** If this pass changes or pushes any file, the PR head has moved off the reviewed `ROUND_HEAD_SHA` — the binding no longer holds. Delete the record **before the first cleanup edit** (not after the push), then make the edits, commit, push, and **return to step 4 as a re-review of this same cycle** (per step 8's "cycles vs. re-reviews" rule — this does NOT consume one of the 3 cycles, and is capped at 2 re-reviews before stopping) for a fresh clean review of the new head (do **not** proceed straight to CI/merge on a post-review commit):
        ```bash
        rm -f "$STATE_FILE" "$STATE_FILE.tmp"   # before the first cleanup edit, if anything will be changed/pushed
        ```
        Then: **both modes** proceed to step 10 (CI watch, read-only) once that re-review comes back clean, then **stop and report**. The record persists for the manual-merge recipe (step 11), which the user may run later — it is not part of the cycle.

**Post a final review-summary table on the PR** (both modes). Accumulate from **every** prior review round — include findings from **both** reviewers (claude `/review` AND Codex companion, plus any human comments). This is the roll-up of the entire review history: what was caught, what was fixed (and in which commit), what was deliberately skipped, and what was UNVERIFIED.

**Do not publish reviewer text.** Re-read the stored findings to understand the history, then write a fresh `public_summary` for every row. The original reviewer `title`, `claim`, and body never enter the final comment, shell source, or variables used to post it. Do not quote, copy, truncate, escape, sanitize, or lightly edit reviewer wording. Only the agent-authored interpretation, verdict, location, and resolution are published.

```bash
SUMMARY_BODY=$(jq -nr \
  --arg finding_1 '<agent-authored interpretation of verified issue 1>' \
  --arg finding_2 '<agent-authored interpretation of verified issue 2>' \
  '"## 📋 Review summary — all cycles

| Cycle | Reviewer | Finding | Verdict | Resolution |
|---|---|---|---|---|
| 1 | codex | \($finding_1) | FIX | Fixed in <sha> |
| 1 | claude | \($finding_2) | SKIP | Left as-is |
| ... | ... | ... | ... | ... |

**Totals:** <N> FIX (all resolved), <N> SKIP, <N> UNVERIFIED."')
gh pr comment <PR> --body "$SUMMARY_BODY"   # Bash, dangerouslyDisableSandbox: true
```

**Important:** `<agent-authored interpretation ...>` is a semantic placeholder, not a reviewer-title placeholder. The agent must formulate it from its verified understanding without reusing reviewer wording. Keep it to one neutral line of about 80 characters and avoid Markdown table delimiters. If the agent cannot describe the issue without copying the reviewer, stop and report that the public summary could not be produced; never fall back to the original text.

This table is informational — it does not affect merge decisions. After posting it, proceed per the no-op/apply branch above (step 9, point 1).

### 10. Watch CI (both modes, read-only)

Both modes run this step after step 9 (or after a fresh clean review following a step-9 cleanup commit). It is **read-only** against GitHub CI — `gh pr checks --watch` blocks and reports status; the cycle does not merge here (merge is a user action, step 11 recipe).

```bash
gh pr checks <PR> --watch --interval 10
```
Run via `Bash` with `dangerouslyDisableSandbox: true`. `gh pr checks --watch` is a native blocking watch — no custom loop needed.

If any check has failed — read the logs of the failed run:
```bash
gh run list --branch <HEAD_BRANCH> --limit 5 --json databaseId,name,status,conclusion --jq '.[] | select(.conclusion == "failure")'
gh run view <RUN_ID> --log-failed
```
Identify the root cause, apply fixes, commit and push (follow the commit style from step 8), then **return to step 4 as a re-review of this same cycle** (per step 8's "cycles vs. re-reviews" rule — this does NOT consume one of the 3 cycles, and is capped at 2 re-reviews before stopping) for a fresh clean review of the new head — a post-review commit invalidates the review-binding record (as in step 9), so the cycle re-reviews and re-watches CI. Repeat until a clean review lands on a green-CI head; then **stop and report** (do not merge — that is the user's action).

**Ownership-aware (do not edit a foreign PR's CI failures locally).** Applying CI fixes — editing code, running the repo's test suite/linter (the global pre-commit rule), committing, pushing — is **only for a PR you own** (`OWN_PR=true`). For a **foreign PR** (`OWN_PR=false`), do **not** edit/test/commit locally: surface the CI failure to the user (and re-run the bots), do not fix someone else's CI failure on your machine. If a foreign PR's CI can't go green, stop and hand back to the user.

If the same CI check fails more than 2 times after fixes — notify the user and stop: do not hand back a broken build.

### 11. Manual merge recipe (both modes — run only when the user asks to merge)

**The cycle never runs this step on its own — both modes are review-only on merge (0.5.2).** This is a recipe for when the user explicitly asks to merge a reviewed PR (e.g. after step 10 reported green CI). It consumes the review-binding record written at step 6's terminal-success transition and merges **only the reviewed head** with GitHub CLI's atomic expected-head guard. Do not walk into this step from the cycle — it is reached only by an explicit user request.

Load the record, re-read the live PR, and require that **author, head, base-ref, and base-sha all still match the record** — then merge. Any mismatch means the reviewed snapshot is no longer the PR in front of you → stop and re-review, do **not** refresh the stored values, and do **not** retry without the guard. (The record can only exist if the silence gate already passed — step 6 writes it solely from the terminal-success transition — so its presence is proof every configured reviewer answered that round.)
```bash
REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner)            # Bash, dangerouslyDisableSandbox: true
STATE_FILE="${TMPDIR:-/tmp}/cycle-review/$REPO_NWO/$PR-verified.json"
VERIFIED=$(jq -er --argjson pr <PR> 'select(.reviewed_head_sha and .reviewed_base_sha) | {head:.reviewed_head_sha, bref:.reviewed_base_ref, bsha:.reviewed_base_sha, author:.author}' "$STATE_FILE") \
  || { echo "No review-binding record; stop without merging."; exit 1; }
VERIFIED_HEAD=$(jq -r '.head' <<<"$VERIFIED")
CURRENT=$(gh pr view <PR> --json author,headRefOid,baseRefName,baseRefOid)
jq -e --arg head "$VERIFIED_HEAD" --argjson v "$VERIFIED" \
  '(.headRefOid == $v.head) and (.baseRefName == $v.bref) and (.baseRefOid == $v.bsha) and (($v.author | length == 0) or (.author.login == $v.author))' \
  <<<"$CURRENT" >/dev/null || { rm -f "$STATE_FILE" "$STATE_FILE.tmp"; echo "PR drifted from reviewed snapshot; re-review."; exit 1; }
gh pr merge <PR> --squash --delete-branch --match-head-commit "$VERIFIED_HEAD"
git checkout main
git pull
rm -f "$STATE_FILE" "$STATE_FILE.tmp"
```
(The `author | length == 0` carve-out skips the author check in cloud mode, where `ME`/`author` weren't resolved.) If CI is not yet confirmed green, run step 10 first (read-only `gh pr checks --watch`), then run this recipe. If the installed `gh` lacks `--match-head-commit` (`gh pr merge --help` doesn't list it), **stop** — do not fall back to a plain compare-then-merge (that leaves the check-to-merge TOCTOU hole). Upgrade `gh` or merge manually with an equivalent expected-head guard.

If a multi-PR queue was built in step 2 and the user has merged a PR (via this recipe or manually):
- pop the merged PR from the queue;
- recompute the file-overlap map for the remaining PRs (the codebase changed after the merge);
- return to step 4 with the next PR.

## Important
- **Built-in review mechanics are vendor-supported — don't redesign them.** Claude Code's built-in `/review` and the codex companion's `review`/`adversarial-review` are maintained by their vendors (Anthropic / the codex-fork maintainer). The skill **consumes** their findings and triages them like any reviewer comment — it does **not** alter, override, or re-implement how those reviewers work, what they flag, or how confident they are. If a vendor reviewer's behavior needs changing, that's an upstream issue (e.g. codex-plugin-cc), not a cycle-review change. The TDD/mutation verification in step 6 is *our triage tool*, applied to the findings we receive — never a prescription for how the vendor reviewers should behave.
- **Two modes (step 1).** `cloud` (default) pings GitHub bots; `local` reviews with the built-in `/review` command (no bot ping, no GitHub wait). **Both modes are review-only on merge** — each loops triage→reply/summary→fix→commit→push, watches CI (step 10, read-only), auto-fixes a red CI in a PR you own, then stops and reports. The skill never merges; a manual-merge recipe lives in step 11 for an explicit user request. A leading `local`/`cloud` flag overrides the saved `mode`; with neither, default to cloud. In local mode `/review` always runs; if `@codex` is in the reviewers list, Codex also reviews locally (companion script, in parallel, findings merged).
- **Approval requires every configured reviewer to answer — silence is never approval (root invariant).** If **any** configured reviewer does not return a verdict this round — for ANY reason (not installed, not logged in, 503/upstream-outage, usage-limit, timeout, empty parse, "aliens") — it is silent, and silence is not approval. The cycle **retries the round up to 2 times, then STOPS and reports** (step 6); it does **not** fall back to the other reviewer alone, does **not** finalize, and does **not** tell the user the PR is ready/mergeable. The same ALL-configured rule applies in cloud: every configured bot must be heard from, round-bound — one bot approving while the other is silent is not approval.
- **Local review records its verdicts on the PR — and that comment is programmatically verified.** Because there is no bot comment to reply to, local mode posts one triage-summary comment per round before fixing (step 6). The worker must capture the comment id and run `verify-comment.sh` (beside this `SKILL.md`), which confirms via the GitHub API that an **issue comment** with this round's nonce really exists (a `gh pr edit --body` PR-body edit, or a skipped comment, fails the gate as `MISSING`). Only `VERIFIED` lets the cycle proceed to fixes.
- **Codex review progress is streamed, not waited on silently (local).** Step 4 launches Codex with `run_in_background: true` + `--wait` and records the shell id (`$CODEX_SHELL_ID`); a `Monitor` (now in `allowed-tools`, alongside `BashOutput`) tails the shell's stderr every ~10s and prints the live `[codex]` progress to the user — you see the review happen, no silent background wait — then collects the final JSON + exit code once the shell exits.
- All `gh` commands (and any other GitHub API calls) must be run via Bash with `dangerouslyDisableSandbox: true`, as the sandbox blocks TLS connections to api.github.com.
- Every commit must have a meaningful message following conventional commits style.
- Run lint and tests before every commit; if tests fail after fixes — fix them before pushing.
- **Never merge without every configured reviewer's verdict** — finalize only if all configured reviewers returned a verdict this round AND none is `FIX`/`UNVERIFIED` (the finalize + silence gates live in step 6; this bullet restates the root invariant above).
