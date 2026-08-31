# ClickHouse Passwords — generated when not caller-supplied; stored in Secrets
# Manager and synced into the cluster by ESO (never passed through Helm values).
#
# Generation is an `ephemeral` resource and the sinks below use write-only
# arguments, so no password reaches Terraform state or plan files (YET-2514).
# Consequences worth knowing:
#   - Each plan/apply mints a NEW ephemeral value. It is only ever written when
#     the matching clickhouse_password_versions field changes, so a steady-state
#     apply is a no-op despite the regenerated value.
#   - The locals below are ephemeral (they reference an ephemeral resource), so
#     Terraform will reject any use of them outside a write-only argument. That
#     is the invariant this change buys, enforced by the language.

locals {
  # admin is a gated break-glass superuser (off by default), so — like
  # readonly_user — its password, secret, and chart wiring are all conditional
  # on its enabled flag. Both flags are non-ephemeral: they derive from
  # var.helm, so they may legally drive count.
  clickhouse_admin_enabled         = try(var.helm.clickhouse.admin.enabled, false)
  clickhouse_readonly_user_enabled = try(var.helm.clickhouse.readonly_user.enabled, false)

  # Caller-supplied password wins; otherwise the generated one. No null-check
  # gate on generation any more: `count` cannot derive from an ephemeral value,
  # and it no longer needs to — an unused ephemeral resource costs nothing
  # because it has no state. This is why the old nonsensitive() wrappers are
  # gone.
  #
  # coalesce (not a != null ternary) also skips the empty string, so `otel = ""`
  # now generates a password instead of writing an empty secret. Deliberate: an
  # empty ClickHouse password is never a legitimate input.
  clickhouse_otel_password         = coalesce(var.clickhouse_passwords.otel, ephemeral.random_password.clickhouse_otel.result)
  clickhouse_monte_carlo_password  = coalesce(var.clickhouse_passwords.monte_carlo, ephemeral.random_password.clickhouse_monte_carlo.result)
  clickhouse_schema_owner_password = coalesce(var.clickhouse_passwords.schema_owner, ephemeral.random_password.clickhouse_schema_owner.result)
  clickhouse_llm_worker_password   = coalesce(var.clickhouse_passwords.llm_worker, ephemeral.random_password.clickhouse_llm_worker.result)
  clickhouse_admin_password = local.clickhouse_admin_enabled ? coalesce(
    var.clickhouse_passwords.admin, ephemeral.random_password.clickhouse_admin[0].result
  ) : null
  clickhouse_readonly_user_password = local.clickhouse_readonly_user_enabled ? coalesce(
    var.clickhouse_passwords.readonly_user, ephemeral.random_password.clickhouse_readonly_user[0].result
  ) : null
}

ephemeral "random_password" "clickhouse_otel" {
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_monte_carlo" {
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_schema_owner" {
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_llm_worker" {
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_admin" {
  count   = local.clickhouse_admin_enabled ? 1 : 0
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_readonly_user" {
  count   = local.clickhouse_readonly_user_enabled ? 1 : 0
  length  = 32
  special = false
}

# KMS — customer-managed key for all Secrets Manager secrets.

resource "aws_kms_key" "pipeline_secrets" {
  description             = "${local.effective_cluster_name} pipeline secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "pipeline_secrets" {
  name          = "alias/${local.effective_cluster_name}-pipeline-secrets"
  target_key_id = aws_kms_key.pipeline_secrets.key_id
}

# Secrets Manager — ClickHouse passwords (otel, monte_carlo, schema_owner,
# llm_worker users always provisioned; admin and readonly_user conditional on
# their respective enabled flags).

# admin and admin_password versions were unconditional before the gated
# break-glass admin user existed. The moved blocks let enabling admin adopt the
# existing secret in place rather than destroy/recreate it.
moved {
  from = aws_secretsmanager_secret.clickhouse_admin_password
  to   = aws_secretsmanager_secret.clickhouse_admin_password[0]
}

moved {
  from = aws_secretsmanager_secret_version.clickhouse_admin_password
  to   = aws_secretsmanager_secret_version.clickhouse_admin_password[0]
}

resource "aws_secretsmanager_secret" "clickhouse_admin_password" {
  count                   = local.clickhouse_admin_enabled ? 1 : 0
  name                    = "${local.effective_cluster_name}/clickhouse/admin-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # Allow immediate deletion so destroy + re-apply with the same cluster name doesn't fail during the default 30-day recovery window.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_admin_password" {
  count                    = local.clickhouse_admin_enabled ? 1 : 0
  secret_id                = aws_secretsmanager_secret.clickhouse_admin_password[0].id
  secret_string_wo         = local.clickhouse_admin_password
  secret_string_wo_version = var.clickhouse_password_versions.admin
}

resource "aws_secretsmanager_secret" "clickhouse_otel_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/otel-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_otel_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_otel_password.id
  secret_string_wo         = local.clickhouse_otel_password
  secret_string_wo_version = var.clickhouse_password_versions.otel
}

resource "aws_secretsmanager_secret" "clickhouse_monte_carlo_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/monte-carlo-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_monte_carlo_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_monte_carlo_password.id
  secret_string_wo         = local.clickhouse_monte_carlo_password
  secret_string_wo_version = var.clickhouse_password_versions.monte_carlo
}

resource "aws_secretsmanager_secret" "clickhouse_schema_owner_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/schema-owner-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_schema_owner_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_schema_owner_password.id
  secret_string_wo         = local.clickhouse_schema_owner_password
  secret_string_wo_version = var.clickhouse_password_versions.schema_owner
}

resource "aws_secretsmanager_secret" "clickhouse_llm_worker_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/llm-worker-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_llm_worker_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_llm_worker_password.id
  secret_string_wo         = local.clickhouse_llm_worker_password
  secret_string_wo_version = var.clickhouse_password_versions.llm_worker
}

resource "aws_secretsmanager_secret" "clickhouse_readonly_user_password" {
  count                   = local.clickhouse_readonly_user_enabled ? 1 : 0
  name                    = "${local.effective_cluster_name}/clickhouse/readonly-user-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_readonly_user_password" {
  count                    = local.clickhouse_readonly_user_enabled ? 1 : 0
  secret_id                = aws_secretsmanager_secret.clickhouse_readonly_user_password[0].id
  secret_string_wo         = local.clickhouse_readonly_user_password
  secret_string_wo_version = var.clickhouse_password_versions.readonly_user
}
