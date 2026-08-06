#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-skills/cycle-review/resolve-companion.sh}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $desc — expected '$expected', got '$actual'"
    fail=1
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fake install trees. `fork` uses the meta-plugin layout (plugins/codex/scripts/...),
# `upstream` uses the direct layout (scripts/...).
mk_fork() {
  mkdir -p "$TMP/$1/plugins/codex/scripts"
  touch "$TMP/$1/plugins/codex/scripts/codex-companion.mjs"
}
mk_upstream() {
  mkdir -p "$TMP/$1/scripts"
  touch "$TMP/$1/scripts/codex-companion.mjs"
}

# Writes a manifest from a jq-free JSON literal.
manifest() {
  printf '%s\n' "$1" > "$TMP/manifest.json"
}

# Both override vars are unset per-run: the test machine may well have a (stale) one exported,
# which would otherwise short-circuit every manifest case.
run() {
  env -u CODEX_COMPANION_PATH -u CYCLE_REVIEW_CODEX_COMPANION_PATH \
    PLUGINS_MANIFEST="$TMP/manifest.json" "$@" bash "$SCRIPT" 2>/dev/null
}
run_stderr() {
  # shellcheck disable=SC2069  # deliberate: capture stderr only, discard stdout.
  env -u CODEX_COMPANION_PATH -u CYCLE_REVIEW_CODEX_COMPANION_PATH \
    PLUGINS_MANIFEST="$TMP/manifest.json" "$@" bash "$SCRIPT" 2>&1 >/dev/null
}

mk_fork fork
mk_upstream upstream
FORK_MJS="$TMP/fork/plugins/codex/scripts/codex-companion.mjs"
UPSTREAM_MJS="$TMP/upstream/scripts/codex-companion.mjs"

manifest '{"version":2,"plugins":{}}'

# --- override: valid ---
out=$(run CODEX_COMPANION_PATH="$FORK_MJS")
check "override valid" "$FORK_MJS" "$out"

# --- override: broken (must NOT fall back to the manifest, even when it would hit) ---
manifest "$(cat <<EOF
{"version":2,"plugins":{"codex-fork@etopro-plugins":[
  {"installPath":"$TMP/fork","scope":"user","lastUpdated":"2026-01-01T00:00:00Z"}]}}
EOF
)"
out=$(run CODEX_COMPANION_PATH="$TMP/nope/codex-companion.mjs")
check "override broken fails closed" "OVERRIDE_BROKEN $TMP/nope/codex-companion.mjs" "$out"

# --- deprecated var: used as fallback, with a stderr warning ---
out=$(run CYCLE_REVIEW_CODEX_COMPANION_PATH="$FORK_MJS")
check "deprecated var resolves" "$FORK_MJS" "$out"
err=$(run_stderr CYCLE_REVIEW_CODEX_COMPANION_PATH="$FORK_MJS")
case "$err" in
  *"CYCLE_REVIEW_CODEX_COMPANION_PATH is deprecated"*) ;;
  *) echo "FAIL: deprecated var warning — expected deprecation notice on stderr, got '$err'"; fail=1 ;;
esac

# --- new name wins over the deprecated one ---
out=$(run CODEX_COMPANION_PATH="$UPSTREAM_MJS" CYCLE_REVIEW_CODEX_COMPANION_PATH="$FORK_MJS")
check "new name wins over deprecated" "$UPSTREAM_MJS" "$out"
err=$(run_stderr CODEX_COMPANION_PATH="$UPSTREAM_MJS" CYCLE_REVIEW_CODEX_COMPANION_PATH="$FORK_MJS")
check "no warning when new name set" "" "$err"

# --- manifest: single entry, fork layout ---
out=$(run)
check "manifest single entry (fork layout)" "$FORK_MJS" "$out"

# --- manifest: single entry, upstream direct layout ---
manifest "$(cat <<EOF
{"version":2,"plugins":{"codex@openai-codex":[
  {"installPath":"$TMP/upstream","scope":"user","lastUpdated":"2026-01-01T00:00:00Z"}]}}
EOF
)"
out=$(run)
check "manifest single entry (upstream layout)" "$UPSTREAM_MJS" "$out"

# --- manifest: multiple entries, newest lastUpdated wins (not file order) ---
manifest "$(cat <<EOF
{"version":2,"plugins":{
  "codex@openai-codex":[{"installPath":"$TMP/upstream","scope":"user","lastUpdated":"2025-01-01T00:00:00Z"}],
  "codex-fork@etopro-plugins":[{"installPath":"$TMP/fork","scope":"user","lastUpdated":"2026-06-01T00:00:00Z"}]}}
EOF
)"
out=$(run)
check "multiple entries sort by lastUpdated desc" "$FORK_MJS" "$out"

manifest "$(cat <<EOF
{"version":2,"plugins":{
  "codex@openai-codex":[{"installPath":"$TMP/upstream","scope":"user","lastUpdated":"2026-06-01T00:00:00Z"}],
  "codex-fork@etopro-plugins":[{"installPath":"$TMP/fork","scope":"user","lastUpdated":"2025-01-01T00:00:00Z"}]}}
EOF
)"
out=$(run)
check "multiple entries sort by lastUpdated desc (reversed)" "$UPSTREAM_MJS" "$out"

# --- scope filter: local/project entries excluded ---
manifest "$(cat <<EOF
{"version":2,"plugins":{"codex-fork@etopro-plugins":[
  {"installPath":"$TMP/fork","scope":"local","projectPath":"/somewhere/else","lastUpdated":"2026-06-01T00:00:00Z"},
  {"installPath":"$TMP/fork","scope":"project","projectPath":"/other","lastUpdated":"2026-06-02T00:00:00Z"}]}}
EOF
)"
out=$(run)
check "scope filter excludes local/project" "NOT_FOUND" "$out"

# --- scope filter: user entry still wins alongside excluded ones ---
manifest "$(cat <<EOF
{"version":2,"plugins":{"codex-fork@etopro-plugins":[
  {"installPath":"$TMP/upstream","scope":"local","lastUpdated":"2026-12-01T00:00:00Z"},
  {"installPath":"$TMP/fork","scope":"user","lastUpdated":"2026-01-01T00:00:00Z"}]}}
EOF
)"
out=$(run)
check "user-scoped entry chosen over newer local one" "$FORK_MJS" "$out"

# --- name allowlist: substring matches excluded ---
manifest "$(cat <<EOF
{"version":2,"plugins":{
  "codex-helper@somebody":[{"installPath":"$TMP/fork","scope":"user","lastUpdated":"2026-06-01T00:00:00Z"}],
  "my-codex@somebody":[{"installPath":"$TMP/upstream","scope":"user","lastUpdated":"2026-06-02T00:00:00Z"}],
  "codexfork@somebody":[{"installPath":"$TMP/fork","scope":"user","lastUpdated":"2026-06-03T00:00:00Z"}]}}
EOF
)"
out=$(run)
check "name allowlist excludes substring matches" "NOT_FOUND" "$out"

# --- manifest hit, but companion file missing on disk ---
mkdir -p "$TMP/empty"
manifest "$(cat <<EOF
{"version":2,"plugins":{"codex@openai-codex":[
  {"installPath":"$TMP/empty","scope":"user","lastUpdated":"2026-06-01T00:00:00Z"}]}}
EOF
)"
out=$(run)
check "manifest entry without companion on disk" "NOT_FOUND" "$out"

# --- newest entry has no companion on disk, older one does: fall through in order ---
manifest "$(cat <<EOF
{"version":2,"plugins":{
  "codex-fork@etopro-plugins":[{"installPath":"$TMP/empty","scope":"user","lastUpdated":"2026-12-01T00:00:00Z"}],
  "codex@openai-codex":[{"installPath":"$TMP/upstream","scope":"user","lastUpdated":"2026-01-01T00:00:00Z"}]}}
EOF
)"
out=$(run)
check "falls through to next candidate when newest has no file" "$UPSTREAM_MJS" "$out"

# --- nothing at all ---
manifest '{"version":2,"plugins":{}}'
out=$(run)
check "empty manifest" "NOT_FOUND" "$out"

out=$(env -u CODEX_COMPANION_PATH -u CYCLE_REVIEW_CODEX_COMPANION_PATH \
  PLUGINS_MANIFEST="$TMP/does-not-exist.json" bash "$SCRIPT" 2>/dev/null)
check "missing manifest file" "NOT_FOUND" "$out"

out=$(printf 'not json' > "$TMP/manifest.json"; run)
check "malformed manifest" "NOT_FOUND" "$out"

# --- exit code is always 0 ---
manifest '{"version":2,"plugins":{}}'
if ! run >/dev/null; then
  echo "FAIL: exit code — expected 0 on NOT_FOUND"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: resolve-companion.sh covers override valid/broken, deprecated fallback, manifest sort/scope/allowlist/layouts, NOT_FOUND"
else
  exit 1
fi
