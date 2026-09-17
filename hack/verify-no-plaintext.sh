#!/usr/bin/env bash
# Verify a Terraform state JSON for the ClickHouse password migration:
#   1. no plaintext (negative gates), and
#   2. the ClickHouse secret writes actually went through the write-only path
#      (positive gate) — a state with no writes at all also has no plaintext.
#
# AWS-SPECIFIC: sinks are aws_secretsmanager_secret_version and the plaintext
# argument is secret_string. The Azure/GCP sibling modules (YET-2516/2517)
# ship their own verifiers.
#
# Usage: hack/verify-no-plaintext.sh <state.json> [--sentinel-file <file>] [sentinel ...]
#
# <state.json> comes first; --sentinel-file and positional sentinels may
# follow in either order. --sentinel-file takes a file with one sentinel per
# line (blank lines skipped). Prefer it over positional sentinels: a command
# line lands in shell history and in `ps` argv, and shell word-splitting
# cannot carry a sentinel that contains whitespace. Positional sentinels
# still work but are deprecated and warn. A sentinel cannot contain a
# newline — the sentinel file is line-oriented.
#
# Produce <state.json> with `terraform show -json > state.json` (local state) or
# `terraform state pull > state.json` (Terraform Cloud). Requires `jq`.
#
# Sentinel matching decodes the JSON first: each sentinel is compared against
# the state's decoded string values (substring match), so a password
# containing ", \, <, > or & is still caught even though `terraform show
# -json` emits those bytes JSON-escaped.
#
# Never echoes a secret: sentinels are reported by position, not by value.
#
# SCOPE: this script only makes sense for a deployment that has opted into the
# write-only path (clickhouse_write_only = true). Both of its rules assume that:
# a surviving managed random_password is reported as plaintext, and a sink
# without has_secret_string_wo fails the positive gate. On the legacy path both
# are the CORRECT state — managed generators and secret_string are what that
# path uses — so running this against a legacy deployment reports exit 1 or 3 by
# design, not a defect. Run it after the opt-in apply (README step 6).
#
# The negative gates sweep the whole state, not just ClickHouse resources, but
# split the verdict by resource name: hits on clickhouse*-named resources are
# a hard FAIL; hits on anything else are reported as an ADVISORY — worth
# investigating, but not proof of a ClickHouse leak (the sentinel file is
# authoritative for known passwords).
#
# Exit codes (first applicable wins: 2, then 1, then 3, then 4):
#   0  clean — no plaintext, and every ClickHouse sink used the write-only path
#   1  plaintext found (a ClickHouse-named sink still carries secret_string, a
#      ClickHouse-named managed random_password survives, or a supplied
#      sentinel appears anywhere in the state)
#   2  usage / input error (bad or unknown arguments, missing state or
#      sentinel file, malformed or empty JSON)
#   3  no plaintext, but the write-only path could not be proven
#   4  advisory only — non-ClickHouse resources carry a plaintext argument or
#      an unmanaged random_password
set -euo pipefail

usage() {
  echo "usage: $0 <state.json> [--sentinel-file <file>] [sentinel ...]" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

state="$1"
shift

sentinel_file=""
positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --sentinel-file)
    if [[ $# -lt 2 ]]; then
      echo "--sentinel-file requires a path" >&2
      exit 2
    fi
    sentinel_file="$2"
    shift 2
    ;;
  --sentinel-file=*)
    sentinel_file="${1#--sentinel-file=}"
    shift
    ;;
  --help | -h)
    usage
    exit 2
    ;;
  --)
    shift
    while [[ $# -gt 0 ]]; do
      positionals+=("$1")
      shift
    done
    ;;
  -*)
    echo "unknown option: $1" >&2
    exit 2
    ;;
  *)
    positionals+=("$1")
    shift
    ;;
  esac
done

if [[ ! -f "$state" ]]; then
  echo "no such file: $state" >&2
  exit 2
fi

if [[ -n "$sentinel_file" && ! -f "$sentinel_file" ]]; then
  echo "no such sentinel file: $sentinel_file" >&2
  exit 2
fi

# Malformed or empty input must not silently read as "no plaintext found":
# a truncated capture or an empty redirect has to fail loud, not fail open.
if ! jq -e . "$state" >/dev/null 2>&1; then
  echo "not valid (or empty) JSON: $state" >&2
  exit 2
fi

fail=0     # exit 1 — plaintext found
wofail=0   # exit 3 — write-only path not proven
advisory=0 # exit 4 — non-ClickHouse plaintext / unmanaged generators

# A jq failure mid-scan must exit 2, never read as "clean". jq's own stderr
# passes through; this adds the context line and the documented exit code.
jq_error() {
  echo "error: jq failed while scanning $state ($1) — see jq's message above" >&2
  exit 2
}

# A ClickHouse secret sink must carry no plaintext argument. An empty string
# is treated as absent: the AWS provider leaves secret_string = "" in state
# after a secret_string_wo migration (confirmed against real Secrets
# Manager — type str, length 0, does not hash-match the real value), and jq
# treats "" as truthy, so a bare presence test would false-FAIL on every
# correctly-migrated state. Hits are split by resource name: clickhouse*
# sinks are a hard FAIL, anything else is advisory.
if ! plaintext_hits="$(jq -r '
  def present: if . == null or . == "" then null else . end;
  [ .. | objects
    | select(.type? == "aws_secretsmanager_secret_version")
    | . as $r
    | select(
        ((($r.instances // []) | map(.attributes // {})) + [$r.values // {}])
        | any((.secret_string | present) != null))
    | ($r.name? // "<unnamed>")
    | if startswith("clickhouse") then "C\t" + . else "O\t" + . end
  ] | .[]
' "$state")"; then
  jq_error "plaintext secret_string scan"
fi

ch_plain=()
other_hits=()
while IFS=$'\t' read -r cls name; do
  case "$cls" in
  C) ch_plain+=("$name") ;;
  O) other_hits+=("$name") ;;
  esac
done <<<"$plaintext_hits"

# No managed random_password may remain — its result is plaintext in state.
# The mode filter matters: this repo now has six `ephemeral "random_password"`
# blocks with the identical type name. State JSON does not surface ephemeral
# instances today, so the filter is latent, but it keeps the check matching its
# own message if Terraform ever does surface them in `show -json`.
if ! gen_hits="$(jq -r '
  [ .. | objects
    | select(.type? == "random_password" and .mode? == "managed")
    | (.name? // "<unnamed>")
    | if startswith("clickhouse") then "C\t" + . else "O\t" + . end
  ] | .[]
' "$state")"; then
  jq_error "managed random_password scan"
fi

ch_gen=()
while IFS=$'\t' read -r cls name; do
  case "$cls" in
  C) ch_gen+=("$name") ;;
  O) other_hits+=("$name") ;;
  esac
done <<<"$gen_hits"

if [[ ${#ch_plain[@]} -gt 0 ]]; then
  echo "FAIL: a secret sink still carries a plaintext argument (secret_string)" >&2
  fail=1
fi

if [[ ${#ch_gen[@]} -gt 0 ]]; then
  echo "FAIL: managed random_password resources still present in state" >&2
  fail=1
fi

if [[ ${#other_hits[@]} -gt 0 ]]; then
  echo "ADVISORY: non-ClickHouse resources carry a plaintext argument or an unmanaged random_password: ${other_hits[*]}" >&2
  echo "ADVISORY: this is not proof of a ClickHouse leak — the sentinel file is authoritative for known passwords." >&2
  advisory=1
fi

# Positive gate. `has_secret_string_wo` is a computed, non-secret boolean the AWS
# provider persists on aws_secretsmanager_secret_version. Absence of plaintext is
# also true of a secret that was never written, so assert the write happened via
# the write-only argument.
if ! ch_total="$(jq '
  [ .. | objects
    | select(.type? == "aws_secretsmanager_secret_version")
    | select((.name? // "") | startswith("clickhouse"))
    | . as $r
    | (($r.instances // [] | map(.attributes // {})) + [$r.values // {}])
    | .[] | select(. != {})
  ] | length
' "$state")"; then
  jq_error "ClickHouse write-only positive gate"
fi

if ! ch_no_wo="$(jq '
  [ .. | objects
    | select(.type? == "aws_secretsmanager_secret_version")
    | select((.name? // "") | startswith("clickhouse"))
    | . as $r
    | (($r.instances // [] | map(.attributes // {})) + [$r.values // {}])
    | .[] | select(. != {})
    | select((.has_secret_string_wo // false) != true)
  ] | length
' "$state")"; then
  jq_error "ClickHouse write-only positive gate"
fi

if [[ "$ch_total" -eq 0 ]]; then
  echo "FAIL: no ClickHouse aws_secretsmanager_secret_version instances found in $state — cannot prove the write-only path was used" >&2
  wofail=1
elif [[ "$ch_no_wo" -gt 0 ]]; then
  echo "FAIL: $ch_no_wo of $ch_total ClickHouse secret version instances do not show has_secret_string_wo = true — the write did not go through secret_string_wo" >&2
  wofail=1
fi

# Any password supplied for the migration must not appear anywhere in the
# file. The comparison runs against DECODED string values, not raw bytes, so
# JSON escaping (", \) and Go's HTML escaping (<, >, &) in terraform show
# -json cannot hide a leaked value. jq exit 1 means not found; anything
# worse is an input error, not a clean bill.
check_sentinel() {
  local sentinel="$1" label="$2" rc=0
  jq -e --arg s "$sentinel" 'any(.. | strings; . == $s or contains($s))' "$state" >/dev/null || rc=$?
  case "$rc" in
  0)
    echo "FAIL: $label appears in state" >&2
    fail=1
    ;;
  1) : ;;
  *) jq_error "sentinel check ($label)" ;;
  esac
}

if [[ -n "$sentinel_file" ]]; then
  i=0
  while IFS= read -r sentinel || [[ -n "$sentinel" ]]; do
    i=$((i + 1))
    # Skip blank lines: an empty sentinel would match anything.
    [[ -n "$sentinel" ]] || continue
    check_sentinel "$sentinel" "sentinel file line #$i"
  done <"$sentinel_file"
fi

if [[ ${#positionals[@]} -gt 0 ]]; then
  echo "warning: passing sentinels as arguments is deprecated — they land in shell history and ps argv, and cannot carry whitespace. Use --sentinel-file." >&2
  i=0
  for sentinel in "${positionals[@]}"; do
    i=$((i + 1))
    [[ -n "$sentinel" ]] || continue
    check_sentinel "$sentinel" "supplied sentinel #$i"
  done
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi

if [[ $wofail -ne 0 ]]; then
  exit 3
fi

if [[ $advisory -ne 0 ]]; then
  exit 4
fi

echo "OK: no ClickHouse plaintext in $state; all $ch_total ClickHouse secret version instances used secret_string_wo"
exit 0
