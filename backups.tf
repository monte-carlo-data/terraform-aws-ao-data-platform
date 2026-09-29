# Backup storage is separate from the short-lived trace-export ingest bucket.
# This prepares storage and credentials; installing the backup software and
# creating its ClickHouse user are separate steps.

locals {
  clickhouse_backup_enabled = var.clickhouse_backup != null
}

resource "aws_s3_bucket" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  bucket        = var.clickhouse_backup.bucket_name
  force_destroy = false
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.clickhouse_backup[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  bucket = aws_s3_bucket.clickhouse_backup[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Keep backup-file encryption separate from the key used for stored passwords.
# AWS's default key policy allows this account to grant access through IAM.
resource "aws_kms_key" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  description             = "${local.effective_cluster_name} ClickHouse backup files"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  name          = "alias/${local.effective_cluster_name}-clickhouse-backup"
  target_key_id = aws_kms_key.clickhouse_backup[0].key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  bucket = aws_s3_bucket.clickhouse_backup[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.clickhouse_backup[0].arn
    }
  }
}

resource "aws_s3_bucket_policy" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  bucket = aws_s3_bucket.clickhouse_backup[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.clickhouse_backup[0].arn,
        "${aws_s3_bucket.clickhouse_backup[0].arn}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.clickhouse_backup]
}

# No S3 expiry rules: the backup software owns retention, including any
# dependencies between full and incremental backups.

resource "aws_iam_role" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  # IAM adds a unique suffix; keep the prefix within its 38-character limit.
  name_prefix = "${substr(local.region_qualified_name, 0, 24)}-backup-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:${kubernetes_namespace_v1.montecarlo.metadata[0].name}:${var.clickhouse_backup.service_account_name}"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  name = "clickhouse-backup-storage"
  role = aws_iam_role.clickhouse_backup[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BackupBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.clickhouse_backup[0].arn
      },
      {
        Sid    = "BackupFiles"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
        ]
        Resource = "${aws_s3_bucket.clickhouse_backup[0].arn}/*"
      },
      {
        Sid      = "BackupEncryptionKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.clickhouse_backup[0].arn
      },
    ]
  })
}

resource "random_password" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  name       = "${local.effective_cluster_name}/clickhouse/backup-credentials"
  kms_key_id = aws_kms_key.pipeline_secrets.arn
  # Match the other ClickHouse secrets so destroy/recreate can reuse the name.
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0

  secret_id     = aws_secretsmanager_secret.clickhouse_backup[0].id
  secret_string = random_password.clickhouse_backup[0].result
}
