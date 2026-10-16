#!/usr/bin/env bash
# Regression test for hack/verify-no-plaintext.sh — see that script's header for
# what it verifies and its scope. Run from anywhere:
#   hack/verify-no-plaintext.test.sh                  all cases (make selftest-verify-no-plaintext)
#   hack/verify-no-plaintext.test.sh <case> [case..]  only the named cases
#
# Every case asserts an exact exit code so the meanings stay distinct:
# 1 = plaintext found, 2 = usage/input error, 3 = write-only path not proven,
# 4 = advisory: known backup or non-ClickHouse resources carry plaintext /
# managed generators.
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

# expect_with_sentinel <code> <what> <state> <sentinel>: run with a one-line
# sentinel file and assert the exact exit code.
expect_with_sentinel() {
  local code="$1" what="$2" state="$3" tmp
  tmp="$(mktemp)"
  printf '%s\n' "$4" >"$tmp"
  expect "$code" "$what" "$VERIFY" "$state" --sentinel-file "$tmp"
  rm -f "$tmp"
}

case_leaking_state_pull() {
  expect_with_sentinel 1 "leaking fixture (state pull shape)" \
    "$FIXTURES/state-with-plaintext.json" SENTINEL-OTEL-0001
}

case_clean_state_pull() {
  expect_with_sentinel 0 "clean fixture (state pull shape)" \
    "$FIXTURES/state-clean.json" SENTINEL-OTEL-0001
}

case_leaking_show_json() {
  expect_with_sentinel 1 "leaking fixture (show -json shape)" \
    "$FIXTURES/state-with-plaintext-show.json" SENTINEL-OTEL-0002
}

case_clean_show_json() {
  expect_with_sentinel 0 "clean fixture (show -json shape)" \
    "$FIXTURES/state-clean-show.json" SENTINEL-OTEL-0002
}

# Post-migration remnant: the AWS provider leaves secret_string = "" (not
# absent) after a secret_string_wo write, and jq treats "" as truthy. This pins
# the fix that stops the empty string from false-FAILing a genuinely clean,
# correctly-migrated state. Covers both state shapes.
case_empty_secret_string_state_pull() {
  expect_with_sentinel 0 "post-migration empty-secret_string fixture (state pull shape)" \
    "$FIXTURES/state-clean-empty-secret-string.json" SENTINEL-OTEL-0001
}

case_empty_secret_string_show_json() {
  expect_with_sentinel 0 "post-migration empty-secret_string fixture (show -json shape)" \
    "$FIXTURES/state-clean-empty-secret-string-show.json" SENTINEL-OTEL-0002
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

# A sentinel containing whitespace must still be verified.
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

# F3: a mistyped --sentinel-file is an unknown option — it must exit 2, not
# silently disable the sentinel layer.
case_unknown_option_typo() {
  local tmp status=0
  tmp="$(mktemp -d)"
  printf '\npass word 123\n' >"$tmp/sentinels.txt"
  "$VERIFY" "$FIXTURES/state-whitespace-sentinel.json" --sentinel-fil "$tmp/sentinels.txt" >/dev/null 2>&1 || status=$?
  rm -rf "$tmp"
  [ "$status" -eq 2 ] || fail "mistyped --sentinel-file option: expected exit 2, got $status"
}

# F10: positional sentinels no longer exist — a stray argument must exit 2,
# not be silently ignored (which would skip the leak check).
case_positional_argument_rejected() {
  expect 2 "positional argument" "$VERIFY" "$FIXTURES/state-clean.json" SENTINEL-OTEL-0001
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
# secret_string_wo: exit 3, and the message must report the one unwritten sink.
case_partial_migration_child_module_show() {
  local tmp status=0 counted=0
  tmp="$(mktemp -d)"
  "$VERIFY" "$FIXTURES/state-partial-migration-child-module-show.json" >"$tmp/out" 2>&1 || status=$?
  if grep -q "FAIL: 1 ClickHouse secret version instances" "$tmp/out"; then counted=1; fi
  rm -rf "$tmp"
  { [ "$status" -eq 3 ] && [ "$counted" -eq 1 ]; } \
    || fail "partial migration (child_modules shape): expected exit 3 reporting one unwritten sink, got status=$status counted=$counted"
}

# F10: the removed SENTINELS make variable must error, not be silently ignored.
case_makefile_rejects_sentinels_var() {
  local status=0
  make -C "$REPO_ROOT" verify-no-plaintext STATE="$FIXTURES/state-clean.json" \
    SENTINELS=SENTINEL-OTEL-0001 >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "make accepted the removed SENTINELS variable"
}

# Generate the same mixed state in both supported Terraform formats. All
# passwords here are synthetic. The nested show shape also exercises callers
# that install this module below their root module.
mixed_backup_state() {
  local shape="$1" scenario="$2" target="${3:-}"
  jq -n --arg shape "$shape" --arg scenario "$scenario" --arg target "$target" '
    def secret: "SYNTHETIC-BACKUP-PASSWORD-\"\\&<>";
    def sink($name; $values): {
      mode: "managed", type: "aws_secretsmanager_secret_version",
      name: $name, values: $values
    };
    def generator($name): {
      mode: "managed", type: "random_password", name: $name,
      values: {result: secret}
    };
    ["clickhouse_admin", "clickhouse_otel", "clickhouse_monte_carlo",
     "clickhouse_schema_owner", "clickhouse_llm_worker", "clickhouse_readonly_user"] as $sql
    | ["clickhouse_backup", "clickhouse_backup_api", "clickhouse_backup_probe"] as $backup
    | [$sql[] | sink(. + "_password"; {
        has_secret_string_wo: true, secret_string: "", secret_string_wo_version: 1
      })] as $protected
    | [$backup[] | sink(.; {secret_string: secret, has_secret_string_wo: false}),
        generator(.)] as $known
    | ($protected + $known)
    | if $scenario == "sql_plaintext" then
        map(if .name == $target + "_password" then
          .values.secret_string = secret | .values.has_secret_string_wo = false
          else . end)
      elif $scenario == "sql_generator" then . + [generator($target)]
      elif $scenario == "sql_unwritten" then
        map(if .name == $target + "_password" then
          .values.has_secret_string_wo = false else . end)
      elif $scenario == "sql_missing_flag" then
        map(if .name == $target + "_password" then
          del(.values.has_secret_string_wo) else . end)
      elif $scenario == "unknown_plaintext" then
        . + [sink($target; {secret_string: secret, has_secret_string_wo: false})]
      elif $scenario == "unknown_generator" then . + [generator($target)]
      elif $scenario == "unknown_unwritten" then
        . + [sink($target; {has_secret_string_wo: false})]
      elif $scenario == "backup_only" then $known
      elif $scenario == "unknown_only" then
        $known + [sink($target; {has_secret_string_wo: true})]
      elif $scenario == "backup_empty" or $scenario == "backup_null" then
        $protected + [$backup[] | sink(.; {
          secret_string: (if $scenario == "backup_empty" then "" else null end)
        })]
      elif $scenario == "mixed_other" then
        . + [sink("app_api_key"; {secret_string: secret}), generator("app_token")]
      else . end
    | if $shape == "pull" then
        {version: 4, resources: map(
          .instances = [{attributes: .values}] | del(.values)
        )}
      else
        {format_version: "1.0", values: {root_module: {resources: [],
          child_modules: [{address: "module.example", resources: map(
            .address = "module.example." + .type + "." + .name
          )}]
        }}}
      end
  '
}

# The backup resources are a distinct advisory, never the same FAIL message
# as a regression in one of the protected SQL users. Reporting names is useful;
# reporting any of the password is not.
case_known_backup_advisory() {
  local tmp shape name status
  tmp="$(mktemp -d)"
  for shape in pull show; do
    mixed_backup_state "$shape" mixed >"$tmp/state.json"
    status=0
    "$VERIFY" "$tmp/state.json" >"$tmp/out" 2>&1 || status=$?
    [ "$status" -eq 4 ] || fail "known backups ($shape): expected advisory exit 4, got $status"
    grep -q "ADVISORY" "$tmp/out" || fail "known backups ($shape): missing advisory"
    if grep -q "FAIL:" "$tmp/out"; then fail "known backups ($shape): incorrectly reported a failure"; fi
    for name in clickhouse_backup clickhouse_backup_api clickhouse_backup_probe; do
      grep -qw "$name" "$tmp/out" || fail "known backups ($shape): missing resource name $name"
    done
    if grep -q "SYNTHETIC-BACKUP-PASSWORD" "$tmp/out"; then
      fail "known backups ($shape): diagnostic printed a password"
    fi
  done
  rm -rf "$tmp"
}

# Every protected SQL user must retain both negative checks. The plaintext
# cases also have a missing write-only flag, proving exit 1 wins over 3 and 4.
case_all_sql_users_remain_protected() {
  local tmp shape name scenario
  tmp="$(mktemp -d)"
  for shape in pull show; do
    for name in clickhouse_admin clickhouse_otel clickhouse_monte_carlo \
      clickhouse_schema_owner clickhouse_llm_worker clickhouse_readonly_user; do
      for scenario in sql_plaintext sql_generator; do
        mixed_backup_state "$shape" "$scenario" "$name" >"$tmp/state.json"
        expect 1 "$scenario for $name ($shape), despite known backup advisory" "$VERIFY" "$tmp/state.json"
      done
      for scenario in sql_unwritten sql_missing_flag; do
        mixed_backup_state "$shape" "$scenario" "$name" >"$tmp/state.json"
        expect 3 "$scenario for $name ($shape), despite known backup advisory" "$VERIFY" "$tmp/state.json"
      done
    done
  done
  rm -rf "$tmp"
}

# No wildcard exception: unfamiliar names, including ones resembling the
# allowed backup resources, remain strict until reviewed explicitly.
case_unknown_clickhouse_resources_remain_strict() {
  local tmp shape name scenario
  tmp="$(mktemp -d)"
  for shape in pull show; do
    for name in clickhouse_future_user clickhouse_backup_extra \
      clickhouse_backup_api_password clickhouse_backup_probe_extra; do
      for scenario in unknown_plaintext unknown_generator; do
        mixed_backup_state "$shape" "$scenario" "$name" >"$tmp/state.json"
        expect 1 "$scenario for unfamiliar resource $name ($shape)" "$VERIFY" "$tmp/state.json"
      done
      mixed_backup_state "$shape" unknown_unwritten "$name" >"$tmp/state.json"
      expect 3 "unfamiliar ClickHouse sink without write-only proof ($shape)" "$VERIFY" "$tmp/state.json"
    done
  done
  rm -rf "$tmp"
}

# Backup credentials cannot stand in for proof that SQL-user passwords used
# the write-only path. Nor can an unfamiliar resource with a true flag.
case_backups_do_not_prove_sql_migration() {
  local tmp shape scenario
  tmp="$(mktemp -d)"
  for shape in pull show; do
    for scenario in backup_only unknown_only; do
      mixed_backup_state "$shape" "$scenario" clickhouse_future_user >"$tmp/state.json"
      expect 3 "$scenario has no protected SQL-user proof ($shape)" "$VERIFY" "$tmp/state.json"
    done
  done
  rm -rf "$tmp"
}

case_empty_backup_secrets_are_not_plaintext() {
  local tmp shape scenario
  tmp="$(mktemp -d)"
  for shape in pull show; do
    for scenario in backup_empty backup_null; do
      mixed_backup_state "$shape" "$scenario" >"$tmp/state.json"
      expect 0 "$scenario is not plaintext and is outside SQL-user proof ($shape)" "$VERIFY" "$tmp/state.json"
    done
  done
  rm -rf "$tmp"
}

# A known backup resource is not exempt from an explicit sentinel search.
# The JSON-escaped password occurs only inside the known backup resources.
case_known_backups_do_not_hide_sentinels() {
  local tmp shape status
  tmp="$(mktemp -d)"
  for shape in pull show; do
    mixed_backup_state "$shape" mixed >"$tmp/state.json"
    jq -r '.. | objects | select(.name? == "clickhouse_backup_api")
      | (.values.secret_string // .instances[0].attributes.secret_string // empty)' \
      "$tmp/state.json" >"$tmp/sentinels.txt"
    [ -s "$tmp/sentinels.txt" ] || fail "sentinel fixture ($shape) is empty"
    status=0
    "$VERIFY" "$tmp/state.json" --sentinel-file "$tmp/sentinels.txt" >"$tmp/out" 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail "sentinel inside known backup ($shape): expected exit 1, got $status"
    grep -q "appears in state" "$tmp/out" || fail "sentinel inside known backup ($shape) was not reported"
    if grep -q "SYNTHETIC-BACKUP-PASSWORD" "$tmp/out"; then
      fail "sentinel inside known backup ($shape): diagnostic printed a password"
    fi
  done
  rm -rf "$tmp"
}

case_known_and_unrelated_advisories_stay_separate() {
  local tmp shape name status
  tmp="$(mktemp -d)"
  for shape in pull show; do
    mixed_backup_state "$shape" mixed_other >"$tmp/state.json"
    status=0
    "$VERIFY" "$tmp/state.json" >"$tmp/out" 2>&1 || status=$?
    [ "$status" -eq 4 ] || fail "known and unrelated advisory ($shape): expected exit 4, got $status"
    for name in clickhouse_backup_api app_api_key app_token; do
      grep -qw "$name" "$tmp/out" || fail "mixed advisory ($shape): missing $name"
    done
    grep -q "non-ClickHouse" "$tmp/out" || fail "mixed advisory ($shape): unrelated category missing"
    if grep -q "SYNTHETIC-BACKUP-PASSWORD" "$tmp/out"; then
      fail "mixed advisory ($shape): diagnostic printed a password"
    fi
  done
  rm -rf "$tmp"
}

case_corrupt_known_backup_state_is_input_error() {
  local tmp
  tmp="$(mktemp -d)"
  mixed_backup_state pull mixed | jq '
    (.resources[] | select(.name == "clickhouse_backup_api" and
      .type == "aws_secretsmanager_secret_version") | .instances) = "corrupt"
  ' >"$tmp/state.json"
  expect 2 "corrupt known backup state takes priority over advisory" "$VERIFY" "$tmp/state.json"
  rm -rf "$tmp"
}

# Clean six-sink state (pull shape) with one extra decoded string, so only the
# sentinel layer can catch it.
clean_state_with_value() {
  mixed_backup_state pull backup_empty | jq --arg v "$1" '.outputs = {value: $v}'
}

# run_sentinel_state <state-json-file> <sentinel-file>: sets status and out.
run_sentinel_state() {
  status=0
  "$VERIFY" "$1" --sentinel-file "$2" >"$tmp/out" 2>&1 || status=$?
}

# F4: bare --help exits 0 with usage on stdout (it used to exit 2).
case_help_flag() {
  local flag out status
  for flag in --help -h; do
    status=0
    out="$("$VERIFY" "$flag" 2>/dev/null)" || status=$?
    [ "$status" -eq 0 ] || fail "$flag: expected exit 0, got $status"
    case "$out" in usage:*) ;; *) fail "$flag: usage not printed to stdout" ;; esac
  done
}

# F6: each unconditional sink missing from an otherwise clean state must exit 3
# naming it; the count-gated admin/readonly sinks may be absent.
case_missing_unconditional_sink() {
  local tmp shape name status
  tmp="$(mktemp -d)"
  for shape in pull show; do
    for name in clickhouse_otel clickhouse_monte_carlo clickhouse_schema_owner clickhouse_llm_worker; do
      mixed_backup_state "$shape" backup_empty \
        | jq --arg n "${name}_password" 'del(.. | objects | select(.name? == $n))' >"$tmp/state.json"
      status=0
      "$VERIFY" "$tmp/state.json" >"$tmp/out" 2>&1 || status=$?
      [ "$status" -eq 3 ] || fail "missing ${name}_password ($shape): expected exit 3, got $status"
      grep -q "${name}_password" "$tmp/out" || fail "missing ${name}_password ($shape): sink not named"
    done
    for name in clickhouse_admin clickhouse_readonly_user; do
      mixed_backup_state "$shape" backup_empty \
        | jq --arg n "${name}_password" 'del(.. | objects | select(.name? == $n))' >"$tmp/state.json"
      expect 0 "count-gated ${name}_password absent ($shape)" "$VERIFY" "$tmp/state.json"
    done
  done
  rm -rf "$tmp"
}

# F12: a CRLF sentinel file (Windows/WSL) must still match.
case_crlf_sentinel_file() {
  local tmp status
  tmp="$(mktemp -d)"
  clean_state_with_value SENTINEL-OTEL-0009 >"$tmp/state.json"
  printf 'SENTINEL-OTEL-0009\r\n' >"$tmp/sentinels.txt"
  run_sentinel_state "$tmp/state.json" "$tmp/sentinels.txt"
  rm -rf "$tmp"
  [ "$status" -eq 1 ] || fail "CRLF sentinel file: expected exit 1, got $status"
}

# F12: a sentinel file with no trailing newline must still apply its last line.
case_sentinel_file_no_trailing_newline() {
  local tmp status
  tmp="$(mktemp -d)"
  clean_state_with_value SENTINEL-OTEL-0009 >"$tmp/state.json"
  printf '%s' 'SENTINEL-OTEL-0009' >"$tmp/sentinels.txt"
  run_sentinel_state "$tmp/state.json" "$tmp/sentinels.txt"
  rm -rf "$tmp"
  [ "$status" -eq 1 ] || fail "sentinel file without trailing newline: expected exit 1, got $status"
}

# F11: a sentinel embedded in a longer string (connection string, JSON blob)
# must match by substring, not only by equality.
case_embedded_sentinel_substring() {
  local tmp status
  tmp="$(mktemp -d)"
  clean_state_with_value 'clickhouse://otel:SENTINEL-OTEL-0009@ch:9000/db' >"$tmp/state.json"
  printf 'SENTINEL-OTEL-0009\n' >"$tmp/sentinels.txt"
  run_sentinel_state "$tmp/state.json" "$tmp/sentinels.txt"
  grep -q "appears in state" "$tmp/out" || { rm -rf "$tmp"; fail "embedded sentinel was not reported"; }
  rm -rf "$tmp"
  [ "$status" -eq 1 ] || fail "embedded sentinel: expected exit 1, got $status"
}

# F13: the detector's user-secret list must cover every ClickHouse user secret
# secrets.tf declares.
case_user_secret_list_matches_module() {
  local declared known
  declared="$(grep -o 'aws_secretsmanager_secret_version" "clickhouse_[a-z_]*_password"' "$REPO_ROOT/secrets.tf" \
    | grep -o 'clickhouse_[a-z_]*_password' | sort -u)"
  known="$(sed -n '/def is_user_secret/,/);/p' "$VERIFY" | grep -o 'clickhouse_[a-z_]*_password' | sort -u)"
  [ -n "$declared" ] || fail "no ClickHouse user secrets found in secrets.tf"
  [ "$declared" = "$known" ] \
    || fail "secrets.tf declares a ClickHouse user secret the detector does not verify (or vice versa): $(diff <(echo "$declared") <(echo "$known") | tr '\n' ' ')"
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
  positional_argument_rejected
  corrupt_shape_instances_string
  clean_child_module_show
  leaking_child_module_show
  partial_migration_child_module_show
  makefile_rejects_sentinels_var
  known_backup_advisory
  all_sql_users_remain_protected
  unknown_clickhouse_resources_remain_strict
  backups_do_not_prove_sql_migration
  empty_backup_secrets_are_not_plaintext
  known_backups_do_not_hide_sentinels
  known_and_unrelated_advisories_stay_separate
  corrupt_known_backup_state_is_input_error
  help_flag
  missing_unconditional_sink
  crlf_sentinel_file
  sentinel_file_no_trailing_newline
  embedded_sentinel_substring
  user_secret_list_matches_module
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
