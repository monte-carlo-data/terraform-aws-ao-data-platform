#!/usr/bin/env bash
#
# skill-drift-check.sh — CI guard against drift between the bundled ao-data-platform
# Claude Code skill and the module it documents.
#
# Maintainer tooling (lives in hack/, NOT inside the skill — the skill dir is copied
# verbatim to customers by `make install-skill`). Run via `make skill-check`, and as
# part of `make sanity-check`.
#
# Checks the things that silently break the skill if the module changes:
#   1. Outputs the skill's scripts/guidance key off still exist in outputs.tf.
#   2. Every references/*.md named in SKILL.md exists.
#   3. Both bundled scripts parse and are executable.
#
# This is intentionally a small, explicit contract — not a parser. When the skill grows
# a new hard dependency on a module output, add it to REQUIRED_OUTPUTS below.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/.claude/skills/ao-data-platform"
OUTPUTS_TF="$ROOT/outputs.tf"

FAILS=0
fail() { echo "  ✖ $*"; FAILS=$((FAILS + 1)); }
ok()   { echo "  ✔ $*"; }

echo "Skill drift check (ao-data-platform)"

# 1 — module outputs the skill depends on must exist.
echo "Outputs the skill depends on:"
REQUIRED_OUTPUTS=(
  montecarlo_namespace                          # collect-state.sh derives the namespace
  eks_cluster_name                              # collect-state.sh + deploy update-kubeconfig
  clickhouse_monte_carlo_credentials_secret_arn # deploy: creds hand-off to Monte Carlo
  clickhouse_otel_credentials_secret_arn        # troubleshoot: ExternalSecret source
)
for out in "${REQUIRED_OUTPUTS[@]}"; do
  if grep -qE "^output \"${out}\"" "$OUTPUTS_TF"; then ok "output \"$out\""
  else fail "output \"$out\" referenced by the skill is missing from outputs.tf — update the skill or the list"; fi
done

# 2 — reference files named in SKILL.md must exist.
echo "Reference files named in SKILL.md:"
while IFS= read -r ref; do
  if [[ -f "$SKILL/$ref" ]]; then ok "$ref"
  else fail "SKILL.md references '$ref' but the file is missing"; fi
done < <(grep -oE 'references/[a-z]+\.md' "$SKILL/SKILL.md" | sort -u)

# 3 — bundled scripts parse and are executable.
echo "Bundled scripts:"
for s in collect-state.sh preflight.sh; do
  p="$SKILL/scripts/$s"
  if [[ ! -f "$p" ]]; then fail "$s missing"; continue; fi
  bash -n "$p" 2>/dev/null && ok "$s parses" || fail "$s has a syntax error"
  [[ -x "$p" ]] && ok "$s is executable" || fail "$s is not executable (chmod +x)"
done

echo ""
if [[ "$FAILS" -gt 0 ]]; then
  echo "skill-drift-check: $FAILS problem(s) — the skill is out of sync with the module."
  exit 1
fi
echo "skill-drift-check: OK"
