# Plan-only tests: every provider is mocked, so these cannot access AWS or a
# Kubernetes cluster. Only computed IDs/passwords are supplied by the mocks;
# the policies and resource settings under test come from the real module.

mock_provider "aws" {
  override_during = plan

  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }

  override_data {
    target = data.aws_eks_cluster.existing[0]
    values = {
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/TESTOIDC" }] }]
      certificate_authority = [{ data = "dGVzdC1jYQ==" }]
    }
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws", dns_suffix = "amazonaws.com" }
  }

  override_resource {
    target = aws_iam_openid_connect_provider.cluster[0]
    values = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/TESTOIDC" }
  }

  override_resource {
    target = aws_s3_bucket.clickhouse_backup[0]
    values = {
      id  = "test-clickhouse-backups"
      arn = "arn:aws:s3:::test-clickhouse-backups"
    }
  }

  override_resource {
    target = aws_iam_role.clickhouse_backup[0]
    values = { arn = "arn:aws:iam::123456789012:role/test-cluster-us-east-1-clickhouse-backup" }
  }

  override_resource {
    target = aws_kms_key.pipeline_secrets
    values = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_backup[0]
    values = {
      id  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/backup-credentials-ABCDEF"
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/backup-credentials-ABCDEF"
    }
  }
}

mock_provider "tls" {
  override_data {
    target = data.tls_certificate.cluster[0]
    values = { certificates = [{ sha1_fingerprint = "0123456789abcdef0123456789abcdef01234567" }] }
  }
}

mock_provider "random" {
  override_during = plan

  override_resource {
    target = random_password.clickhouse_backup[0]
    values = { result = "00000000000000000000000000000000" }
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "null" {}

variables {
  region = "us-east-1"

  cluster = {
    create                = false
    existing_cluster_name = "test-cluster"
  }

  networking = {
    create_vpc                  = false
    existing_vpc_id             = "vpc-12345678"
    existing_private_subnet_ids = ["subnet-aaaa1111", "subnet-bbbb2222"]
  }

  helm = { deploy_charts = false }
}

run "backup_disabled_by_default" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_s3_bucket.clickhouse_backup) == 0,
      length(aws_s3_bucket_public_access_block.clickhouse_backup) == 0,
      length(aws_s3_bucket_ownership_controls.clickhouse_backup) == 0,
      length(aws_s3_bucket_server_side_encryption_configuration.clickhouse_backup) == 0,
      length(aws_s3_bucket_policy.clickhouse_backup) == 0,
      length(aws_iam_role.clickhouse_backup) == 0,
      length(aws_iam_role_policy.clickhouse_backup) == 0,
      length(random_password.clickhouse_backup) == 0,
      length(aws_secretsmanager_secret.clickhouse_backup) == 0,
      length(aws_secretsmanager_secret_version.clickhouse_backup) == 0,
    ])
    error_message = "Existing callers must not receive backup storage, access, or credentials unless they enable backups."
  }

  assert {
    condition     = output.clickhouse_backup == null
    error_message = "The backup output must be null when the feature is disabled."
  }
}

run "backup_storage_is_private_and_not_force_deleted" {
  command = plan

  variables {
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
  }

  assert {
    condition = (
      aws_s3_bucket.clickhouse_backup[0].bucket == "test-clickhouse-backups" &&
      aws_s3_bucket.clickhouse_backup[0].force_destroy == false
    )
    error_message = "Use the caller's backup bucket name and refuse to delete a bucket that still contains backups."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.clickhouse_backup[0].block_public_acls &&
      aws_s3_bucket_public_access_block.clickhouse_backup[0].block_public_policy &&
      aws_s3_bucket_public_access_block.clickhouse_backup[0].ignore_public_acls &&
      aws_s3_bucket_public_access_block.clickhouse_backup[0].restrict_public_buckets &&
      one(aws_s3_bucket_ownership_controls.clickhouse_backup[0].rule).object_ownership == "BucketOwnerEnforced"
    )
    error_message = "Backup storage must block every form of public access and disable object ACLs."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.clickhouse_backup[0].rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Backup objects must use S3-managed encryption by default."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_s3_bucket_policy.clickhouse_backup[0].policy).Statement :
      statement.Effect == "Deny" &&
      statement.Principal == "*" &&
      toset(flatten([statement.Action])) == toset(["s3:*"]) &&
      toset(flatten([statement.Resource])) == toset(["arn:aws:s3:::test-clickhouse-backups", "arn:aws:s3:::test-clickhouse-backups/*"]) &&
      try(tostring(statement.Condition.Bool["aws:SecureTransport"]) == "false", false)
    ])
    error_message = "The bucket policy must reject unencrypted connections for everyone, covering both the bucket and its objects."
  }
}

run "backup_role_trusts_only_the_selected_service_account" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "test-clickhouse-backups"
      service_account_name = "backup-jobs"
    }
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role.clickhouse_backup[0].assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.clickhouse_backup[0].assume_role_policy).Statement[0].Effect == "Allow" &&
      toset(flatten([jsondecode(aws_iam_role.clickhouse_backup[0].assume_role_policy).Statement[0].Action])) == toset(["sts:AssumeRoleWithWebIdentity"]) &&
      jsondecode(aws_iam_role.clickhouse_backup[0].assume_role_policy).Statement[0].Principal == {
        Federated = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/TESTOIDC"
      } &&
      jsondecode(aws_iam_role.clickhouse_backup[0].assume_role_policy).Statement[0].Condition == {
        StringEquals = {
          "oidc.eks.us-east-1.amazonaws.com/id/TESTOIDC:sub" = "system:serviceaccount:montecarlo:backup-jobs"
          "oidc.eks.us-east-1.amazonaws.com/id/TESTOIDC:aud" = "sts.amazonaws.com"
        }
      }
    )
    error_message = "Only the selected service account in montecarlo, from this cluster's identity provider and with the AWS audience, may assume the backup role."
  }

  assert {
    condition     = output.clickhouse_backup.service_account_name == "backup-jobs" && output.clickhouse_backup.namespace == "montecarlo"
    error_message = "The output must name the same service account and namespace permitted by the role."
  }
}

run "backup_role_can_only_read_and_write_its_backup_bucket" {
  command = plan

  variables {
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement) == 2 &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement : statement.Effect == "Allow"])
    )
    error_message = "The backup role must contain only its two S3 grants, without additional secret, key, or account-wide permissions."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement :
      toset(flatten([statement.Action])) == toset(["s3:ListBucket", "s3:GetBucketLocation"]) &&
      toset(flatten([statement.Resource])) == toset(["arn:aws:s3:::test-clickhouse-backups"])
    ])
    error_message = "Bucket-listing permissions must be limited to this backup bucket."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement :
      toset(flatten([statement.Action])) == toset(["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]) &&
      toset(flatten([statement.Resource])) == toset(["arn:aws:s3:::test-clickhouse-backups/*"])
    ])
    error_message = "Object permissions must permit backup and restore operations only within this backup bucket."
  }
}

run "backup_password_is_generated_and_stored_in_the_existing_key" {
  command = plan

  variables {
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
  }

  assert {
    condition = (
      random_password.clickhouse_backup[0].length == 32 &&
      aws_secretsmanager_secret.clickhouse_backup[0].kms_key_id == aws_kms_key.pipeline_secrets.arn &&
      aws_secretsmanager_secret.clickhouse_backup[0].recovery_window_in_days == 0 &&
      aws_secretsmanager_secret_version.clickhouse_backup[0].secret_id == aws_secretsmanager_secret.clickhouse_backup[0].id &&
      nonsensitive(aws_secretsmanager_secret_version.clickhouse_backup[0].secret_string) == "00000000000000000000000000000000"
    )
    error_message = "Store this backup user's generated 32-character password as the raw secret value, encrypted by the existing secrets key."
  }

  assert {
    condition = output.clickhouse_backup == {
      bucket_name          = "test-clickhouse-backups"
      bucket_arn           = "arn:aws:s3:::test-clickhouse-backups"
      iam_role_arn         = "arn:aws:iam::123456789012:role/test-cluster-us-east-1-clickhouse-backup"
      service_account_name = "clickhouse-backup"
      namespace            = "montecarlo"
      password_secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/backup-credentials-ABCDEF"
      username             = "backup"
    }
    error_message = "Expose the storage and identity references needed for the backup job, without exposing its password."
  }
}
