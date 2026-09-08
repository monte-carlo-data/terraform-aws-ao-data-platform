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
	# STATE is required. SENTINEL_FILE is the preferred way to supply the passwords
	# used in a migration apply — one per line, in a file, so they stay out of
	# shell history and out of `ps` argv:
	#   make verify-no-plaintext STATE=state.json SENTINEL_FILE=sentinels.txt
	#
	# SENTINELS (space-separated) is retained for compatibility but is discouraged:
	# it puts secrets on a command line and make/shell word-splitting means a
	# sentinel containing whitespace is silently split and never verified. Use
	# SENTINEL_FILE for anything that may contain a space.
	#
	# `set -f` disables globbing so a sentinel containing shell wildcards is not
	# expanded against the working directory into a false PASS.
	@test -n "$(STATE)" || { echo "STATE=<path/to/state.json> is required"; exit 2; }
	set -f; ./hack/verify-no-plaintext.sh "$(STATE)" $(if $(SENTINEL_FILE),--sentinel-file "$(SENTINEL_FILE)",) $(SENTINELS)

selftest-verify-no-plaintext:
	# Regression test for hack/verify-no-plaintext.sh. Covers both state shapes
	# (terraform state pull vs. terraform show -json), the negative gate
	# (plaintext / managed random_password / sentinels), the post-migration
	# secret_string = "" remnant that must read as absent (not plaintext), the
	# positive gate (has_secret_string_wo proves the write-only path was used),
	# malformed and empty and missing input, the sentinel-file path, and the
	# Makefile's defense against sentinel glob-expansion.
	#
	# Every case asserts an exact exit code so the three meanings stay distinct:
	# 1 = plaintext found, 2 = usage/input error, 3 = write-only path not proven.
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-with-plaintext.json SENTINEL-OTEL-0001 >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 1 ] || { echo "FAIL: leaking fixture (state pull shape) expected exit 1, got $$status"; exit 1; }
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-clean.json SENTINEL-OTEL-0001 >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 0 ] || { echo "FAIL: clean fixture (state pull shape) expected exit 0, got $$status"; exit 1; }
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-with-plaintext-show.json SENTINEL-OTEL-0002 >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 1 ] || { echo "FAIL: leaking fixture (show -json shape) expected exit 1, got $$status"; exit 1; }
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-clean-show.json SENTINEL-OTEL-0002 >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 0 ] || { echo "FAIL: clean fixture (show -json shape) expected exit 0, got $$status"; exit 1; }
	# Post-migration remnant: the AWS provider leaves secret_string = "" (not
	# absent) after a secret_string_wo write. jq treats "" as truthy, so this
	# pins the fix that stops the empty string from false-FAILing a genuinely
	# clean, correctly-migrated state. Covers both state shapes.
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-clean-empty-secret-string.json SENTINEL-OTEL-0001 >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 0 ] || { echo "FAIL: post-migration empty-secret_string fixture (state pull shape) expected exit 0, got $$status"; exit 1; }
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-clean-empty-secret-string-show.json SENTINEL-OTEL-0002 >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 0 ] || { echo "FAIL: post-migration empty-secret_string fixture (show -json shape) expected exit 0, got $$status"; exit 1; }
	# Positive gate: no plaintext, but nothing was ever written through
	# secret_string_wo. Must not read as clean.
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-no-write.json >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 3 ] || { echo "FAIL: unwritten-secret fixture expected exit 3, got $$status"; exit 1; }
	@tmp="$$(mktemp)"; \
		printf 'not valid json {{{' > "$$tmp"; \
		status=0; ./hack/verify-no-plaintext.sh "$$tmp" >/dev/null 2>&1 || status=$$?; \
		rm -f "$$tmp"; \
		[ "$$status" -eq 2 ] || { echo "FAIL: malformed input did not exit 2 (got $$status)"; exit 1; }
	@tmp="$$(mktemp)"; \
		status=0; ./hack/verify-no-plaintext.sh "$$tmp" >/dev/null 2>&1 || status=$$?; \
		rm -f "$$tmp"; \
		[ "$$status" -eq 2 ] || { echo "FAIL: empty input did not exit 2 (got $$status)"; exit 1; }
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/definitely-not-a-file.json >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 2 ] || { echo "FAIL: missing state file did not exit 2 (got $$status)"; exit 1; }
	@status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-clean.json --sentinel-file tests/fixtures/definitely-not-a-file.txt >/dev/null 2>&1 || status=$$?; \
		[ "$$status" -eq 2 ] || { echo "FAIL: missing sentinel file did not exit 2 (got $$status)"; exit 1; }
	# Sentinel file: a sentinel containing whitespace must still be verified —
	# the argv path cannot carry one, which is why the file path exists.
	@tmp="$$(mktemp -d)"; \
		printf '\npass word 123\n' > "$$tmp/sentinels.txt"; \
		status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-whitespace-sentinel.json --sentinel-file "$$tmp/sentinels.txt" >/dev/null 2>&1 || status=$$?; \
		rm -rf "$$tmp"; \
		[ "$$status" -eq 1 ] || { echo "FAIL: whitespace sentinel from a sentinel file expected exit 1, got $$status"; exit 1; }
	# Blank lines in a sentinel file must be skipped, not treated as a sentinel
	# that matches everything.
	@tmp="$$(mktemp -d)"; \
		printf '\nSENTINEL-ABSENT-0003\n\n' > "$$tmp/sentinels.txt"; \
		status=0; ./hack/verify-no-plaintext.sh tests/fixtures/state-clean.json --sentinel-file "$$tmp/sentinels.txt" >/dev/null 2>&1 || status=$$?; \
		rm -rf "$$tmp"; \
		[ "$$status" -eq 0 ] || { echo "FAIL: clean fixture with an absent sentinel file expected exit 0, got $$status"; exit 1; }
	# Makefile glob defense, run in a scratch directory so the decoy filename
	# never lands in the repo (or the CI workspace) even if interrupted.
	# Asserted on the reported reason rather than the exit code: make maps any
	# failing recipe to its own exit 2, which would hide which check fired.
	@tmp="$$(mktemp -d)"; \
		trap 'rm -rf "$$tmp"' EXIT INT TERM; \
		ln -s "$(CURDIR)/hack" "$$tmp/hack"; \
		cp "$(CURDIR)/Makefile" "$$tmp/Makefile"; \
		touch "$$tmp/P@ssw0rdXYZ123"; \
		status=0; \
		( cd "$$tmp" && $(MAKE) --no-print-directory verify-no-plaintext \
			STATE="$(CURDIR)/tests/fixtures/state-glob-sentinel.json" SENTINELS="P@ssw0rd*123" ) >"$$tmp/out" 2>&1 || status=$$?; \
		matched=0; grep -q "appears in state" "$$tmp/out" && matched=1; \
		rm -rf "$$tmp"; \
		[ "$$status" -ne 0 ] && [ "$$matched" -eq 1 ] || { echo "FAIL: a coincidentally-matching filename glob-expanded the sentinel into a false PASS (status=$$status, sentinel reported=$$matched)"; exit 1; }
	@echo "OK: verify-no-plaintext self-test passed"

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
