#!/usr/bin/env bash
#
# preflight.sh — READ-ONLY pre-deployment checks for the Agent Observability data platform.
#
# Confirms the operator's tooling, AWS identity, and (optionally) DNS prerequisites are in
# place before a deploy. Makes no changes and reads no secrets. Reports PASS/WARN/FAIL.
#
# Usage:
#   preflight.sh [-r REGION] [--profile NAME] [--hosted-zone-id ZID] [-o FILE]
#
# Requirements: aws CLI (for identity / hosted-zone checks). terraform/kubectl/helm are
# checked for presence; a missing optional tool is a FAIL/WARN, never an abort.

set -uo pipefail

REGION=""; PROFILE=""; HZID=""; OUTFILE=""
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)        REGION="${2:-}"; shift 2 ;;
    --profile)          PROFILE="${2:-}"; shift 2 ;;
    --hosted-zone-id)   HZID="${2:-}"; shift 2 ;;
    -o|--output)        OUTFILE="${2:-}"; shift 2 ;;
    -h|--help)          usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done
[[ -n "$OUTFILE" ]] && exec > >(tee "$OUTFILE") 2>&1

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; BLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'
else RED=""; GRN=""; YEL=""; BLD=""; DIM=""; RST=""; fi

AWS=(aws); [[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE"); [[ -n "$REGION" ]] && AWS+=(--region "$REGION")
have() { command -v "$1" >/dev/null 2>&1; }

N_PASS=0; N_WARN=0; N_FAIL=0
rec() {  # status name detail
  case "$1" in
    PASS) N_PASS=$((N_PASS+1)); local c="$GRN" i="✔" ;;
    WARN) N_WARN=$((N_WARN+1)); local c="$YEL" i="⚠" ;;
    FAIL) N_FAIL=$((N_FAIL+1)); local c="$RED" i="✖" ;;
  esac
  printf '  %s%s %-4s%s %s%-22s%s %s\n' "$c" "$i" "$1" "$RST" "$BLD" "$2" "$RST" "${3:-}"
}

# Compare dotted versions: ver_ge A B  → true if A >= B.
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

echo "${BLD}Agent Observability data platform — deploy preflight (read-only)${RST}"
echo "${DIM}No changes are made. No secrets are read.${RST}"
echo ""

# ── tooling ───────────────────────────────────────────────────────────────────
echo "${BLD}Tooling${RST}"
if have terraform; then
  TFV="$(terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -n "$TFV" ]] && ver_ge "$TFV" "1.3.0"; then rec PASS "terraform" "v$TFV (>= 1.3)"
  else rec FAIL "terraform" "v${TFV:-?} — module requires >= 1.3"; fi
else rec FAIL "terraform" "not found on PATH"; fi

have aws     && rec PASS "aws CLI" "$(aws --version 2>&1 | head -1)"          || rec FAIL "aws CLI" "not found on PATH"
have kubectl && rec PASS "kubectl" "present"                                  || rec FAIL "kubectl" "not found — needed for post-apply verification"
have helm    && rec PASS "helm"    "present"                                  || rec WARN "helm" "not found — only needed if managing the chart yourself"

# ── AWS identity ────────────────────────────────────────────────────────────────
echo ""; echo "${BLD}AWS${RST}"
if ! have aws; then
  rec FAIL "AWS identity" "aws CLI missing — cannot verify credentials"
elif IDENT="$("${AWS[@]}" sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null)" && [[ -n "$IDENT" ]]; then
  ACCT="$(echo "$IDENT" | awk '{print $1}')"; ARN="$(echo "$IDENT" | awk '{print $2}')"
  rec PASS "AWS identity" "account ${ACCT} · ${ARN}"
else
  rec FAIL "AWS identity" "sts get-caller-identity failed — log in / set --profile (and re-check SSO token)"
fi

if [[ -n "$REGION" ]]; then rec PASS "region" "$REGION"
else rec WARN "region" "none passed (-r) — confirm the deploy region explicitly"; fi

# ── DNS (optional) ───────────────────────────────────────────────────────────
if [[ -n "$HZID" ]]; then
  echo ""; echo "${BLD}DNS${RST}"
  if ! have aws; then rec WARN "hosted zone" "aws CLI missing — cannot verify ${HZID}"
  elif ZONE="$("${AWS[@]}" route53 get-hosted-zone --id "$HZID" --query 'HostedZone.Name' --output text 2>/dev/null)" && [[ -n "$ZONE" && "$ZONE" != "None" ]]; then
    rec PASS "hosted zone" "${HZID} → ${ZONE}"
    echo "      ${DIM}confirm otel_collector_domain and clickhouse_domain sit within this zone${RST}"
  else
    rec FAIL "hosted zone" "${HZID} not found / not accessible with these credentials"
  fi
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
printf '%sPreflight:%s %s%d PASS%s  %s%d WARN%s  %s%d FAIL%s\n' \
  "$BLD" "$RST" "$GRN" "$N_PASS" "$RST" "$YEL" "$N_WARN" "$RST" "$RED" "$N_FAIL" "$RST"
[[ "$N_FAIL" -gt 0 ]] && echo "${DIM}Resolve FAILs against the Prerequisites doc before deploying.${RST}"
[[ "$N_FAIL" -gt 0 ]] && exit 1 || exit 0
