#!/usr/bin/env bash
# Verify a Terraform state JSON for the ClickHouse password migration:
#   1. no plaintext (negative gate), and
#   2. the ClickHouse secret writes actually went through the write-only path
#      (positive gate) — a state with no writes at all also has no plaintext.
#
# Usage: hack/verify-no-plaintext.sh <state.json> [--sentinel-file <file>] [sentinel ...]
#
# Produce <state.json> with `terraform show -json > state.json` (local state) or
# `terraform state pull > state.json` (Terraform Cloud). Requires `jq`.
#
# --sentinel-file takes a file with one sentinel per line (blank lines skipped).
# Prefer it over positional sentinels: a command line lands in shell history and
# in `ps` argv, and shell word-splitting cannot carry a sentinel that contains
# whitespace. Positional sentinels still work but are deprecated and warn.
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
# Exit codes:
#   0  clean — no plaintext, and every ClickHouse sink used the write-only path
#   1  plaintext found (a plaintext argument, a managed random_password, or a
#      supplied sentinel present in the state)
#   2  usage / input error (missing or unreadable file, malformed or empty JSON)
#   3  no plaintext, but the write-only path could not be proven
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
    break
    ;;
  *)
    break
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

fail=0   # exit 1 — plaintext found
wofail=0 # exit 3 — write-only path not proven

# A ClickHouse secret sink must carry no plaintext argument. An empty string
# is treated as absent: the AWS provider leaves secret_string = "" in state
# after a secret_string_wo migration (confirmed against real Secrets
# Manager — type str, length 0, does not hash-match the real value), and jq
# treats "" as truthy, so a bare `// .value // .secret_data` would false-FAIL
# on every correctly-migrated state.
if jq -e '
  def present: if . == null or . == "" then null else . end;
  [ .. | objects
    | select(.type? == "aws_secretsmanager_secret_version"
          or .type? == "azurerm_key_vault_secret"
          or .type? == "google_secret_manager_secret_version")
    | (.instances // [] | .[].attributes // {}), (.values // {})
    | select(((.secret_string | present) // (.value | present) // (.secret_data | present)) != null)
  ] | length > 0
' "$state" >/dev/null 2>&1; then
  echo "FAIL: a secret sink still carries a plaintext argument (secret_string/value/secret_data)" >&2
  fail=1
fi

# No managed random_password may remain — its result is plaintext in state.
# The mode filter matters: this repo now has six `ephemeral "random_password"`
# blocks with the identical type name. State JSON does not surface ephemeral
# instances today, so the filter is latent, but it keeps the check matching its
# own message if Terraform ever does surface them in `show -json`.
if jq -e '
  [ .. | objects
    | select(.type? == "random_password" and .mode? == "managed")
  ] | length > 0
' "$state" >/dev/null 2>&1; then
  echo "FAIL: managed random_password resources still present in state" >&2
  fail=1
fi

# Positive gate. `has_secret_string_wo` is a computed, non-secret boolean the AWS
# provider persists on aws_secretsmanager_secret_version. Absence of plaintext is
# also true of a secret that was never written, so assert the write happened via
# the write-only argument.
ch_total="$(jq '
  [ .. | objects
    | select(.type? == "aws_secretsmanager_secret_version")
    | select((.name? // "") | startswith("clickhouse"))
    | . as $r
    | (($r.instances // [] | map(.attributes // {})) + [$r.values // {}])
    | .[] | select(. != {})
  ] | length
' "$state")"

ch_no_wo="$(jq '
  [ .. | objects
    | select(.type? == "aws_secretsmanager_secret_version")
    | select((.name? // "") | startswith("clickhouse"))
    | . as $r
    | (($r.instances // [] | map(.attributes // {})) + [$r.values // {}])
    | .[] | select(. != {})
    | select((.has_secret_string_wo // false) != true)
  ] | length
' "$state")"

if [[ "$ch_total" -eq 0 ]]; then
  echo "FAIL: no ClickHouse aws_secretsmanager_secret_version instances found in $state — cannot prove the write-only path was used" >&2
  wofail=1
elif [[ "$ch_no_wo" -gt 0 ]]; then
  echo "FAIL: $ch_no_wo of $ch_total ClickHouse secret version instances do not show has_secret_string_wo = true — the write did not go through secret_string_wo" >&2
  wofail=1
fi

# Any password supplied for the migration must not appear anywhere in the file.
check_sentinel() {
  local sentinel="$1" label="$2"
  if grep -Fq -- "$sentinel" "$state"; then
    echo "FAIL: $label appears in state" >&2
    fail=1
  fi
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

if [[ $# -gt 0 ]]; then
  echo "warning: passing sentinels as arguments is deprecated — they land in shell history and ps argv, and cannot carry whitespace. Use --sentinel-file." >&2
  i=0
  for sentinel in "$@"; do
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

echo "OK: no ClickHouse plaintext in $state; all $ch_total ClickHouse secret version instances used secret_string_wo"
exit 0
