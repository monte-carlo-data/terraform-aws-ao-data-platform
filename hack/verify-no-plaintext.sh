#!/usr/bin/env bash
# Fail if ClickHouse password plaintext appears in a Terraform state JSON.
#
# Usage: hack/verify-no-plaintext.sh <state.json> [sentinel ...]
#
# Produce <state.json> with `terraform show -json > state.json` (local state) or
# `terraform state pull > state.json` (Terraform Cloud).
#
# Never echoes a secret: sentinels are reported by position, not by value.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <state.json> [sentinel ...]" >&2
  exit 2
fi

state="$1"
shift

if [[ ! -f "$state" ]]; then
  echo "no such file: $state" >&2
  exit 2
fi

# Malformed or empty input must not silently read as "no plaintext found":
# a truncated capture or an empty redirect has to fail loud, not fail open.
if ! jq -e . "$state" >/dev/null 2>&1; then
  echo "not valid (or empty) JSON: $state" >&2
  exit 2
fi

fail=0

# A ClickHouse secret sink must carry no plaintext argument.
if jq -e '
  [ .. | objects
    | select(.type? == "aws_secretsmanager_secret_version"
          or .type? == "azurerm_key_vault_secret"
          or .type? == "google_secret_manager_secret_version")
    | (.instances // [] | .[].attributes // {}), (.values // {})
    | select((.secret_string // .value // .secret_data) != null)
  ] | length > 0
' "$state" >/dev/null 2>&1; then
  echo "FAIL: a secret sink still carries a plaintext argument (secret_string/value/secret_data)" >&2
  fail=1
fi

# No managed random_password may remain — its result is plaintext in state.
if jq -e '[.. | objects | select(.type? == "random_password")] | length > 0' "$state" >/dev/null 2>&1; then
  echo "FAIL: managed random_password resources still present in state" >&2
  fail=1
fi

# Any password supplied for the migration must not appear anywhere in the file.
i=0
for sentinel in "$@"; do
  i=$((i + 1))
  if grep -Fq -- "$sentinel" "$state"; then
    echo "FAIL: supplied sentinel #$i appears in state" >&2
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "OK: no ClickHouse plaintext in $state"
fi
exit $fail
