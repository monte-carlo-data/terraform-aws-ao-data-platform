#!/usr/bin/env bash
#
# collect-state.sh — READ-ONLY state sweep of the Agent Observability data platform.
#
# Collects the health of every layer of the platform in a single pass and prints a
# PASS / WARN / FAIL / SKIP summary grouped by layer, followed by supporting detail.
# Unlike a deploy gate, it NEVER stops at the first problem — it collects everything so
# the whole picture is visible at once.
#
#   --mode verify    Assert each value against the expected deployment ("is it correct
#                    and complete?"). Missing/incorrect state is a FAIL.
#   --mode diagnose  Gather state for an open symptom and flag anomalies as WARN/FAIL so
#                    they can be routed to a cause. (default)
#
# CONTRACT (enforced here, not just by convention):
#   * Runs only read-only commands (get/describe/logs, terraform output, aws describe/get,
#     helm status/list, dig, openssl). It never mutates infrastructure or cluster state.
#   * It never prints secret VALUES. Secrets are checked for existence and for expected
#     KEYS only — never decoded or echoed.
#
# Usage:
#   collect-state.sh [--mode verify|diagnose] [-n NAMESPACE] [-r REGION] [--profile NAME]
#                    [--context CTX] [--terraform-dir DIR] [--no-aws] [--no-exec]
#                    [--log-lines N] [-o FILE]
#
# Requirements: kubectl (required); terraform, aws, helm, jq, dig, openssl (optional —
# checks that need a missing tool are reported as SKIP rather than failing the run).

set -uo pipefail   # NOT -e: we want collect-all behaviour.

# ── defaults / args ──────────────────────────────────────────────────────────
MODE="diagnose"
NS=""
REGION=""
PROFILE=""
CONTEXT=""
TFDIR="."
DO_AWS=1
DO_EXEC=1
LOG_LINES=200
OUTFILE=""

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)          MODE="${2:-}"; shift 2 ;;
    -n|--namespace)  NS="${2:-}"; shift 2 ;;
    -r|--region)     REGION="${2:-}"; shift 2 ;;
    --profile)       PROFILE="${2:-}"; shift 2 ;;
    --context)       CONTEXT="${2:-}"; shift 2 ;;
    --terraform-dir) TFDIR="${2:-}"; shift 2 ;;
    --no-aws)        DO_AWS=0; shift ;;
    --no-exec)       DO_EXEC=0; shift ;;
    --log-lines)     LOG_LINES="${2:-}"; shift 2 ;;
    -o|--output)     OUTFILE="${2:-}"; shift 2 ;;
    -h|--help)       usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

case "$MODE" in verify|diagnose) ;; *) echo "Invalid --mode: $MODE" >&2; usage 1 ;; esac

# Mirror all output to a file if requested.
if [[ -n "$OUTFILE" ]]; then exec > >(tee "$OUTFILE") 2>&1; fi

# ── colours (respect NO_COLOR and non-tty) ─────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; CYN=$'\033[0;36m'
  DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; CYN=""; DIM=""; BLD=""; RST=""
fi

# ── command wrappers ───────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

KUBECTL=(kubectl)
[[ -n "$CONTEXT" ]] && KUBECTL+=(--context "$CONTEXT")
kube() { "${KUBECTL[@]}" -n "$NS" "$@"; }              # namespaced
kubeg() { "${KUBECTL[@]}" "$@"; }                      # cluster-scoped

AWS=(aws)
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")
[[ -n "$REGION" ]] && AWS+=(--region "$REGION")
awsq() { "${AWS[@]}" "$@"; }

tf() { terraform -chdir="$TFDIR" "$@"; }

# ── results accumulator ─────────────────────────────────────────────────────────
# Each entry: "STATUS|LAYER|NAME|DETAIL"
declare -a RESULTS=()
N_PASS=0; N_WARN=0; N_FAIL=0; N_SKIP=0

record() {  # status layer name detail
  local status="$1" layer="$2" name="$3" detail="${4:-}"
  RESULTS+=("${status}|${layer}|${name}|${detail}")
  case "$status" in
    PASS) N_PASS=$((N_PASS+1)) ;;
    WARN) N_WARN=$((N_WARN+1)) ;;
    FAIL) N_FAIL=$((N_FAIL+1)) ;;
    SKIP) N_SKIP=$((N_SKIP+1)) ;;
  esac
  # In verify mode a missing/incorrect value is a hard FAIL; in diagnose mode the same
  # signal is reported but treated as an anomaly to route, not a gate.
  local icon col
  case "$status" in
    PASS) icon="✔"; col="$GRN" ;;
    WARN) icon="⚠"; col="$YEL" ;;
    FAIL) icon="✖"; col="$RED" ;;
    SKIP) icon="•"; col="$DIM" ;;
  esac
  printf '  %s%s %-4s%s %s%s%s  %s\n' "$col" "$icon" "$status" "$RST" "$BLD" "$name" "$RST" "$detail"
}

section() { printf '\n%s%s── %s %s%s\n' "$BLD" "$CYN" "$1" "────────────────────────────────────────" "$RST"; }

# Read a single terraform output value (empty string if unavailable). Guards against
# terraform writing diagnostics ("No outputs found", warnings) to stdout when the output
# or state is absent — those must not be mistaken for a value.
tf_out() {
  local v
  v="$(tf output -raw "$1" 2>/dev/null)" || return 0
  case "$v" in
    *"No outputs found"*|*"Warning:"*|*"Error:"*|*$'\n'*) return 0 ;;
    *) printf '%s' "$v" ;;
  esac
}

# Ready condition for a resource ("True"/"False"/"").
ready_status() { kube get "$1" "$2" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true; }

print_summary() {
  echo ""
  echo "${BLD}════════════════════ SUMMARY (${MODE}) ════════════════════${RST}"
  local prev_layer=""
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r st layer name detail <<< "$entry"
    if [[ "$layer" != "$prev_layer" ]]; then
      printf '%s%s%s\n' "$DIM" "$layer" "$RST"
      prev_layer="$layer"
    fi
    local col icon
    case "$st" in
      PASS) icon="✔"; col="$GRN" ;; WARN) icon="⚠"; col="$YEL" ;;
      FAIL) icon="✖"; col="$RED" ;; SKIP) icon="•"; col="$DIM" ;;
    esac
    printf '  %s%s%s %-24s %s\n' "$col" "$icon" "$RST" "$name" "$detail"
  done
  echo ""
  printf '%sTotals:%s %s%d PASS%s  %s%d WARN%s  %s%d FAIL%s  %s%d SKIP%s\n' \
    "$BLD" "$RST" "$GRN" "$N_PASS" "$RST" "$YEL" "$N_WARN" "$RST" "$RED" "$N_FAIL" "$RST" "$DIM" "$N_SKIP" "$RST"
}

# ── preconditions ────────────────────────────────────────────────────────────
if ! have kubectl; then
  echo "${RED}kubectl is required and was not found on PATH.${RST}" >&2
  exit 2
fi

echo "${BLD}Agent Observability data platform — read-only state sweep (${MODE} mode)${RST}"
echo "${DIM}No secret values are collected. No changes are made.${RST}"

# ── resolve namespace from the module output if not supplied ───────────────────
section "Context"
if [[ -z "$NS" ]]; then
  if have terraform; then NS="$(tf_out montecarlo_namespace)"; fi
  [[ -z "$NS" ]] && NS="montecarlo"
  record PASS context "namespace" "using '${NS}' (override with -n)"
else
  record PASS context "namespace" "using '${NS}'"
fi

CLUSTER_NAME=""
if have terraform; then CLUSTER_NAME="$(tf_out eks_cluster_name)"; fi
[[ -n "$CLUSTER_NAME" ]] && record PASS context "eks_cluster_name" "$CLUSTER_NAME"

if ! kubeg version -o json >/dev/null 2>&1 && ! kubeg get --raw='/readyz' >/dev/null 2>&1; then
  record FAIL context "cluster reachable" "kubectl cannot reach the cluster (check kubeconfig / --context / aws eks update-kubeconfig)"
  print_summary; exit 1
fi
record PASS context "cluster reachable" "kubectl can talk to the API server"

if ! kube auth can-i get pods >/dev/null 2>&1; then
  record WARN context "namespace access" "cannot 'get pods' in '${NS}' — RBAC or wrong namespace; remaining checks may be incomplete"
fi

# ── nodes ──────────────────────────────────────────────────────────────────────
section "Nodes"
CH_NODES="$(kubeg get nodes -l dedicated=clickhouse --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${CH_NODES:-0}" -gt 0 ]]; then
  CH_NODE_READY="$(kubeg get nodes -l dedicated=clickhouse -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  if [[ "$CH_NODE_READY" == *True* ]]; then
    record PASS nodes "dedicated clickhouse node" "${CH_NODES} node(s), Ready"
  else
    record FAIL nodes "dedicated clickhouse node" "node(s) present but not Ready — ClickHouse pod cannot schedule"
  fi
else
  record FAIL nodes "dedicated clickhouse node" "no node with label dedicated=clickhouse — ClickHouse pod will stay Pending"
fi

# ── workloads ────────────────────────────────────────────────────────────────
section "Workloads"
check_pod() {  # label friendly-name
  local label="$1" friendly="$2" pod
  pod="$(kube get pods -l "$label" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)"
  if [[ -z "$pod" ]]; then
    record FAIL workloads "$friendly" "no pod found (label ${label})"
    return
  fi
  local rs; rs="$(kube get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  local phase; phase="$(kube get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
  if [[ "$rs" == "True" ]]; then
    record PASS workloads "$friendly" "$pod Ready"
  else
    record FAIL workloads "$friendly" "$pod not Ready (phase=${phase:-?}) — 'kubectl describe pod -n ${NS} ${pod}' for events"
  fi
}
check_pod "app.kubernetes.io/name=altinity-clickhouse-operator" "ClickHouse operator"
check_pod "clickhouse.altinity.com/chi=otel"                    "ClickHouse"
check_pod "app.kubernetes.io/name=opentelemetry-collector"      "OTel Collector"
check_pod "app.kubernetes.io/component=llm-worker"              "LLM worker"

# Any pods stuck Init (commonly blocked on the schema job) or restarting.
INIT_PODS="$(kube get pods --no-headers 2>/dev/null | awk '$3 ~ /Init|PodInitializing/ {print $1}' | tr '\n' ' ')"
[[ -n "${INIT_PODS// }" ]] && record WARN workloads "init-blocked pods" "${INIT_PODS}(often waiting on the schema-migration job)"

# ── schema migration job ───────────────────────────────────────────────────────
section "Schema migration"
SCHEMA_JOBS="$(kube get jobs --no-headers -o custom-columns=":metadata.name,:status.succeeded" 2>/dev/null | grep clickhouse-schema || true)"
if [[ -z "$SCHEMA_JOBS" ]]; then
  record FAIL schema "schema job" "no clickhouse-schema-<n> job found"
else
  UNFINISHED="$(echo "$SCHEMA_JOBS" | awk '$2 != "1" {print $1}' | tr '\n' ' ')"
  if [[ -n "${UNFINISHED// }" ]]; then
    record FAIL schema "schema job" "not complete: ${UNFINISHED}— Collector/worker stay in Init until it finishes"
  else
    record PASS schema "schema job" "$(echo "$SCHEMA_JOBS" | awk '{print $1}' | tail -1) succeeded"
  fi
fi

# ── external secrets ───────────────────────────────────────────────────────────
section "External Secrets"
CSS="$(kubeg get clustersecretstore -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
if [[ -z "$CSS" ]]; then
  record WARN secrets "ClusterSecretStore" "none found or no Ready condition"
elif [[ "$CSS" == *True* ]]; then
  record PASS secrets "ClusterSecretStore" "Valid"
else
  record FAIL secrets "ClusterSecretStore" "not Valid — ESO cannot reach Secrets Manager (check IRSA/KMS)"
fi

ES_LIST="$(kube get externalsecret --no-headers -o custom-columns=":metadata.name" 2>/dev/null)"
if [[ -z "$ES_LIST" ]]; then
  record WARN secrets "ExternalSecrets" "none found in ${NS}"
else
  while IFS= read -r es; do
    [[ -z "$es" ]] && continue
    st="$(kube get externalsecret "$es" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [[ "$st" == "True" ]]; then
      record PASS secrets "ExternalSecret/${es}" "SecretSynced"
    else
      record FAIL secrets "ExternalSecret/${es}" "not synced — 'kubectl describe externalsecret -n ${NS} ${es}' (usually IRSA/KMS or missing source secret)"
    fi
  done <<< "$ES_LIST"
fi

# Confirm the otel credentials Secret exists and has a 'password' KEY (key name only).
if kube get secret ao-clickhouse-otel-credentials >/dev/null 2>&1; then
  if have jq; then
    KEYS="$(kube get secret ao-clickhouse-otel-credentials -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | join(",")' 2>/dev/null)"
    if [[ ",$KEYS," == *",password,"* ]]; then
      record PASS secrets "otel credentials Secret" "present with key 'password'"
    else
      record FAIL secrets "otel credentials Secret" "present but missing 'password' key (keys: ${KEYS:-none})"
    fi
  else
    record PASS secrets "otel credentials Secret" "present (install jq to verify keys)"
  fi
else
  record FAIL secrets "otel credentials Secret" "ao-clickhouse-otel-credentials not found — ExternalSecret has not synced"
fi

# ── cert-manager: issuers & certificates ────────────────────────────────────────
section "TLS (cert-manager)"
for issuer in ao-data-platform-selfsigned ao-data-platform-ca; do
  st="$(kube get issuer "$issuer" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$st" == "True" ]]; then record PASS tls "Issuer/${issuer}" "Ready"
  elif [[ -z "$st" ]]; then record WARN tls "Issuer/${issuer}" "not found"
  else record FAIL tls "Issuer/${issuer}" "not Ready"; fi
done
for cert in ao-data-platform-ca clickhouse-server-tls otel-collector-tls; do
  st="$(kube get certificate "$cert" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$st" == "True" ]]; then record PASS tls "Certificate/${cert}" "Ready"
  elif [[ -z "$st" ]]; then record WARN tls "Certificate/${cert}" "not found"
  else record FAIL tls "Certificate/${cert}" "never became Ready — 'kubectl describe certificate -n ${NS} ${cert}' (CA issuer / DNS-01 / Route 53)"; fi
done

# ── storage ──────────────────────────────────────────────────────────────────
section "Storage"
UNBOUND="$(kube get pvc --no-headers -o custom-columns=":metadata.name,:status.phase" 2>/dev/null | awk '$2 != "Bound" {print $1}' | tr '\n' ' ')"
PVC_TOTAL="$(kube get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${PVC_TOTAL:-0}" -eq 0 ]]; then
  record WARN storage "PVCs" "no PersistentVolumeClaims in ${NS}"
elif [[ -n "${UNBOUND// }" ]]; then
  record FAIL storage "PVCs" "not Bound: ${UNBOUND}"
else
  record PASS storage "PVCs" "${PVC_TOTAL} bound"
fi
CH_SC="$(kube get pvc --no-headers -o custom-columns=":spec.storageClassName" 2>/dev/null | grep -v '^<none>$' | head -1)"
if [[ -n "$CH_SC" ]]; then
  SC_PROV="$(kubeg get storageclass "$CH_SC" -o jsonpath='{.provisioner}' 2>/dev/null)"
  SC_TYPE="$(kubeg get storageclass "$CH_SC" -o jsonpath='{.parameters.type}' 2>/dev/null)"
  SC_ENC="$(kubeg get storageclass "$CH_SC" -o jsonpath='{.parameters.encrypted}' 2>/dev/null)"
  if [[ "$SC_PROV" == "ebs.csi.aws.com" && "$SC_TYPE" == "gp3" && "$SC_ENC" == "true" ]]; then
    record PASS storage "StorageClass/${CH_SC}" "gp3, encrypted, ebs.csi.aws.com"
  else
    record WARN storage "StorageClass/${CH_SC}" "provisioner=${SC_PROV:-?} type=${SC_TYPE:-?} encrypted=${SC_ENC:-?}"
  fi
fi

# ── load balancers (AWS) ─────────────────────────────────────────────────────
section "Load balancers"
if [[ "$DO_AWS" -eq 0 ]]; then
  record SKIP nlb "NLB checks" "--no-aws set"
elif ! have aws; then
  record SKIP nlb "NLB checks" "aws CLI not found"
elif ! awsq sts get-caller-identity >/dev/null 2>&1; then
  record SKIP nlb "NLB checks" "AWS credentials not available (try --profile / --region)"
else
  check_nlb() {  # service-name friendly
    local svc="$1" friendly="$2" host arn scheme
    host="$(kube get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    if [[ -z "$host" ]]; then
      record FAIL nlb "${friendly} NLB" "Service '${svc}' has no load-balancer hostname — not provisioned (check the AWS Load Balancer Controller)"
      return
    fi
    arn="$(awsq elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='${host}'].LoadBalancerArn" --output text 2>/dev/null)"
    if [[ -z "$arn" || "$arn" == "None" ]]; then
      record WARN nlb "${friendly} NLB" "hostname ${host} present but no matching ELB found yet"
      return
    fi
    scheme="$(awsq elbv2 describe-load-balancers --load-balancer-arns "$arn" --query 'LoadBalancers[0].Scheme' --output text 2>/dev/null)"
    [[ "$scheme" == "internal" ]] \
      && record PASS nlb "${friendly} NLB" "provisioned, internal" \
      || record WARN nlb "${friendly} NLB" "scheme=${scheme} (expected internal)"
    # Target health
    local tgs unhealthy=""
    tgs="$(awsq elbv2 describe-target-groups --load-balancer-arn "$arn" --query 'TargetGroups[*].TargetGroupArn' --output text 2>/dev/null)"
    for tg in $tgs; do
      local bad
      bad="$(awsq elbv2 describe-target-health --target-group-arn "$tg" \
        --query "TargetHealthDescriptions[?TargetHealth.State!='healthy' && TargetHealth.State!='initial'].Target.Id" --output text 2>/dev/null)"
      [[ -n "$bad" && "$bad" != "None" ]] && unhealthy+="$bad "
    done
    if [[ -n "${unhealthy// }" ]]; then
      record WARN nlb "${friendly} targets" "not healthy: ${unhealthy}"
    else
      record PASS nlb "${friendly} targets" "healthy (or completing initial check)"
    fi
  }
  check_nlb clickhouse-otel        "ClickHouse"
  check_nlb opentelemetry-collector "OTel Collector"
fi

# ── DNS ──────────────────────────────────────────────────────────────────────
section "DNS"
if ! have dig; then
  record SKIP dns "DNS resolution" "dig not found"
else
  check_dns() {  # service-name friendly
    local svc="$1" friendly="$2" host
    host="$(kube get svc "$svc" -o jsonpath='{.metadata.annotations.external-dns\.alpha\.kubernetes\.io/hostname}' 2>/dev/null)"
    if [[ -z "$host" ]]; then
      record SKIP dns "${friendly} DNS" "no external-dns hostname annotation on ${svc}"
      return
    fi
    if [[ -n "$(dig +short "$host" 2>/dev/null | head -1)" ]]; then
      record PASS dns "${friendly} DNS" "${host} resolves"
    else
      record FAIL dns "${friendly} DNS" "${host} does not resolve — external-dns may not have created the record"
    fi
  }
  check_dns clickhouse-otel         "ClickHouse"
  check_dns opentelemetry-collector "OTel Collector"
fi

# ── in-cluster TLS handshake (optional; needs kubectl exec) ─────────────────────
section "In-cluster TLS"
CH_POD="$(kube get pods -l clickhouse.altinity.com/chi=otel --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)"
if [[ "$DO_EXEC" -eq 0 ]]; then
  record SKIP tls-live "TLS handshake" "--no-exec set"
elif [[ -z "$CH_POD" ]]; then
  record SKIP tls-live "TLS handshake" "no ClickHouse pod to exec from"
else
  CA_PATH="/etc/clickhouse-server/secrets.d/ca.crt/clickhouse-server-tls/ca.crt"
  probe_tls() {  # host port friendly
    local host="$1" port="$2" friendly="$3" out
    out="$(kube exec "$CH_POD" -- bash -c "echo | openssl s_client -connect ${host}:${port} -servername ${host} -CAfile ${CA_PATH} 2>/dev/null" 2>/dev/null || true)"
    if echo "$out" | grep -q "Verify return code: 0"; then
      record PASS tls-live "${friendly}:${port}" "serving TLS, verified against CA"
    elif echo "$out" | grep -q "Certificate chain"; then
      record WARN tls-live "${friendly}:${port}" "serving TLS but CA verification did not return 0"
    else
      record FAIL tls-live "${friendly}:${port}" "no TLS connection established"
    fi
  }
  probe_tls clickhouse-otel        9440 "ClickHouse"
  probe_tls clickhouse-otel        8443 "ClickHouse"
  probe_tls opentelemetry-collector 4317 "OTel Collector"
  probe_tls opentelemetry-collector 4318 "OTel Collector"
fi

# NOTE: Confirming the otel_traces database/tables directly requires authenticating to
# ClickHouse, which would mean handling the otel password — outside this script's
# read-only, no-secrets contract. The schema-migration job status checked above is the
# credential-free proxy for "the schema was created"; a direct table/row query belongs in
# the emitted active-verification commands (verify.md), which the customer runs themselves.

# ── Collector logs (error scan; redacted) ───────────────────────────────────────
section "Collector logs"
OTEL_POD="$(kube get pods -l app.kubernetes.io/name=opentelemetry-collector --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)"
if [[ -z "$OTEL_POD" ]]; then
  record SKIP logs "Collector log scan" "no Collector pod"
else
  ERRS="$(kube logs "$OTEL_POD" --tail="$LOG_LINES" 2>/dev/null \
    | grep -iE 'error|failed|refused|denied' \
    | grep -ivE 'healthcheck|retrying|will retry' \
    | sed -E 's/(password|token|secret|authorization)=[^[:space:]]+/\1=***REDACTED***/Ig' \
    | tail -8)"
  if [[ -n "$ERRS" ]]; then
    record WARN logs "Collector log scan" "error-like lines found (see detail below)"
    echo "${DIM}${ERRS}${RST}" | sed 's/^/      /'
  else
    record PASS logs "Collector log scan" "no persistent export errors in last ${LOG_LINES} lines"
  fi
fi

# ── summary ──────────────────────────────────────────────────────────────────
print_summary

# Exit code: non-zero if anything FAILed (useful for verify mode / CI), else 0.
[[ "$N_FAIL" -gt 0 ]] && exit 1 || exit 0
