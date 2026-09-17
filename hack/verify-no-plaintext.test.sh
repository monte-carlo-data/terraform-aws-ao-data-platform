#!/usr/bin/env bash
# Regression test for hack/verify-no-plaintext.sh — see that script's header for
# what it verifies and its scope. Run from anywhere:
#   hack/verify-no-plaintext.test.sh                  all cases (make selftest-verify-no-plaintext)
#   hack/verify-no-plaintext.test.sh <case> [case..]  only the named cases
#
# Every case asserts an exact exit code so the meanings stay distinct:
# 1 = plaintext found, 2 = usage/input error, 3 = write-only path not proven,
# 4 = advisory: non-ClickHouse resources carry plaintext / unmanaged generators.
# Each case's FAIL message names what it covers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$REPO_ROOT/hack/verify-no-plaintext.sh"
FIXTURES="$REPO_ROOT/tests/fixtures"

fail() { echo "FAIL: $*" >&2; exit 1; }

# expect <code> <what the case covers> <cmd...>: run cmd with output suppressed
# and assert its exact exit code.
expect() {
  local code="$1" what="$2" status=0
  shift 2
  "$@" >/dev/null 2>&1 || status=$?
  [ "$status" -eq "$code" ] || fail "$what: expected exit $code, got $status"
}

case_leaking_state_pull() {
  expect 1 "leaking fixture (state pull shape)" \
    "$VERIFY" "$FIXTURES/state-with-plaintext.json" SENTINEL-OTEL-0001
}

case_clean_state_pull() {
  expect 0 "clean fixture (state pull shape)" \
    "$VERIFY" "$FIXTURES/state-clean.json" SENTINEL-OTEL-0001
}

case_leaking_show_json() {
  expect 1 "leaking fixture (show -json shape)" \
    "$VERIFY" "$FIXTURES/state-with-plaintext-show.json" SENTINEL-OTEL-0002
}

case_clean_show_json() {
  expect 0 "clean fixture (show -json shape)" \
    "$VERIFY" "$FIXTURES/state-clean-show.json" SENTINEL-OTEL-0002
}

# Post-migration remnant: the AWS provider leaves secret_string = "" (not
# absent) after a secret_string_wo write, and jq treats "" as truthy. This pins
# the fix that stops the empty string from false-FAILing a genuinely clean,
# correctly-migrated state. Covers both state shapes.
case_empty_secret_string_state_pull() {
  expect 0 "post-migration empty-secret_string fixture (state pull shape)" \
    "$VERIFY" "$FIXTURES/state-clean-empty-secret-string.json" SENTINEL-OTEL-0001
}

case_empty_secret_string_show_json() {
  expect 0 "post-migration empty-secret_string fixture (show -json shape)" \
    "$VERIFY" "$FIXTURES/state-clean-empty-secret-string-show.json" SENTINEL-OTEL-0002
}

# Positive gate: no plaintext, but nothing was ever written through
# secret_string_wo. Must not read as clean.
case_unwritten_secret() {
  expect 3 "unwritten-secret fixture" \
    "$VERIFY" "$FIXTURES/state-no-write.json"
}

case_malformed_input() {
  local tmp status=0
  tmp="$(mktemp)"
  printf 'not valid json {{{' >"$tmp"
  "$VERIFY" "$tmp" >/dev/null 2>&1 || status=$?
  rm -f "$tmp"
  [ "$status" -eq 2 ] || fail "malformed input did not exit 2 (got $status)"
}

case_empty_input() {
  local tmp status=0
  tmp="$(mktemp)"
  "$VERIFY" "$tmp" >/dev/null 2>&1 || status=$?
  rm -f "$tmp"
  [ "$status" -eq 2 ] || fail "empty input did not exit 2 (got $status)"
}

case_missing_state_file() {
  expect 2 "missing state file" \
    "$VERIFY" "$FIXTURES/definitely-not-a-file.json"
}

case_missing_sentinel_file() {
  expect 2 "missing sentinel file" \
    "$VERIFY" "$FIXTURES/state-clean.json" --sentinel-file "$FIXTURES/definitely-not-a-file.txt"
}

# A sentinel containing whitespace must still be verified — the argv path
# cannot carry one, which is why the sentinel-file path exists.
case_whitespace_sentinel_file() {
  local tmp status=0
  tmp="$(mktemp -d)"
  printf '\npass word 123\n' >"$tmp/sentinels.txt"
  "$VERIFY" "$FIXTURES/state-whitespace-sentinel.json" --sentinel-file "$tmp/sentinels.txt" >/dev/null 2>&1 || status=$?
  rm -rf "$tmp"
  [ "$status" -eq 1 ] || fail "whitespace sentinel from a sentinel file: expected exit 1, got $status"
}

# Blank lines in a sentinel file must be skipped, not treated as a sentinel
# that matches everything.
case_sentinel_file_blank_lines() {
  local tmp status=0
  tmp="$(mktemp -d)"
  printf '\nSENTINEL-ABSENT-0003\n\n' >"$tmp/sentinels.txt"
  "$VERIFY" "$FIXTURES/state-clean.json" --sentinel-file "$tmp/sentinels.txt" >/dev/null 2>&1 || status=$?
  rm -rf "$tmp"
  [ "$status" -eq 0 ] || fail "clean fixture with an absent sentinel file: expected exit 0, got $status"
}

# F1: the sentinel check must match a password whose bytes JSON encoding
# altered. The leak lives in values.outputs — a surface the structural gates
# do not inspect — so only the sentinel layer can catch it. The sentinel file
# holds the raw password; the fixture holds the escaped bytes terraform show
# -json actually emits (" -> \" and \ -> \\).
case_json_escaped_sentinel_quote_backslash() {
  local tmp status=0 matched=0
  tmp="$(mktemp -d)"
  printf 'ab"cd\\ef\n' >"$tmp/sentinels.txt"
  "$VERIFY" "$FIXTURES/state-json-escaped-sentinel-show.json" --sentinel-file "$tmp/sentinels.txt" >"$tmp/out" 2>&1 || status=$?
  if grep -q "appears in state" "$tmp/out"; then matched=1; fi
  rm -rf "$tmp"
  { [ "$status" -eq 1 ] && [ "$matched" -eq 1 ]; } \
    || fail "JSON-escaped sentinel (quote/backslash): expected exit 1 reporting the sentinel, got status=$status matched=$matched"
}

# F1: Go's encoding/json HTML-escapes <, > and & in terraform show -json, so
# a password carrying those bytes lands in state HTML-escaped, not raw.
# Same contract as the quote/backslash case, on a second leak in the fixture.
case_json_escaped_sentinel_html_chars() {
  local tmp status=0 matched=0
  tmp="$(mktemp -d)"
  printf 'x&y<z>\n' >"$tmp/sentinels.txt"
  "$VERIFY" "$FIXTURES/state-json-escaped-sentinel-show.json" --sentinel-file "$tmp/sentinels.txt" >"$tmp/out" 2>&1 || status=$?
  if grep -q "appears in state" "$tmp/out"; then matched=1; fi
  rm -rf "$tmp"
  { [ "$status" -eq 1 ] && [ "$matched" -eq 1 ]; } \
    || fail "HTML-escaped sentinel (ampersand/angle brackets): expected exit 1 reporting the sentinel, got status=$status matched=$matched"
}

# F2: the negative gates must not hard-fail on caller-owned resources outside
# the ClickHouse set. A correctly migrated ClickHouse sink plus an unrelated
# plaintext secret_version and an unrelated managed random_password is an
# advisory (exit 4), not a ClickHouse leak (exit 1), and the message must name
# the non-ClickHouse resources.
case_non_clickhouse_plaintext_advisory() {
  local tmp status=0 named=0
  tmp="$(mktemp -d)"
  "$VERIFY" "$FIXTURES/state-non-clickhouse-plaintext-show.json" >"$tmp/out" 2>&1 || status=$?
  if grep -q "app_api_key" "$tmp/out" && grep -q "app_token" "$tmp/out"; then named=1; fi
  rm -rf "$tmp"
  { [ "$status" -eq 4 ] && [ "$named" -eq 1 ]; } \
    || fail "non-ClickHouse plaintext/generator: expected advisory exit 4 naming the resources, got status=$status named=$named"
}

# F3: a mistyped --sentinel-file is an unknown option, not a positional
# sentinel — it must exit 2, not silently disable the sentinel layer.
case_unknown_option_typo() {
  local tmp status=0
  tmp="$(mktemp -d)"
  printf '\npass word 123\n' >"$tmp/sentinels.txt"
  "$VERIFY" "$FIXTURES/state-whitespace-sentinel.json" --sentinel-fil "$tmp/sentinels.txt" >/dev/null 2>&1 || status=$?
  rm -rf "$tmp"
  [ "$status" -eq 2 ] || fail "mistyped --sentinel-file option: expected exit 2, got $status"
}

# F3: positional sentinels stay accepted (deprecated) in ANY order — one
# placed before --sentinel-file must still be applied.
case_positional_sentinel_before_flag() {
  local tmp status=0
  tmp="$(mktemp -d)"
  printf '\nSENTINEL-ABSENT-0006\n' >"$tmp/sentinels.txt"
  "$VERIFY" "$FIXTURES/state-whitespace-sentinel.json" "pass word 123" --sentinel-file "$tmp/sentinels.txt" >/dev/null 2>&1 || status=$?
  rm -rf "$tmp"
  [ "$status" -eq 1 ] || fail "positional sentinel before --sentinel-file: expected exit 1, got $status"
}

# F3: an option appearing after a positional sentinel must still be parsed —
# the sentinel file applies even when a positional precedes the flag.
case_positional_then_sentinel_file() {
  local tmp status=0
  tmp="$(mktemp -d)"
  printf '\npass word 123\n' >"$tmp/sentinels.txt"
  "$VERIFY" "$FIXTURES/state-whitespace-sentinel.json" UNRELATED-SENTINEL --sentinel-file "$tmp/sentinels.txt" >/dev/null 2>&1 || status=$?
  rm -rf "$tmp"
  [ "$status" -eq 1 ] || fail "sentinel file after a positional sentinel: expected exit 1, got $status"
}

# F8: a corrupt resource shape (instances is a string, not an array) is a jq
# error, not a clean bill — the negative gates must exit 2 rather than fail
# open or conflate the error with "no plaintext found".
case_corrupt_shape_instances_string() {
  expect 2 "corrupt-shape fixture (instances is a string)" \
    "$VERIFY" "$FIXTURES/state-corrupt-instances.json"
}

# F12: consumers run the script on their ROOT module's terraform show -json,
# where this module's resources nest under values.root_module.child_modules[].
# These three pin the recursive gates against that real consumer shape.
case_clean_child_module_show() {
  expect 0 "clean nested fixture (child_modules shape)" \
    "$VERIFY" "$FIXTURES/state-clean-child-module-show.json"
}

case_leaking_child_module_show() {
  expect 1 "leaking nested fixture (child_modules shape)" \
    "$VERIFY" "$FIXTURES/state-with-plaintext-child-module-show.json"
}

# All four unconditional ClickHouse sinks, exactly one not written through
# secret_string_wo: exit 3, and the "$ch_no_wo of $ch_total" partial-migration
# message path must fire.
case_partial_migration_child_module_show() {
  local tmp status=0 counted=0
  tmp="$(mktemp -d)"
  "$VERIFY" "$FIXTURES/state-partial-migration-child-module-show.json" >"$tmp/out" 2>&1 || status=$?
  if grep -q "1 of 4 ClickHouse" "$tmp/out"; then counted=1; fi
  rm -rf "$tmp"
  { [ "$status" -eq 3 ] && [ "$counted" -eq 1 ]; } \
    || fail "partial migration (child_modules shape): expected exit 3 with a '1 of 4' message, got status=$status counted=$counted"
}

# Makefile glob defense, run in a scratch directory so the decoy filename never
# lands in the repo (or the CI workspace) even if interrupted. Asserted on the
# reported reason rather than the exit code: make maps any failing recipe to
# its own exit 2, which would hide which check fired.
case_sentinel_glob_not_expanded() {
  local tmp status=0 matched=0
  tmp="$(mktemp -d)"
  ln -s "$REPO_ROOT/hack" "$tmp/hack"
  touch "$tmp/P@ssw0rdXYZ123"
  ( cd "$tmp" && make -f "$REPO_ROOT/Makefile" verify-no-plaintext \
      STATE="$FIXTURES/state-glob-sentinel.json" SENTINELS="P@ssw0rd*123" ) >"$tmp/out" 2>&1 || status=$?
  if grep -q "appears in state" "$tmp/out"; then matched=1; fi
  rm -rf "$tmp"
  { [ "$status" -ne 0 ] && [ "$matched" -eq 1 ]; } \
    || fail "a coincidentally-matching filename glob-expanded the sentinel into a false PASS (status=$status, sentinel reported=$matched)"
}

ALL_CASES=(
  leaking_state_pull
  clean_state_pull
  leaking_show_json
  clean_show_json
  empty_secret_string_state_pull
  empty_secret_string_show_json
  unwritten_secret
  malformed_input
  empty_input
  missing_state_file
  missing_sentinel_file
  whitespace_sentinel_file
  sentinel_file_blank_lines
  json_escaped_sentinel_quote_backslash
  json_escaped_sentinel_html_chars
  non_clickhouse_plaintext_advisory
  unknown_option_typo
  positional_sentinel_before_flag
  positional_then_sentinel_file
  corrupt_shape_instances_string
  clean_child_module_show
  leaking_child_module_show
  partial_migration_child_module_show
  sentinel_glob_not_expanded
)

main() {
  local cases=("$@")
  [ "${#cases[@]}" -gt 0 ] || cases=("${ALL_CASES[@]}")
  local c
  for c in "${cases[@]}"; do
    declare -F "case_$c" >/dev/null \
      || { echo "unknown case: $c (cases: ${ALL_CASES[*]})" >&2; exit 2; }
    "case_$c"
  done
  echo "OK: verify-no-plaintext self-test passed"
}

main "$@"
