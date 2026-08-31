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
	# Fail if ClickHouse plaintext appears in a Terraform state JSON.
	# STATE is required; SENTINELS is an optional space-separated list of
	# passwords supplied during a migration apply.
	#   make verify-no-plaintext STATE=state.json SENTINELS="pw1 pw2"
	@test -n "$(STATE)" || { echo "STATE=<path/to/state.json> is required"; exit 2; }
	set -f; ./hack/verify-no-plaintext.sh "$(STATE)" $(SENTINELS)

selftest-verify-no-plaintext:
	# Regression test for hack/verify-no-plaintext.sh: both state shapes
	# (terraform state pull vs. terraform show -json), malformed/empty
	# input, and the Makefile's defense against sentinel glob-expansion.
	@! ./hack/verify-no-plaintext.sh tests/fixtures/state-with-plaintext.json SENTINEL-OTEL-0001 2>/dev/null \
		|| { echo "FAIL: leaking fixture (state pull shape) was not detected"; exit 1; }
	@./hack/verify-no-plaintext.sh tests/fixtures/state-clean.json SENTINEL-OTEL-0001 >/dev/null \
		|| { echo "FAIL: clean fixture (state pull shape) was rejected"; exit 1; }
	@! ./hack/verify-no-plaintext.sh tests/fixtures/state-with-plaintext-show.json SENTINEL-OTEL-0002 2>/dev/null \
		|| { echo "FAIL: leaking fixture (show -json shape) was not detected"; exit 1; }
	@./hack/verify-no-plaintext.sh tests/fixtures/state-clean-show.json SENTINEL-OTEL-0002 >/dev/null \
		|| { echo "FAIL: clean fixture (show -json shape) was rejected"; exit 1; }
	@tmp="$$(mktemp)"; \
		printf 'not valid json {{{' > "$$tmp"; \
		status=0; ./hack/verify-no-plaintext.sh "$$tmp" >/dev/null 2>&1 || status=$$?; \
		rm -f "$$tmp"; \
		[ "$$status" -eq 2 ] || { echo "FAIL: malformed input did not exit 2 (got $$status)"; exit 1; }
	@tmp="$$(mktemp)"; \
		status=0; ./hack/verify-no-plaintext.sh "$$tmp" >/dev/null 2>&1 || status=$$?; \
		rm -f "$$tmp"; \
		[ "$$status" -eq 2 ] || { echo "FAIL: empty input did not exit 2 (got $$status)"; exit 1; }
	@decoy="P@ssw0rdXYZ123"; \
		touch -- "$$decoy"; \
		status=0; $(MAKE) --no-print-directory verify-no-plaintext STATE=tests/fixtures/state-glob-sentinel.json SENTINELS="P@ssw0rd*123" >/dev/null 2>&1 || status=$$?; \
		rm -f -- "$$decoy"; \
		[ "$$status" -ne 0 ] || { echo "FAIL: a coincidentally-matching filename glob-expanded the sentinel into a false PASS"; exit 1; }
	@echo "OK: verify-no-plaintext self-test passed"