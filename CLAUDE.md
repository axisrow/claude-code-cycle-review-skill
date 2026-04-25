# CLAUDE.md

## Project Overview

Claude Code plugin providing the `/cycle-review` skill (with `/cr` alias) — an automated PR review loop. Plans a multi-PR merge strategy when several PRs are open, requests a code review, triages reviewer comments (FIX / SKIP / HALLUCINATION / IRRELEVANT / CONFLICTING / ALREADY_FIXED), applies fixes, and repeats until approval, then squash-merges.

## Structure

```
.claude-plugin/plugin.json        # plugin manifest
skills/cycle-review/SKILL.md      # skill definition
commands/cr.md                    # /cr alias for /cycle-review
```

## Key Details

- Single skill plus a short slash-command alias (`/cr`)
- Requires `gh` CLI authenticated with GitHub
- All `gh` commands need `dangerouslyDisableSandbox: true` (sandbox blocks TLS to api.github.com)
- Skill uses Agent tool for comment triage (subagent)
- Language: skill prompts in English, responds in user's language
