.PHONY: default sanity-check test test-rotation-model

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
	# This guard needs its own check: terraform test cannot expect prevent_destroy errors.
	python3 tests/verify_backup_versioning_guard.py

test-rotation-model:
	# Run the credential rotation model in spec/credential-rotation. It is a
	# separate Terraform root, so it needs its own init and the `test` target
	# above does not reach it. See that directory's README for scope and limits.
	terraform -chdir=spec/credential-rotation init -backend=false
	terraform -chdir=spec/credential-rotation test
