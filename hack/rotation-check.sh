#!/usr/bin/env bash
# Post-apply rotation check for the ClickHouse credential secrets (YET-2680).
#
# Answers one question the Terraform plan cannot: did the rotation actually
# land in Secrets Manager, and is it live on the ClickHouse server? A forgotten
# clickhouse_password_versions bump is a silent no-op — the apply succeeds,
# nothing is written, and the operator proceeds to roll clients against a
# server that never learned the new password.
#
# NEVER prints or stores a password. It compares Secrets Manager VersionIds
# (and, in the baseline file, sha256 digests of values it reads and immediately
# discards). Passwords live in shell variables for the duration of the
# client probes and are passed to clickhouse-client via --password; nothing is
# echoed or logged.
#
# Usage:
#   rotation-check.sh <cluster> <user-slug> [--baseline FILE] [--region REGION]
#                     [--namespace NS] [--skip-reload]
#   rotation-check.sh --fixture CURRENT.json --baseline-fixture BASELINE.json
#
#   cluster    : the module's effective cluster name (secret name prefix)
#   user-slug  : otel | monte-carlo | schema-owner | llm-worker | admin | readonly-user
#   --baseline : a baseline file written by a pre-rotation run without --baseline;
#                the previous (B) secret's VersionId must have moved since then
#   --skip-reload: version diff only; no ESO force-sync / mount wait / reload / probe
#
# Exit codes: 0 = B secret moved AND (unless --skip-reload) the expected auth
# state is live on every CH pod; 1 = the B secret did not move, or the live
# state is wrong after reload; 2 = usage/input error.
set -euo pipefail

NAMESPACE=montecarlo
BUNDLE_ES=ao-clickhouse-auth-methods
MOUNT_TIMEOUT=120

usage() {
  cat >&2 <<'EOF'
usage: rotation-check.sh <cluster> <user-slug> [--baseline FILE] [--region R]
                          [--namespace NS] [--skip-reload]
       rotation-check.sh --fixture CURRENT.json --baseline-fixture BASE.json
EOF
  exit 2
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 2; }; }

CLUSTER=""
SLUG=""
BASELINE=""
REGION_ARG=()
FIXTURE=""
BASELINE_FIXTURE=""
SKIP_RELOAD=false

while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) BASELINE="$2"; shift 2 ;;
    --region) REGION_ARG=(--region "$2"); shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    --baseline-fixture) BASELINE_FIXTURE="$2"; shift 2 ;;
    --skip-reload) SKIP_RELOAD=true; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *)
      if [ -z "$CLUSTER" ]; then CLUSTER="$1"; elif [ -z "$SLUG" ]; then SLUG="$1"; else usage; fi
      shift ;;
  esac
done

# --- fixture mode (self-test; no AWS, no cluster) -----------------------------
if [ -n "$FIXTURE" ] || [ -n "$BASELINE_FIXTURE" ]; then
  require_cmd jq
  [ -n "$FIXTURE" ] && [ -n "$BASELINE_FIXTURE" ] || { echo "--fixture and --baseline-fixture go together" >&2; exit 2; }
  cur=$(jq -r '.VersionIdsToStages | to_entries[] | select(.value | index("AWSCURRENT")) | .key' "$FIXTURE")
  base=$(jq -r '.VersionIdsToStages | to_entries[] | select(.value | index("AWSCURRENT")) | .key' "$BASELINE_FIXTURE")
  [ -n "$cur" ] && [ -n "$base" ] || { echo "fixture missing an AWSCURRENT version" >&2; exit 2; }
  if [ "$cur" != "$base" ]; then
    echo "fixture check: version moved ($base -> $cur)"
    exit 0
  fi
  echo "fixture check: version did NOT move (still $cur)" >&2
  exit 1
fi

[ -n "$CLUSTER" ] && [ -n "$SLUG" ] || usage
require_cmd aws
require_cmd jq
# macOS has shasum, Linux has sha256sum; take whichever exists.
if command -v sha256sum >/dev/null 2>&1; then
  SHA256=sha256sum
else
  require_cmd shasum
  SHA256="shasum -a 256"
fi

case "$SLUG" in
  otel|monte-carlo|schema-owner|llm-worker|admin|readonly-user) ;;
  *) echo "unknown user slug: $SLUG" >&2; usage ;;
esac
CH_USER=${SLUG//-/_}

A_SECRET="$CLUSTER/clickhouse/$SLUG-credentials"
B_SECRET="$CLUSTER/clickhouse/$SLUG-previous-credentials"

# AWSCURRENT VersionId of a secret (fails the script if the secret is missing).
current_version() {
  aws secretsmanager describe-secret --secret-id "$1" "${REGION_ARG[@]}" \
    --query 'VersionIdsToStages' --output json |
    jq -r 'to_entries[] | select(.value | index("AWSCURRENT")) | .key'
}

# sha256 of a secret's value. The digest is all that leaves this function.
value_digest() {
  aws secretsmanager get-secret-value --secret-id "$1" "${REGION_ARG[@]}" \
    --query SecretString --output text | $SHA256 | cut -d' ' -f1
}

A_VERSION=$(current_version "$A_SECRET")
B_VERSION=$(current_version "$B_SECRET")

if [ -z "$BASELINE" ]; then
  # Baseline-capture mode: record versions + digests for the post-rotation run.
  # The file holds VersionIds and sha256 digests only — never a password.
  OUT="$CLUSTER-$SLUG-rotation-baseline.txt"
  (umask 077
    {
      printf '%s %s %s\n' "$A_SECRET" "$A_VERSION" "$(value_digest "$A_SECRET")"
      printf '%s %s %s\n' "$B_SECRET" "$B_VERSION" "$(value_digest "$B_SECRET")"
    } > "$OUT")
  echo "baseline written to $OUT (mode 600; versions + digests only)"
  exit 0
fi

[ -f "$BASELINE" ] || { echo "baseline file not found: $BASELINE" >&2; exit 2; }
A_BASE_VERSION=$(awk -v id="$A_SECRET" '$1 == id { print $2 }' "$BASELINE")
B_BASE_VERSION=$(awk -v id="$B_SECRET" '$1 == id { print $2 }' "$BASELINE")
[ -n "$A_BASE_VERSION" ] && [ -n "$B_BASE_VERSION" ] || { echo "baseline file does not cover both secrets" >&2; exit 2; }

# The version lever writes both sinks; the A sink only moves on the rotate
# apply (the cleanup rewrites the same A value at the same version lever,
# which Secrets Manager records as a no-op when the value is identical — so A
# is informational, B is the pass/fail signal: it moves on BOTH applies).
if [ "$A_VERSION" != "$A_BASE_VERSION" ]; then
  echo "A secret moved ($A_BASE_VERSION -> $A_VERSION)"
else
  echo "A secret unchanged ($A_VERSION) — expected on the cleanup apply"
fi
if [ "$B_VERSION" = "$B_BASE_VERSION" ]; then
  echo "FAIL: B secret $B_SECRET did not move (still $B_BASE_VERSION)." >&2
  echo "The apply was a silent no-op — clickhouse_password_versions.$CH_USER was not bumped." >&2
  exit 1
fi
echo "B secret moved ($B_BASE_VERSION -> $B_VERSION) — the rotation landed in Secrets Manager."

if $SKIP_RELOAD; then exit 0; fi

# --- live rollout: force-sync ESO, wait for the mount refresh, reload, probe --
# A secret change alone does NOT reload ClickHouse's users config (Spike
# Finding 5); this sequence is what makes the rotated password live.

require_cmd kubectl

ADMIN_SECRET="$CLUSTER/clickhouse/admin-credentials"
ADMIN_PW=$(aws secretsmanager get-secret-value --secret-id "$ADMIN_SECRET" "${REGION_ARG[@]}" \
  --query SecretString --output text 2>/dev/null) || {
  echo "cannot read $ADMIN_SECRET — admin must be enabled (it is the reload/probe user)" >&2
  exit 2
}

PODS=()
while IFS= read -r pod; do PODS+=("$pod"); done < <(
  kubectl -n "$NAMESPACE" get pods -l clickhouse.altinity.com/chi -o name | sed 's|^pod/||'
)
[ "${#PODS[@]}" -gt 0 ] || { echo "no ClickHouse pods found in namespace $NAMESPACE" >&2; exit 1; }

# The B value decides the expected server state: a real value means the
# <previous> method must be present; the sentinel "-" means it must be absent.
B_VALUE=$(aws secretsmanager get-secret-value --secret-id "$B_SECRET" "${REGION_ARG[@]}" \
  --query SecretString --output text)
EXPECT_PREVIOUS=true
if [ "$B_VALUE" = "-" ]; then EXPECT_PREVIOUS=false; fi

echo "force-syncing the auth-methods bundle ExternalSecret"
kubectl -n "$NAMESPACE" annotate externalsecret "$BUNDLE_ES" \
  force-sync="$(date +%s)" --overwrite >/dev/null

# Wait for the kubelet mount refresh on every pod: the mounted auth.xml must
# reflect the expected <previous> state (Spike Finding 12: ~30s typical).
#
# The file is one bundle covering every user, so the check is scoped to the
# target user's <NAME_auth_methods> block — an unscoped grep would read another
# user's concurrent rotation as this one's.
AUTH_XML=$(kubectl -n "$NAMESPACE" get externalsecret "$BUNDLE_ES" \
  -o jsonpath='{.spec.target.name}')
for pod in "${PODS[@]}"; do
  deadline=$(( $(date +%s) + MOUNT_TIMEOUT ))
  path="/etc/clickhouse-server/secrets.d/auth-methods.xml/$AUTH_XML/auth.xml"
  while true; do
    if kubectl -n "$NAMESPACE" exec "$pod" -c clickhouse -- sh -c \
      "sed -n '/<${CH_USER}_auth_methods>/,/<\\/${CH_USER}_auth_methods>/p' '$path' | grep -q '<previous>'" \
      2>/dev/null; then
      present=true
    else
      present=false
    fi
    [ "$present" = "$EXPECT_PREVIOUS" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || {
      echo "FAIL: $pod still shows <previous>=$present after ${MOUNT_TIMEOUT}s (expected $EXPECT_PREVIOUS)" >&2
      exit 1
    }
    sleep 5
  done
  echo "$pod: mount refreshed (previous=$EXPECT_PREVIOUS)"
done

# SYSTEM RELOAD CONFIG on each pod — instant, restartless, no dropped
# connections (Spike Finding 6).
for pod in "${PODS[@]}"; do
  kubectl -n "$NAMESPACE" exec "$pod" -c clickhouse -- clickhouse-client \
    --user admin --password "$ADMIN_PW" --query "SYSTEM RELOAD CONFIG" >/dev/null
  echo "$pod: SYSTEM RELOAD CONFIG applied"
done

# Probe both passwords as the rotated user on every pod. The A value must
# authenticate. The B value must authenticate while it is a real password, and
# must be REJECTED once it is back to the sentinel.
A_VALUE=$(aws secretsmanager get-secret-value --secret-id "$A_SECRET" "${REGION_ARG[@]}" \
  --query SecretString --output text)

probe() { # pod user password -> 0 if the server accepted the credential
  kubectl -n "$1" exec "$2" -c clickhouse -- clickhouse-client \
    --user "$3" --password "$4" --query "SELECT 1" 2>/dev/null | grep -q '^1$'
}

for pod in "${PODS[@]}"; do
  probe "$NAMESPACE" "$pod" "$CH_USER" "$A_VALUE" || {
    echo "FAIL: $pod rejected the current (A) password for $CH_USER" >&2
    exit 1
  }
  if $EXPECT_PREVIOUS; then
    probe "$NAMESPACE" "$pod" "$CH_USER" "$B_VALUE" || {
      echo "FAIL: $pod rejected the previous (B) password for $CH_USER during the rotation window" >&2
      exit 1
    }
  else
    probe "$NAMESPACE" "$pod" "$CH_USER" "$B_VALUE" && {
      echo "FAIL: $pod accepted the sentinel as a password for $CH_USER — the previous method did not drop" >&2
      exit 1
    }
  fi
  echo "$pod: probe OK for $CH_USER (A accepted; B $( $EXPECT_PREVIOUS && echo accepted || echo rejected ))"
done

echo "rotation-check passed: version moved and the expected auth state is live on ${#PODS[@]} pod(s)."
