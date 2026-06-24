.PHONY: default sanity-check test install-skill

SKILL_NAME := ao-data-platform
SKILL_SRC  := .claude/skills/$(SKILL_NAME)
# Install destination. Defaults to your personal skills directory (available in
# every project); override to install into a specific project, e.g.
#   make install-skill SKILL_DEST=/path/to/your/infra-repo/.claude/skills
SKILL_DEST ?= $(HOME)/.claude/skills

default:
	@echo "Read the readme"

install-skill:
	# Install the bundled Claude Code skill into a discoverable skills directory.
	# Claude Code auto-discovers skills under <dir>/.claude/skills; this copies the
	# whole self-contained skill (SKILL.md + references + scripts) there.
	mkdir -p "$(SKILL_DEST)"
	cp -R "$(SKILL_SRC)" "$(SKILL_DEST)/"
	@echo "Installed '$(SKILL_NAME)' skill to $(SKILL_DEST)/$(SKILL_NAME)"

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