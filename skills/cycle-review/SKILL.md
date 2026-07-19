---
name: cycle-review
description: Automated PR review cycle — request review, fix issues, repeat until approved, then merge. Cloud mode pings GitHub review bots; local mode reviews with the built-in /review command, plus Codex locally when @codex is configured.
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, Skill, AskUserQuestion
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
| **cloud** (default, original behavior) | GitHub bots `@claude` / `@codex` pinged in a PR comment | yes — waits for the bots to post on GitHub | you want the same reviewers a human teammate would see on the PR, and a fully autonomous loop through merge |
| **local** | the built-in **`/review`** command (Agent-tool-free — Claude Code's own PR-review mechanic) reviewing the PR, **plus Codex (local companion) when `@codex` is configured** | no bot ping, no GitHub wait; only posts the findings as a PR comment afterwards | you want a fast review without waiting on GitHub bots, or the bots aren't installed. `/review` **always** runs; **if `@codex` is in your reviewers list, Codex also reviews locally** via its companion script (run in parallel, findings merged). No GitHub bot ping either way |

**Mode selection — flag overrides config, config is the default:**
- A standalone leading token `local` or `cloud` in `$ARGUMENTS` (also accept `--local` / `--cloud`) forces that mode for this run and is stripped out before parsing PR numbers — exactly like the `onboard` token.
- Otherwise the mode comes from `mode` in the saved config (step 0).
- If neither a flag nor a saved `mode` is present, default to `cloud` (backward-compatible).

**Local mode is review-only on merge:** it runs the full triage→reply→fix→commit→push loop, but it **never merges on its own**. It stops after pushing and hands back to the user; merge happens only when the user explicitly asks. Cloud mode keeps the original autonomous merge (step 11).

## Cycle

Run step 0 (onboarding) and step 1 (resolve mode) once at the start of every invocation. Then, for each PR, run step 3 (verify the PR implements its linked issue 100% — fix any gap BEFORE asking for review), repeat steps 4–8 until the PR has no `FIX` verdicts — **but no more than 3 cycles**; if a 3rd cycle still has `FIX`s, stop and hand back to the user to narrow scope. Once a round is clean, run step 9 (final cleanup pass — apply the minor findings deferred across all earlier rounds). Then: **cloud mode** runs step 10 (CI) and step 11 (merge); **local mode** stops and reports — it does not auto-merge.

### 0. Onboarding — reviewers + default mode (optional, run once per invocation)

The skill needs two things from the user, stored once: which review bots they have installed (`@claude`, `@codex`, or both — drives cloud mode), and the **default review mode** (`cloud` or `local`). The reviewers list drives who gets pinged in step 4 and whose comments we wait for in step 5 (cloud only). The mode is the default when no `local`/`cloud` flag is passed (step 1).

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
   `CONFIGURED` → read the reviewers and mode (the read commands below) and skip to step 1. `NEEDS_ONBOARDING` (missing file, malformed JSON, or empty `reviewers`) → run onboarding.

2. **Run onboarding.** Ask the user TWO `AskUserQuestion` questions (one tool call, two questions):
   - **Reviewers** (multi-select): `@claude`, `@codex` — which review bots they have (one or both). Used by cloud mode.
   - **Default mode** (single-select): `cloud` (ping GitHub review bots, autonomous through merge) vs `local` (the built-in `/review` reviews the PR, no bot ping, never auto-merges). This is just the default — a `local`/`cloud` flag always overrides it per run.

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

### 1. Resolve the active review mode

Decide cloud vs local for this run, then remember it — every later branch (steps 4, 5, 6, 9, 10, 11) reads it.

1. **Flag wins.** If `$ARGUMENTS` had a standalone leading `local` / `cloud` (or `--local` / `--cloud`) token, use that mode and remember it was stripped from PR-number parsing.
2. **Else config.** Use the `mode` read in step 0 (`"cloud"` when the field is absent).
3. **Announce it** so the run is self-documenting, e.g. `Review mode: local (built-in /review; will not auto-merge).` or `Review mode: cloud (pinging @claude @codex).`

In **local** mode no bots are pinged, but the **reviewers list still matters**: the built-in `/review` always runs, and if the list contains `@codex`, Codex also reviews locally via its companion script (step 4). `@claude`-only stays `/review`-only. (The reviewers list read in step 0 is consulted by local step 4 too, not only cloud — no extra read is needed.)

The `@codex` bot login is a best-effort default and can vary by integration. On the first real Codex run, verify the actual login via `gh api repos/{owner}/{repo}/issues/{PR}/comments --jq '[.[].user.login] | unique'` (and `pulls/{PR}/reviews`), and if it differs, tell the user and use the observed value for that session.

### 2. Multi-PR strategy (run once per invocation)

Skip this step only when there is exactly one PR to handle (single-PR run, no other open PRs by the same author).

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

5. After each successful merge in step 11, return here: pop the merged PR from the queue, recompute file overlap for the rest (the codebase has changed), and continue with the next PR.

### 3. Verify the PR implements its linked issue 100% (before any review)

Run this **once per PR, before step 4** — do NOT ask the bots to review a half-finished PR. Review bots check whether the *code* is correct, not whether it is *complete* relative to the issue's design; a PR can be approved by both bots and still ship only half of what the issue asked for. Catch that here, up front, not after a wasted review round (or after merging an incomplete issue).

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

**Branch on the active mode (step 1).**

**Cloud:** ping the configured bots. **Local:** run the built-in `/review` (plus Codex when `@codex` is configured). In both modes, launch everything that runs in parallel up front, then step 5 waits (cloud) or step 6 collects (local).

#### Cloud — ping the bots

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
For example, with both configured the body starts with `@claude @codex review.`; with only Codex it starts with `@codex review.`. Run via `Bash` with `dangerouslyDisableSandbox: true`. Then go to step 5 (wait).

#### Local — built-in `/review` plus Codex when configured

No bot is pinged and no GitHub wait happens. The **built-in `/review` always runs**; if `@codex` is in the reviewers list (step 0), **Codex also reviews locally, in parallel**, and its findings are merged with `/review`'s before triage. (`@codex`-only still runs `/review` too — local mode always includes Claude; the reviewers list only *adds* Codex.)

**Launch both in parallel, then step 6 collects both:**

1. **Start Codex first (background) when `@codex` is configured**, so it runs while `/review` works:
   - **Resolve the companion path from the installed-plugins manifest — never hardcode the source namespace or path layout.** `~/.claude/plugins/installed_plugins.json` is the canonical plugin→installPath index (`{ "version": 2, "plugins": { "<name>@<marketplace>": [{ installPath, version, scope, projectPath, lastUpdated, ... }] } }`). Filter carefully, because the chosen script runs with `dangerouslyDisableSandbox: true` (network) — a wrong pick can execute an unrelated plugin impersonating the reviewer:
     1. **Only `scope: "user"` entries.** A `user`-scoped install is globally enabled and valid in any repo. `local`/`project` entries are tied to another repo's `projectPath` and must NOT be eligible outside it — never run a plugin the user only enabled for a different project.
     2. **Explicit codex names only.** Match the plugin name (the part before `@`) against an allowlist of known codex plugins — `codex` (upstream `codex@openai-codex`) and `codex-fork` (`codex-fork@etopro-plugins`). A loose substring match (`codex`) risks catching an unrelated plugin whose name merely contains it.
     3. **Newest `lastUpdated` first.** Among the surviving entries, order by `lastUpdated` descending — that is the actively installed version, NOT the newest version sitting in the file cache (the cache holds leftovers the GC sweeps away; `.in_use/` PID-markers only protect from sweep, they don't pick the version).
     4. **Probe both path layouts, first existing wins** (preserving the timestamp order above — do NOT re-sort by path): the fork is a meta-plugin wrapping a `codex` sub-plugin (`<installPath>/plugins/codex/scripts/codex-companion.mjs`); the upstream direct plugin is `<installPath>/scripts/codex-companion.mjs`.
     ```bash
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
     ```
     If `$COMPANION` is empty, the codex plugin is **not installed** at user scope (distinct from "installed but not logged in" below) — treat as the fail-closed case in step 6.

     > Why not `${CLAUDE_PLUGIN_ROOT}`? That env var is substituted by Claude Code only inside the *owning* plugin's commands/hooks — in a cycle-review session it points at cycle-review (or is unset), so it can't address a sibling plugin. `installed_plugins.json` is the only cross-plugin source of truth for install paths.
   - **Get the PR's base ref** (this is what makes `--base` equal the PR diff, since local mode is checked out on the PR branch):
     ```bash
     BASE=$(gh pr view <PR> --json baseRefName -q .baseRefName)   # Bash, dangerouslyDisableSandbox: true
     ```
   - **Invoke the companion in the background, JSON output, against the PR base:**
     ```bash
     node "$COMPANION" adversarial-review --wait --json --base "$BASE" \
       "Critical-only review of PR #<PR>: bugs, security vulnerabilities, logical errors, data-loss risks, performance problems. Do NOT nitpick style, naming, formatting, or subjective preferences."
     ```
     Run via **`Bash` with `run_in_background: true`** *and* `dangerouslyDisableSandbox: true` (Codex needs network). `--wait` keeps it blocking *inside* the backgrounded bash, so the background handle completes only when Codex is done. Record the returned background shell id.

2. **Run the Claude review by invoking the built-in `/review` via the `Skill` tool** — do NOT spawn a custom review subagent. `/review` is the canonical Claude Code PR-review command (read-only, single-pass; maintained upstream), and this skill rides on its improvements instead of re-implementing review logic. Because Codex is already running in the background, the two reviews overlap.
   - **Invoke via the `Skill` tool.** Call `Skill({ skill: "review", args: "<PR#>" })`. This is the ONLY programmatic path — do not try to type a literal `/review <PR>` into the chat (the model can't do that), do not shell out via Bash, do not spawn an Agent. `/review` is one of the built-ins explicitly exposed through the `Skill` tool (per `/skills` docs: `/init`, `/review`, `/security-review`). `Skill` is in this skill's `allowed-tools` for exactly this call.
   - **Read the review directly — no parser, no steering, no format contract.** `/review` is read-only and posts nothing to GitHub; it writes its review as an assistant message in THIS skill's own context (verified empirically). You — the agent running the cycle — read that review with your own judgment and extract its findings into the common finding shape exactly the way you read any reviewer comment: each distinct issue the review raises → a finding with whatever `path`/`line` the review points at (often none), a short `title`, the concrete `claim`, and `evidence: "/review-reported; re-verify in triage"`. Tag each `reviewer: claude`. Do NOT try to coerce `/review` into a fixed line format — it writes free-form prose with sections/bullets, and that is fine; you triage prose the same way you triage a human or bot comment in step 6.

3. **After `/review` has run (or its `Skill` call errored — see the fail-closed in step 6), collect the Codex background output** (only if Codex was launched). Use `BashOutput` on the recorded background id; if it has not finished, wait for it (poll `BashOutput`, or use the Monitor/until pattern) — do not proceed until the background bash has exited. Capture both its stdout (the JSON) and its **exit code**.

4. **Fail-closed check (Codex configured but unavailable).** Two distinct failure shapes, both STOP:
   - **Companion not found** (`$COMPANION` was empty): the codex plugin is not installed. STOP and tell the user: *"Codex companion not found in `~/.claude/plugins/installed_plugins.json`. Install the codex plugin (e.g. via `/plugin`), then re-run."* Do **NOT** suggest `codex login` here — there is nothing to log in to yet.
   - **Companion found but the background bash exited non-zero**: the companion runs but reports an install/login error to stderr (e.g. `npm install -g @openai/codex` or `codex login`). STOP, report the exact stderr, and ask the user to install/log in (`codex login`), then re-run.

   In both cases, do **NOT** silently continue on `/review` alone — a missing Codex review must not masquerade as approval. (When `@codex` is *not* configured, there is no Codex run and nothing to fail-closed on.)

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

7. **Persist this round's merged findings to a per-run file** (so step 9 can re-read findings from EVERY prior round — `/review`'s output lives only in chat and is otherwise lost once the conversation moves on, and Codex's JSON stdout is ephemeral). After the merge above, write the merged findings to `~/.claude/cycle-review/runs/<PR>-round<N>.json` where `<PR>` is the PR number and `<N>` is the current cycle number (1/2/3 — same counter the step-6 finalize gate tracks). Build it with `jq -n` so the JSON is always well-formed; one object per round:
   ```json
   {
     "pr": <PR>, "round": <N>, "timestamp": "<ISO 8601 from date -u +%Y-%m-%dT%H:%M:%SZ>",
     "findings": [
       {"reviewer": "claude", "path": "<path>", "line": <int>, "title": "<title>", "claim": "<claim>", "severity": "minor"},
       {"reviewer": "codex",  "path": "<path>", "line": <int>, "title": "<title>", "claim": "<claim>", "severity": "<critical|minor>"}
     ]
   }
   ```
   `mkdir -p ~/.claude/cycle-review/runs/` (it's next to `config.json` from step 0). Tag every finding with its `reviewer` (`claude` for `/review`, `codex` for Codex) so step 9 and the step-6 summary can attribute. Do NOT clean these files up at the end of the run — they are how step 9 reconstructs prior rounds; if a re-run repeats a round number, overwrite that file in place (the latest triage of round N wins).

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

| Handle | Mention (step 4) | Bot login | Where its review lands |
|---|---|---|---|
| `@claude` | `@claude` | `claude[bot]` | edits a single **issue comment** in place; finishes with the marker `Claude finished` |
| `@codex` | `@codex` | `chatgpt-codex-connector[bot]` | a **PR review** object plus **inline review comments** (not issue comments) |

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

#### Triage (both modes)

Launch a **triage** subagent (Agent tool — this is the triage engine, distinct from any review subagent) to triage each comment (cloud) or each finding (local, from `/review` + Codex). The subagent must:
- Read the current code of files referenced in the comments
- Check whether the issue was already fixed in previous commits (compare with what the reviewer is requesting)
- Assess severity: critical (bug, security, logical error) vs cosmetic (style, naming, formatting)
- Check relevance: does the comment actually relate to this PR's code? The reviewer may be mistaken — referencing non-existent files, confusing function names, or providing feedback that clearly belongs to a different project/PR. Mark such comments as `IRRELEVANT`
- Check consistency: does the comment contradict previous comments from the same or another reviewer? If the reviewer asks for X now but asked for not-X in the previous cycle — mark as `CONFLICTING`
- **Verify every claim before assigning `FIX`**: for each comment, read the actual files and grep the codebase to confirm that every statement the reviewer makes is true. Do not take any claim at face value — LLM reviewers routinely hallucinate: non-existent functions, wrong line numbers, incorrect patterns, false project-wide conventions (e.g. "only English comments", "this method doesn't exist", "this pattern is used everywhere"). A `FIX` verdict is only valid when the underlying claim is confirmed by reading the actual code. If any claim is false — mark as `HALLUCINATION`
- Return a list of comments with a verdict: `FIX` (needs fixing), `ALREADY_FIXED` (already resolved), `SKIP` (cosmetic), `IRRELEVANT` (unrelated to this PR), `CONFLICTING` (contradicts previous comments), `HALLUCINATION` (reviewer's factual claim about the codebase is verifiably false)

Triage is still where each gets a `FIX`/`SKIP`/… verdict and where merge-readiness is decided. Treat each finding exactly like a reviewer comment. Codex findings carry `reviewer: codex` and are claim-verified here exactly like bot comments — do not trust Codex's `claim` at face value. `/review` is a single-pass review with NO upstream confidence filtering, so verify each `/review` claim here just as rigorously (LLM reviews hallucinate: non-existent functions, wrong line numbers).

Only fix comments with the `FIX` verdict. For other verdicts — leave a reply comment on the PR with an explanation:
- `ALREADY_FIXED` — specify which commit already addressed the issue
- `SKIP` — explain why the comment is cosmetic and does not affect functionality
- `IRRELEVANT` — politely note that the comment does not relate to this PR's code
- `CONFLICTING` — quote the contradicting previous comment and ask the reviewer to clarify
- `HALLUCINATION` — show concrete evidence from the codebase (grep results, file contents) that disproves the reviewer's claim

In **cloud** mode those replies attach to the bot's existing comments. In **local** mode the findings have no GitHub comment to reply to, so instead **post one summary comment** on the PR recording this round's triage results — the local review is the reviewer of record, so its verdicts must land on the PR. When Codex also ran, attribute each finding to its source (the `Reviewer` column); when `@codex` was not configured, drop that column and the heading's "+ Codex companion":
```bash
gh pr comment <PR> --body "$(cat <<'EOF'
## 🔍 Local review (cycle N)
Reviewed locally (`/review` + Codex companion), no bots pinged.

| Verdict | Reviewer | Finding | Location |
|---|---|---|---|
| FIX | claude | <title> | path:line |
| SKIP | codex | <title> | path:line |
...
EOF
)"
```
Run via `Bash` with `dangerouslyDisableSandbox: true`. This is the comment the user asked local mode to record before fixing — write it every round, then proceed to fix the `FIX` items.

#### Decide whether to finalize

Check these in order (the first two gates are **cloud-only** — they guard against bot silence/outage, which can't happen in local mode where the reviewers report directly):
- **(cloud only) Step 5 returned `ERROR`** → do NOT finalize. The comments could not be read (a sustained API outage), so an empty triage is meaningless, not approval. Notify the user and stop; never let an outage become a silent merge.
- **(cloud only) No reviewer was actually heard from this round** → do NOT finalize. If the configured bots posted nothing new for this round (the bots were slow, or Claude shows a usage-limit message instead of a review and no other reviewer responded), then no review happened — "no `FIX` verdicts" only reflects silence, not an approval. Treat a Claude usage-limit message as "Claude did not review" (not a finding). If Codex is configured and reviewed, you may proceed on Codex alone; if nobody reviewed, notify the user and stop. This must be checked BEFORE interpreting the absence of `FIX` verdicts. (In local mode the equivalent is step 4's `/review` fail-closed: if the `Skill` call errored or `/review` produced no review at all, no Claude review happened — stop; if Codex is configured and reviewed, you may proceed on Codex alone.)
- **No `FIX` verdicts**, and a real review happened (cloud: at least one reviewer reviewed; local: `/review` produced a review and/or Codex reviewed) → this is the **final cycle**. Do not require an explicit `APPROVED` review state — bot reviewers (e.g. `claude[bot]`) rarely emit it; given a real review, the absence of blocking issues IS the approval signal. Post the replies/summary above for any non-`FIX` comments, then go to **step 9** (final cleanup pass — apply the accumulated minor findings). After step 9: **cloud** proceeds to CI (step 10) + merge (step 11); **local** stops and reports — it does NOT run step 10/11 or merge on its own (see step 11).
- **At least one `FIX`, and this is the 3rd cycle** → STOP, do not start a 4th. Three full review rounds with findings still outstanding means the PR isn't converging on its own — looping further wastes review budget. Notify the user: summarize the still-open `FIX` findings and propose narrowing scope — e.g. move some findings **out of scope** into a follow-up issue/PR so the core change can merge, or have the user rethink the approach. Wait for the user's decision; do not merge and do not auto-loop. (Count a "cycle" as one completed round of steps 4–8, i.e. one review request + triage. The round that produced this 3rd batch of `FIX`s is the 3rd.)
- **At least one `FIX`, and this is cycle 1 or 2** → proceed to step 7.

The cycle counter lives only in your working memory across a long conversation, so make it observable: at the end of every triage, **explicitly state the current cycle number** to the user (e.g. "Triage of cycle 2/3 complete: 1 FIX, 2 SKIP"). This keeps the 3-cycle cap self-checkable instead of relying on hidden state.

### 7. Fix issues

Only fix comments with the `FIX` verdict from step 6 — and fix them **properly**, not as throwaway patches. Each `FIX` is a bug; treat it as one and run a real bug-fix pipeline, not "edit until it looks right".

For **each** `FIX` verdict, in turn:

1. **Reproduce it first (test-first).** Before touching production code, write a test that **fails** because of the bug — the test must encode the reviewer's claim (read the file/line, confirm the claim in step 6 already verified it's real) and turn red on the current code. Run it and confirm it fails **for the right reason** (the bug), not for a setup/import error. If the repo has no test framework or the bug genuinely can't be reproduced by a test (e.g. a doc-only issue, an architectural concern, a cross-process/race bug with no test seam) — note that explicitly and fall through to the direct fix below, but do not skip the test by default.
2. **Minimal fix.** Make the smallest change that turns the red test green. No refactors, no "while I'm here" edits, no scope creep — the diff must address the bug and nothing else. (Cosmetic/nice-to-have items are `SKIP`s, handled in step 9, not here.)
3. **Green.** Run the new test plus the **full** suite. The new test passes; nothing else regressed. If a pre-existing test now fails, that's a signal the fix is wrong or too broad — narrow it, don't loosen the test.
4. **Mutation check.** Revert the fix mentally / tweak it: would the test still pass if the fix were subtly wrong (off-by-one, wrong condition, fixed the symptom not the cause)? If yes, strengthen the test until a wrong fix would fail it. The test must actually guard the bug, not just happen to pass.
5. **Lint.** Run the repo's linter (`ruff check src/ tests/` or the repo's equivalent) on the changed files; fix any lint the fix introduced.

**When test-first isn't possible** (step 1 fallback): make the direct fix, but say *why* no test was added (e.g. "doc-only", "no test seam for this race"), and still run the full suite + lint so the change doesn't silently break something. A `FIX` shipped without a reproducing test is the exception and must be justified inline, not the default.

Only after every `FIX` is fixed this way does the round proceed to step 8 (commit + push). The linter/test commands above are the same ones step 8 will run before committing — don't duplicate; just keep them green.


### 8. Commit and push
- Commit fixes with a meaningful message (conventional commits style)
- Push to remote
- Return to step 4 ONLY if fewer than 3 cycles have run. This begins a **new review round**: **cloud** posts a fresh review request and runs the step-5 waiter again (it always waits a clean fixed window — nothing to reset); **local** re-runs `/review` (step 4) against the now-updated diff, plus Codex if configured. Keep a running count of completed cycles (one cycle = one steps 4–8 round). **Hard cap: 3 cycles.** If the round you just triaged was the 3rd and it still had `FIX` verdicts, do NOT loop again — stop and hand back to the user per the step-6 "3rd cycle" gate (summarize the open findings, propose moving some out of scope into a follow-up issue/PR, or rethinking the approach). The cap only bites when findings persist; a clean 1st or 2nd round finalizes normally.

### 9. Final cleanup pass (last cycle — apply the accumulated minor findings)

Reached only on the **final cycle** — when a round has no `FIX` verdicts (step 6) and a real review happened. This is the last cycle: there will be **no further review round** after it. Before finalizing, spend this one pass cleaning up everything that was correct-but-not-blocking and was therefore deferred across the earlier rounds, so nothing useful is left on the table.

1. **Gather the minor findings from EVERY previous review round, not just the last one.** Re-read all findings across the whole PR history — **cloud**: all three GitHub surfaces (issue comments, PR reviews, inline review comments — same fetch as step 6); **local**: read each prior round's **per-run findings file** written in step 4.7 (each round's merged `/review` + Codex findings persisted at `~/.claude/cycle-review/runs/<PR>-round<N>.json`), plus any human comments on the PR. Do NOT try to re-fetch `/review`'s output from GitHub — it never posted a PR comment — and do NOT look for a "recorded Codex JSON": the only persistence of either is the per-run file written in step 4.7. Collect every finding that is real and actionable but was not a `FIX`:
   - all `SKIP` (genuine cosmetic/style/naming/minor-improvement findings), and
   - any reasonable nice-to-have the reviewers suggested (e.g. "add a clarifying comment", "rename for clarity", "tidy this helper", "add a migration note") — even when previously deferred as non-blocking.

   Explicitly EXCLUDE the verdicts that have nothing to fix: `HALLUCINATION` (claim is false), `IRRELEVANT` (not this PR's code), `CONFLICTING` (contradictory — ask, don't guess), and `ALREADY_FIXED` (already done). De-dup findings that recurred across rounds by their substance (use `path` + `line` when present, as on Codex inline comments; otherwise the gist of the body — Claude's single issue comment has no path/line), and skip any that a later commit already addressed.

2. **Apply all of them.** Make the edits, keeping each change minimal and faithful to the reviewer's intent. If a suggested change would be risky, change behavior, or contradicts the repo's conventions, do NOT force it — leave a short reply explaining why it was left out (this is the only thing that may remain unfixed).

3. **Lint and test green**, same as step 7 (`ruff check src/ tests/`, `pytest tests/ -v` — or the repo's equivalents).

4. **Commit and push** (conventional-commits style, e.g. `chore: apply non-blocking review nitpicks before merge`). On the PR, briefly note that the deferred minor findings were applied in `<sha>`.

5. **Do NOT return to step 4.** This pass does not request another review. **Cloud** proceeds directly to step 10 (CI) and step 11 (merge) — the cleanup commit rides the same CI run. **Local** stops here: it does not run step 10/11 and does not merge. Report to the user that the review cycle is complete (summary of what was fixed across rounds and the cleanup `<sha>`), and that merge is theirs to trigger.

If, after re-reading every round, there are genuinely no minor findings to apply (a clean PR that never accrued any `SKIP`/nice-to-have), this step is a no-op — cloud proceeds to step 10; local proceeds to its stop-and-report.

### 10. Check CI before merge — **cloud mode only**

Local mode never reaches this step (it stops at the end of step 9). Steps 10 and 11 run only in cloud mode.

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
Identify the root cause, apply fixes to the code, commit and push (follow the commit style from step 8), then return to step 10. Only proceed to step 11 once all checks pass (or the PR has no CI configured).

If the same CI check fails more than 2 times after fixes — notify the user and stop: do not merge a broken build.

### 11. Finalization / merge — **cloud mode only**

**Local mode does not merge.** It is review-only on merge by design (the user triggers merge explicitly). After step 9 in local mode, stop and report — do not run the commands below.

Cloud mode: when the PR has no remaining `FIX` verdicts and CI is green:
```bash
gh pr merge <PR> --squash --delete-branch
git checkout main
git pull
```

If the user later asks to merge a PR that was reviewed in local mode, this is the step to run (after confirming CI is green via step 10).

If a multi-PR queue was built in step 2 and PRs remain:
- pop the merged PR from the queue;
- recompute the file-overlap map for the remaining PRs (the codebase changed after the merge);
- return to step 4 with the next PR.

## Important
- **Two modes (step 1).** `cloud` (default) pings GitHub bots and runs autonomously through merge; `local` reviews with the built-in `/review` command (no bot ping, no GitHub wait) and is **review-only on merge** — it loops triage→reply/summary→fix→commit→push but stops after cleanup and never merges on its own. A leading `local`/`cloud` flag overrides the saved `mode`; with neither, default to cloud. In local mode `/review` always runs; if `@codex` is in the reviewers list, Codex also reviews locally (companion script, in parallel, findings merged) — and if `@codex` is configured but Codex is unavailable, local mode STOPS and asks you to log in (fail-closed), it does not fall back to `/review` alone.
- **Local review records its verdicts on the PR.** Because there is no bot comment to reply to, local mode posts one triage-summary comment per round before fixing (step 6), so the PR has a durable record of what the local reviewer found.
- All `gh` commands (and any other GitHub API calls) must be run via Bash with `dangerouslyDisableSandbox: true`, as the sandbox blocks TLS connections to api.github.com.
- Every commit must have a meaningful message following conventional commits style.
- Run lint and tests before every commit; if tests fail after fixes — fix them before pushing.
- Never merge without a real review. Finalize only if at least one configured reviewer actually posted a review this round (see the finalize gate in step 6). Silence or an outage is not approval.
