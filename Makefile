.PHONY: default sanity-check test verify-no-plaintext selftest-verify-no-plaintext

default:
	@echo "Read the readme"

sanity-check:
	# Validate TF configuration files and formatting. Used in CI pipeline.
	terraform init -backend=false
	terraform fmt -recursive -check -diff
	terraform validate

test:
	# Run variable-validation tests. Requires Terraform >= 1.7 for mock_provider.
	# tests/*.tftest.hcl exercise the input safety nets (range checks on
	# cluster.main_node_group_size, the existing-cluster guard) — see the
	# test file's preamble for the explicit scope and known coverage gaps.
	terraform init -backend=false
	terraform test

verify-no-plaintext:
	# Fail if ClickHouse plaintext appears in a Terraform state JSON.
	# STATE is required; SENTINELS is an optional space-separated list of
	# passwords supplied during a migration apply.
	#   make verify-no-plaintext STATE=state.json SENTINELS="pw1 pw2"
	@test -n "$(STATE)" || { echo "STATE=<path/to/state.json> is required"; exit 2; }
	./hack/verify-no-plaintext.sh "$(STATE)" $(SENTINELS)

selftest-verify-no-plaintext:
	# Regression test for hack/verify-no-plaintext.sh against both fixtures.
	@! ./hack/verify-no-plaintext.sh tests/fixtures/state-with-plaintext.json SENTINEL-OTEL-0001 2>/dev/null \
		|| { echo "FAIL: leaking fixture was not detected"; exit 1; }
	@./hack/verify-no-plaintext.sh tests/fixtures/state-clean.json SENTINEL-OTEL-0001 >/dev/null \
		|| { echo "FAIL: clean fixture was rejected"; exit 1; }
	@echo "OK: verify-no-plaintext self-test passed"