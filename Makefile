.PHONY: default sanity-check test verify-no-plaintext selftest-verify-no-plaintext \
	rotation-check selftest-rotation-check

default:
	@echo "Read the readme"

sanity-check:
	# Validate TF configuration files and formatting. Used in CI pipeline.
	terraform init -backend=false
	terraform fmt -recursive -check -diff
	terraform validate

test:
	# Run variable-validation tests. Requires Terraform >= 1.12 (the module floor).
	# tests/*.tftest.hcl exercise the input safety nets (range checks on
	# cluster.main_node_group_size, the existing-cluster guard) — see the
	# test file's preamble for the explicit scope and known coverage gaps.
	terraform init -backend=false
	terraform test

verify-no-plaintext:
	# Verify a Terraform state JSON: no ClickHouse plaintext, and every ClickHouse
	# secret write went through secret_string_wo. Requires jq.
	#
	# STATE is required. Pass the migration passwords via SENTINEL_FILE (one per
	# line), not SENTINELS — see the script header; make/shell word-splitting
	# silently drops a whitespace-containing SENTINELS value:
	#   make verify-no-plaintext STATE=state.json SENTINEL_FILE=sentinels.txt
	#
	# `set -f` disables globbing so a sentinel containing shell wildcards is not
	# expanded against the working directory into a false PASS.
	@test -n "$(STATE)" || { echo "STATE=<path/to/state.json> is required"; exit 2; }
	set -f; ./hack/verify-no-plaintext.sh "$(STATE)" $(if $(SENTINEL_FILE),--sentinel-file "$(SENTINEL_FILE)",) $(SENTINELS)

selftest-verify-no-plaintext:
	# Regression suite for hack/verify-no-plaintext.sh — cases, the exact
	# exit-code discipline, and single-case invocation live in the script
	# (see its header).
	@./hack/verify-no-plaintext.test.sh

rotation-check:
	# Verify a ClickHouse password rotation actually landed in Secrets Manager and
	# is live on every ClickHouse pod. CLUSTER and SLUG are required; BASELINE is
	# the file written by a pre-rotation run (one without BASELINE), which is what
	# turns the run from baseline capture into a pass/fail check.
	#   make rotation-check CLUSTER=ao-dev-us1 SLUG=otel                  # capture
	#   make rotation-check CLUSTER=ao-dev-us1 SLUG=otel BASELINE=~/rot.txt  # check
	#
	# Needs kubectl pointed at the cell's cluster and AWS credentials that can read
	# the ClickHouse secrets. Passwords are never printed; see the script header.
	@test -n "$(CLUSTER)" || { echo "CLUSTER=<cluster-name> is required"; exit 2; }
	@test -n "$(SLUG)" || { echo "SLUG=<otel|monte-carlo|schema-owner|llm-worker|admin|readonly-user> is required"; exit 2; }
	./hack/rotation-check.sh "$(CLUSTER)" "$(SLUG)" $(if $(BASELINE),--baseline "$(BASELINE)",)

selftest-rotation-check:
	# Regression test for hack/rotation-check.sh against recorded fixtures: the
	# moved case (exit 0), the unmoved case (exit 1), and usage errors (exit 2).
	# Fixture mode reads a recorded describe-secret JSON, so this needs no AWS
	# credentials and no cluster.
	@status=0; ./hack/rotation-check.sh --fixture tests/fixtures/rotation-versions-after.json \
		--baseline-fixture tests/fixtures/rotation-versions-before.json >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 0 ] || { echo "FAIL: a landed rotation expected exit 0, got $$status"; exit 1; }
	@status=0; ./hack/rotation-check.sh --fixture tests/fixtures/rotation-versions-before.json \
		--baseline-fixture tests/fixtures/rotation-versions-before.json >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 1 ] || { echo "FAIL: an unmoved secret expected exit 1, got $$status"; exit 1; }
	@status=0; ./hack/rotation-check.sh >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 2 ] || { echo "FAIL: missing arguments expected exit 2, got $$status"; exit 1; }
	# A fixture flag without its pair is an input error, not a silent pass.
	@status=0; ./hack/rotation-check.sh --fixture tests/fixtures/rotation-versions-after.json >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 2 ] || { echo "FAIL: a lone --fixture expected exit 2, got $$status"; exit 1; }
	@echo "OK: rotation-check self-test passed"
