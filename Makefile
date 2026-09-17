.PHONY: default sanity-check test verify-no-plaintext selftest-verify-no-plaintext

default:
	@echo "Read the readme"

sanity-check:
	# Validate TF configuration files and formatting. Used in CI pipeline.
	terraform init -backend=false
	terraform fmt -recursive -check -diff
	terraform validate

test:
	# Run variable-validation tests. Requires Terraform >= 1.11 (the module floor).
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
