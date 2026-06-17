# ClickHouse Passwords — generated when not caller-supplied; stored in Secrets
# Manager and synced into the cluster by ESO (never passed through Helm values).
# count cannot derive from a sensitive value, so the null-checks are unwrapped
# with nonsensitive() — this declassifies only whether a password was supplied,
# never the password itself.

resource "random_password" "clickhouse_admin" {
  count   = nonsensitive(var.clickhouse_passwords.admin == null) ? 1 : 0
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

# Secrets Manager — ClickHouse passwords (admin, otel user, monte_carlo user).

resource "aws_secretsmanager_secret" "clickhouse_admin_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/admin-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # Allow immediate deletion so destroy + re-apply with the same cluster name doesn't fail during the default 30-day recovery window.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_admin_password" {
  secret_id     = aws_secretsmanager_secret.clickhouse_admin_password.id
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
