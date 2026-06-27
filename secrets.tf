# ClickHouse Passwords — generated when not caller-supplied; stored in Secrets
# Manager and synced into the cluster by ESO (never passed through Helm values).
# count cannot derive from a sensitive value, so the null-checks are unwrapped
# with nonsensitive() — this declassifies only whether a password was supplied,
# never the password itself.

resource "random_password" "clickhouse_admin" {
  count   = local.clickhouse_admin_enabled && nonsensitive(var.clickhouse_passwords.admin == null) ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "clickhouse_otel" {
  count   = nonsensitive(var.clickhouse_passwords.otel == null) ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "clickhouse_monte_carlo" {
  count   = nonsensitive(var.clickhouse_passwords.monte_carlo == null) ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "clickhouse_schema_owner" {
  count   = nonsensitive(var.clickhouse_passwords.schema_owner == null) ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "clickhouse_llm_worker" {
  count   = nonsensitive(var.clickhouse_passwords.llm_worker == null) ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "clickhouse_readonly_user" {
  count   = local.clickhouse_readonly_user_enabled && nonsensitive(var.clickhouse_passwords.readonly_user == null) ? 1 : 0
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
  count         = local.clickhouse_admin_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.clickhouse_admin_password[0].id
  secret_string = local.clickhouse_admin_password
}

resource "aws_secretsmanager_secret" "clickhouse_otel_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/otel-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_otel_password" {
  secret_id     = aws_secretsmanager_secret.clickhouse_otel_password.id
  secret_string = local.clickhouse_otel_password
}

resource "aws_secretsmanager_secret" "clickhouse_monte_carlo_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/monte-carlo-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_monte_carlo_password" {
  secret_id     = aws_secretsmanager_secret.clickhouse_monte_carlo_password.id
  secret_string = local.clickhouse_monte_carlo_password
}

resource "aws_secretsmanager_secret" "clickhouse_schema_owner_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/schema-owner-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_schema_owner_password" {
  secret_id     = aws_secretsmanager_secret.clickhouse_schema_owner_password.id
  secret_string = local.clickhouse_schema_owner_password
}

resource "aws_secretsmanager_secret" "clickhouse_llm_worker_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/llm-worker-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_llm_worker_password" {
  secret_id     = aws_secretsmanager_secret.clickhouse_llm_worker_password.id
  secret_string = local.clickhouse_llm_worker_password
}

resource "aws_secretsmanager_secret" "clickhouse_readonly_user_password" {
  count                   = local.clickhouse_readonly_user_enabled ? 1 : 0
  name                    = "${local.effective_cluster_name}/clickhouse/readonly-user-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_readonly_user_password" {
  count         = local.clickhouse_readonly_user_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.clickhouse_readonly_user_password[0].id
  secret_string = local.clickhouse_readonly_user_password
}
