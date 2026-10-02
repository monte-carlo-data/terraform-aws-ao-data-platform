# Plan-only tests: every provider is mocked, so these cannot access AWS or a
# Kubernetes cluster. The mocks supply computed IDs/passwords and data lookups
# such as account identity, availability zones, and cluster certificates. The
# policies and resource settings under test come from the real module.

mock_provider "aws" {
  override_during = plan

  override_resource {
    target = aws_acm_certificate.clickhouse[0]
    values = { arn = "arn:aws:acm:us-east-1:123456789012:certificate/clickhouse" }
  }

  override_resource {
    target = aws_acm_certificate.otel_collector[0]
    values = { arn = "arn:aws:acm:us-east-1:123456789012:certificate/otel" }
  }

  override_resource {
    target = aws_iam_role.otel_collector
    values = { arn = "arn:aws:iam::123456789012:role/otel" }
  }

  override_resource {
    target = aws_iam_role.llm_worker
    values = { arn = "arn:aws:iam::123456789012:role/worker" }
  }

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
    target = data.aws_caller_identity.clickhouse_backup[0]
    values = { account_id = "123456789012" }
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
    target = aws_kms_key.clickhouse_backup[0]
    values = {
      key_id = "11111111-1111-1111-1111-111111111111"
      arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
    }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_backup[0]
    values = {
      id  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/backup-credentials-ABCDEF"
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/backup-credentials-ABCDEF"
    }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_backup_probe[0]
    values = {
      id  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/backup-probe-credentials-ABCDEF"
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/backup-probe-credentials-ABCDEF"
    }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_otel_password
    values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/otel-credentials-ABCDEF" }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_monte_carlo_password
    values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/monte-carlo-credentials-ABCDEF" }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_schema_owner_password
    values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/schema-owner-credentials-ABCDEF" }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_llm_worker_password
    values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/llm-worker-credentials-ABCDEF" }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_admin_password[0]
    values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/admin-credentials-ABCDEF" }
  }

  override_resource {
    target = aws_secretsmanager_secret.clickhouse_readonly_user_password[0]
    values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster/clickhouse/readonly-user-credentials-ABCDEF" }
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

  override_resource {
    target = random_password.clickhouse_backup_probe[0]
    values = { result = "22222222222222222222222222222222" }
  }

  override_resource {
    target = random_password.clickhouse_backup_api[0]
    values = { result = "11111111111111111111111111111111" }
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
      length(data.aws_caller_identity.clickhouse_backup) == 0,
      length(aws_s3_bucket.clickhouse_backup) == 0,
      length(aws_s3_bucket_public_access_block.clickhouse_backup) == 0,
      length(aws_s3_bucket_ownership_controls.clickhouse_backup) == 0,
      length(aws_s3_bucket_server_side_encryption_configuration.clickhouse_backup) == 0,
      length(aws_s3_bucket_policy.clickhouse_backup) == 0,
      length(aws_kms_key.clickhouse_backup) == 0,
      length(aws_kms_alias.clickhouse_backup) == 0,
      length(aws_iam_role.clickhouse_backup) == 0,
      length(aws_iam_role_policy.clickhouse_backup) == 0,
      length(random_password.clickhouse_backup) == 0,
      length(aws_secretsmanager_secret.clickhouse_backup) == 0,
      length(aws_secretsmanager_secret_version.clickhouse_backup) == 0,
      length(random_password.clickhouse_backup_api) == 0,
      length(kubernetes_secret_v1.clickhouse_backup_api) == 0,
      length(random_password.clickhouse_backup_probe) == 0,
      length(aws_secretsmanager_secret.clickhouse_backup_probe) == 0,
      length(aws_secretsmanager_secret_version.clickhouse_backup_probe) == 0,
      length(keys(local.helm_clickhouse_backup_block)) == 0,
    ])
    error_message = "Existing callers must not receive backup storage, encryption keys, access, or credentials unless they enable backups."
  }

  assert {
    condition     = output.clickhouse_backup == null && output.clickhouse_backup_credentials_secret_arn == null
    error_message = "Both backup outputs must be null when the feature is disabled."
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement) == 2 &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement : statement.Effect == "Allow"]) &&
      anytrue([
        for statement in jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement :
        toset(flatten([statement.Action])) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]) &&
        toset(flatten([statement.Resource])) == toset([
          aws_secretsmanager_secret.clickhouse_otel_password.arn,
          aws_secretsmanager_secret.clickhouse_monte_carlo_password.arn,
          aws_secretsmanager_secret.clickhouse_schema_owner_password.arn,
          aws_secretsmanager_secret.clickhouse_llm_worker_password.arn,
        ])
      ]) &&
      anytrue([
        for statement in jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement :
        toset(flatten([statement.Action])) == toset(["kms:Decrypt"]) &&
        toset(flatten([statement.Resource])) == toset([aws_kms_key.pipeline_secrets.arn])
      ])
    )
    error_message = "With backups disabled, External Secrets must retain only its original four password reads and its existing secrets-key decrypt permission."
  }
}

run "backup_storage_is_private_and_not_force_deleted" {
  command = plan

  variables {
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
  }

  assert {
    condition = (
      length(random_password.clickhouse_backup_api) == 0 &&
      length(kubernetes_secret_v1.clickhouse_backup_api) == 0 &&
      length(keys(local.helm_clickhouse_backup_block)) == 0
    )
    error_message = "Existing storage-only callers must not install backups or create API credentials."
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
    condition = (
      one(aws_s3_bucket_server_side_encryption_configuration.clickhouse_backup[0].rule).bucket_key_enabled &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.clickhouse_backup[0].rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms" &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.clickhouse_backup[0].rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.clickhouse_backup[0].arn &&
      aws_kms_key.clickhouse_backup[0].arn != aws_kms_key.pipeline_secrets.arn
    )
    error_message = "Backup files must use their own KMS key by default, separate from the passwords key, with S3 Bucket Keys enabled."
  }

  assert {
    condition = (
      length(aws_kms_key.clickhouse_backup) == 1 &&
      length(aws_kms_alias.clickhouse_backup) == 1 &&
      aws_kms_key.clickhouse_backup[0].enable_key_rotation &&
      aws_kms_key.clickhouse_backup[0].deletion_window_in_days == 30 &&
      aws_kms_alias.clickhouse_backup[0].name == "alias/test-cluster-clickhouse-backup" &&
      aws_kms_alias.clickhouse_backup[0].target_key_id == aws_kms_key.clickhouse_backup[0].key_id
    )
    error_message = "Enabling backups must create one named KMS key with automatic rotation and a 30-day deletion waiting period."
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

run "backup_bucket_rejects_explicit_encryption_overrides" {
  command = plan

  variables {
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
  }

  assert {
    condition = (
      length(jsondecode(aws_s3_bucket_policy.clickhouse_backup[0].policy).Statement) == 5 &&
      toset([for statement in jsondecode(aws_s3_bucket_policy.clickhouse_backup[0].policy).Statement : statement.Sid]) == toset([
        "DenyInsecureTransport", "DenyNonKmsEncryption", "DenyOtherKmsKeys",
        "DenyKmsWithoutKeyId", "DenyCustomerProvidedEncryptionKeys",
      ]) &&
      alltrue([
        for statement in jsondecode(aws_s3_bucket_policy.clickhouse_backup[0].policy).Statement :
        statement.Effect == "Deny" && statement.Principal == "*" &&
        toset(flatten([statement.Action])) == toset(["s3:PutObject"]) &&
        toset(flatten([statement.Resource])) == toset(["arn:aws:s3:::test-clickhouse-backups/*"])
        if statement.Sid != "DenyInsecureTransport"
      ])
    )
    error_message = "The bucket policy must contain the existing TLS denial and exactly four encryption denials covering every uploader and every backup object."
  }

  # Check the actual AWS condition structure, without inventing a second policy
  # evaluator. See the policy comment in s3.tf for why the Null guards are needed.
  assert {
    condition = jsonencode({
      for statement in jsondecode(aws_s3_bucket_policy.clickhouse_backup[0].policy).Statement :
      statement.Sid => statement.Condition if statement.Sid != "DenyInsecureTransport"
      }) == jsonencode({
      DenyNonKmsEncryption = {
        Null            = { "s3:x-amz-server-side-encryption" = "false" }
        StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
      }
      DenyOtherKmsKeys = {
        Null            = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "false" }
        StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.clickhouse_backup[0].arn }
      }
      DenyKmsWithoutKeyId = {
        StringEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
        Null         = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "true" }
      }
      DenyCustomerProvidedEncryptionKeys = {
        Null = { "s3:x-amz-server-side-encryption-customer-algorithm" = "false" }
      }
    })
    error_message = "Allow headerless default-KMS uploads; reject explicit wrong algorithms, different keys, KMS without a key ID, and customer-provided encryption keys."
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
    condition     = aws_iam_role.clickhouse_backup[0].name == "test-cluster-us-east-1-clickhouse-backup"
    error_message = "The backup role name must contain the cluster and region without a generated suffix."
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

run "backup_role_name_preserves_the_full_cluster_and_region" {
  command = plan

  variables {
    region = "us-west-1"
    cluster = {
      create                = false
      existing_cluster_name = "test-cluster-long-name"
    }
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
  }

  assert {
    condition     = aws_iam_role.clickhouse_backup[0].name == "test-cluster-long-name-us-west-1-clickhouse-backup"
    error_message = "A longer cluster name must not truncate the region from the backup role name."
  }
}

run "backup_role_can_only_use_its_backup_bucket_and_key" {
  command = plan

  variables {
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement) == 3 &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement : statement.Effect == "Allow"])
    )
    error_message = "The backup role must contain only its two S3 grants and one backup-key grant, without secret or account-wide permissions."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement :
      toset(flatten([statement.Action])) == toset(["s3:ListBucket", "s3:GetBucketLocation"]) &&
      toset(flatten([statement.Resource])) == toset(["arn:aws:s3:::test-clickhouse-backups"]) &&
      try(statement.Condition.StringEquals["s3:ResourceAccount"] == "123456789012", false)
    ])
    error_message = "Bucket-listing permissions must be limited to this backup bucket owned by the current AWS account."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement :
      toset(flatten([statement.Action])) == toset(["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]) &&
      toset(flatten([statement.Resource])) == toset(["arn:aws:s3:::test-clickhouse-backups/*"]) &&
      try(statement.Condition.StringEquals["s3:ResourceAccount"] == "123456789012", false)
    ])
    error_message = "Object permissions must permit backup and restore operations only within this backup bucket owned by the current AWS account."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement :
      statement.Sid == "BackupEncryptionKey" &&
      toset(flatten([statement.Action])) == toset(["kms:GenerateDataKey", "kms:Decrypt"]) &&
      toset(flatten([statement.Resource])) == toset([aws_kms_key.clickhouse_backup[0].arn])
    ])
    error_message = "Key permissions must allow only generating data keys and decrypting with the dedicated backup key."
  }

  assert {
    condition = length(setintersection(
      toset(flatten([for statement in jsondecode(aws_iam_role_policy.clickhouse_backup[0].policy).Statement : statement.Action])),
      toset([
        "s3:GetBucketVersioning", "s3:PutBucketVersioning", "s3:ListBucketVersions",
        "s3:GetObjectVersion", "s3:DeleteObjectVersion",
        "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration",
      ]),
    )) == 0
    error_message = "The backup software must not inspect or change bucket versioning/lifecycle settings, or read or delete previous object versions."
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

  assert {
    condition     = output.clickhouse_backup_credentials_secret_arn == output.clickhouse_backup.password_secret_arn
    error_message = "The flat credentials output must reference the same secret as the unchanged backup output object."
  }
}

run "external_secrets_reads_backup_password_without_expanding_other_access" {
  command = plan

  variables {
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
    helm = {
      deploy_charts = false
      clickhouse = {
        admin         = { enabled = true }
        readonly_user = { enabled = true }
      }
    }
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement) == 2 &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement : statement.Effect == "Allow"])
    )
    error_message = "External Secrets must keep exactly its password-read grant and existing secrets-key grant, with no additional grants."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement :
      toset(flatten([statement.Action])) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]) &&
      toset(flatten([statement.Resource])) == toset([
        aws_secretsmanager_secret.clickhouse_otel_password.arn,
        aws_secretsmanager_secret.clickhouse_monte_carlo_password.arn,
        aws_secretsmanager_secret.clickhouse_schema_owner_password.arn,
        aws_secretsmanager_secret.clickhouse_llm_worker_password.arn,
        aws_secretsmanager_secret.clickhouse_admin_password[0].arn,
        aws_secretsmanager_secret.clickhouse_readonly_user_password[0].arn,
        aws_secretsmanager_secret.clickhouse_backup[0].arn,
      ])
    ])
    error_message = "External Secrets must read the backup password alongside all existing passwords, including optional users, without write access or access to unrelated secrets."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement :
      toset(flatten([statement.Action])) == toset(["kms:Decrypt"]) &&
      toset(flatten([statement.Resource])) == toset([aws_kms_key.pipeline_secrets.arn])
    ])
    error_message = "External Secrets must still decrypt with only the passwords' existing KMS key, without receiving access to the backup-files key."
  }
}

run "backup_storage_supports_an_externally_managed_secrets_operator" {
  command = plan

  variables {
    clickhouse_backup = { bucket_name = "test-clickhouse-backups" }
    helm = {
      deploy_charts                     = false
      install_external_secrets_operator = false
    }
  }

  assert {
    condition = (
      length(aws_iam_role.external_secrets) == 0 &&
      length(aws_iam_role_policy.external_secrets) == 0 &&
      length(aws_secretsmanager_secret.clickhouse_backup) == 1 &&
      length(aws_iam_role.clickhouse_backup) == 1
    )
    error_message = "Backup storage and its password must still be available when the caller manages External Secrets separately, without creating an operator role or policy."
  }
}

# Input validation must also protect callers that create storage without Helm.
# Every rejected case inherits helm.deploy_charts = false from this file.

run "backup_rejects_uppercase_bucket" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "Test-clickhouse-backups"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_64_character_bucket" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "backup-${join("", [for _ in range(57) : "a"])}"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_2_character_bucket" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "ab"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_reserved_bucket_prefix_xn" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "xn--backup-test"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_reserved_bucket_prefix_sthree" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "sthree-backup-test"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_reserved_bucket_prefix_demo" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "amzn-s3-demo-backup-test"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_reserved_bucket_suffix_alias" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "backup-test-s3alias"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_reserved_bucket_suffix_object_lambda" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "backup-test--ol-s3"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_reserved_bucket_suffix_directory" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "backup-test--x-s3"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_reserved_bucket_suffix_table" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name = "backup-test--table-s3"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_invalid_service_account" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "test-clickhouse-backups"
      service_account_name = "backup_jobs"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_64_character_service_account" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "test-clickhouse-backups"
      service_account_name = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_default_service_account" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "test-clickhouse-backups"
      service_account_name = "default"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_collector_service_account" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "test-clickhouse-backups"
      service_account_name = "opentelemetry-collector"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_worker_service_account" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "test-clickhouse-backups"
      service_account_name = "llm-worker"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_scheduler_service_account" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "test-clickhouse-backups"
      service_account_name = "otel-backup-job"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_rejects_monitor_service_account" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "test-clickhouse-backups"
      service_account_name = "clickhouse-backup-monitor"
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "backup_accepts_63_character_names_without_helm" {
  command = plan

  variables {
    clickhouse_backup = {
      bucket_name          = "backup-${join("", [for _ in range(56) : "a"])}"
      service_account_name = "backup-${join("", [for _ in range(56) : "a"])}"
    }
  }

  assert {
    condition = (
      var.helm.deploy_charts == false &&
      length(var.clickhouse_backup.bucket_name) == 63 &&
      length(var.clickhouse_backup.service_account_name) == 63 &&
      aws_s3_bucket.clickhouse_backup[0].bucket == var.clickhouse_backup.bucket_name &&
      output.clickhouse_backup.service_account_name == var.clickhouse_backup.service_account_name &&
      jsondecode(aws_iam_role.clickhouse_backup[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-east-1.amazonaws.com/id/TESTOIDC:sub"] == "system:serviceaccount:montecarlo:${var.clickhouse_backup.service_account_name}"
    )
    error_message = "Valid bucket and dedicated service-account names at the 63-character limit must work when only storage is requested."
  }
}

run "scheduled_backups_use_existing_storage_and_a_separate_api_password" {
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups", service_account_name = "custom-backup" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  assert {
    condition = (
      length(random_password.clickhouse_backup_api) == 1 &&
      length(kubernetes_secret_v1.clickhouse_backup_api) == 1 &&
      random_password.clickhouse_backup_api[0].length == 32 &&
      random_password.clickhouse_backup_api[0].special == false &&
      random_password.clickhouse_backup_api[0].keepers == null &&
      kubernetes_secret_v1.clickhouse_backup_api[0].metadata[0].name == "ao-clickhouse-backup-api" &&
      kubernetes_secret_v1.clickhouse_backup_api[0].metadata[0].namespace == "montecarlo" &&
      kubernetes_secret_v1.clickhouse_backup_api[0].type == "Opaque" &&
      nonsensitive(kubernetes_secret_v1.clickhouse_backup_api[0].data.password) == "11111111111111111111111111111111" &&
      nonsensitive(kubernetes_secret_v1.clickhouse_backup_api[0].data.password) != nonsensitive(aws_secretsmanager_secret_version.clickhouse_backup[0].secret_string)
    )
    error_message = "Installing backups must create one separate, stable 32-character API password in the existing namespace, with no rotation triggers."
  }

  assert {
    condition     = issensitive(kubernetes_secret_v1.clickhouse_backup_api[0].data)
    error_message = "Terraform must keep the Kubernetes password value sensitive."
  }

  assert {
    condition = jsonencode(yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup) == jsonencode({
      enabled  = true
      provider = "aws"
      aws = {
        bucket  = "test-clickhouse-backups"
        region  = "us-east-1"
        roleArn = "arn:aws:iam::123456789012:role/test-cluster-us-east-1-clickhouse-backup"
        path    = "clickhouse"
      }
      serviceAccount = { name = "custom-backup" }
      user = {
        externalSecret = {
          secretStoreRef = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
          remoteRef      = { key = "test-cluster/clickhouse/backup-credentials" }
        }
      }
      sidecar = { image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" }
      probe = {
        externalSecret = {
          secretStoreRef = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
          remoteRef      = { key = "test-cluster/clickhouse/backup-probe-credentials" }
        }
      }
      api      = { existingSecret = "ao-clickhouse-backup-api", passwordRevision = "1" }
      schedule = { suspend = false }
    })
    error_message = "The chart must use the existing bucket, role, stored database password and trusted service account; only the separate API secret's name belongs in values."
  }

  assert {
    condition = (
      !strcontains(helm_release.ao_data_platform[0].values[0], "11111111111111111111111111111111") &&
      !strcontains(helm_release.ao_data_platform[0].values[0], "00000000000000000000000000000000") &&
      !strcontains(helm_release.ao_data_platform[0].values[0], "22222222222222222222222222222222") &&
      !issensitive(helm_release.ao_data_platform[0].values[0])
    )
    error_message = "Neither password value may enter the Helm release values."
  }

  assert {
    condition = (
      helm_release.ao_data_platform[0].chart == "oci://registry-1.docker.io/montecarlodata/ao-data-platform" &&
      helm_release.ao_data_platform[0].version == "5.2.0" &&
      length(aws_s3_bucket.clickhouse_backup) == 1 &&
      length(aws_iam_role.clickhouse_backup) == 1 &&
      length(aws_secretsmanager_secret.clickhouse_backup) == 1 &&
      jsondecode(aws_iam_role.clickhouse_backup[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-east-1.amazonaws.com/id/TESTOIDC:sub"] == "system:serviceaccount:montecarlo:custom-backup"
    )
    error_message = "Published chart selection and the existing AWS storage resources must remain in use."
  }
}

run "storage_with_chart_installation_stays_off_without_backup_opt_in" {
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.1.0"
    }
  }

  assert {
    condition = (
      !can(yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup) &&
      length(random_password.clickhouse_backup_api) == 0 &&
      length(kubernetes_secret_v1.clickhouse_backup_api) == 0
    )
    error_message = "Current applied callers must receive no backup chart values or API resources until they opt in."
  }
}

run "scheduled_backups_can_be_installed_with_the_schedule_paused" {
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4", suspend = true } }
    }
  }

  assert {
    condition = (
      yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.schedule.suspend &&
      length(kubernetes_secret_v1.clickhouse_backup_api) == 1
    )
    error_message = "Pausing jobs must preserve the installed setup and API password."
  }
}

run "scheduled_backups_require_existing_storage" {
  # Domains, chart version, and replica settings satisfy the other Helm checks.
  command = plan

  variables {
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [helm_release.ao_data_platform]
}

run "scheduled_backups_reject_the_default_service_account" {
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups", service_account_name = "default" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [var.clickhouse_backup]
}

run "scheduled_backups_require_chart_deployment" {
  command = plan

  variables {
    helm = {
      deploy_charts = false
      clickhouse    = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [var.helm]
}

run "scheduled_backups_reject_published_charts_without_backup_support" {
  # Storage, domains, and replica settings satisfy the other Helm checks.
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.1.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [helm_release.ao_data_platform]
}

run "scheduled_backups_accept_next_major_chart_version" {
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "6.0.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  assert {
    condition = (
      local.chart_version_parts[0] == 6 && local.chart_version_parts[1] == 0 &&
      helm_release.ao_data_platform[0].version == "6.0.0" &&
      yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.enabled
    )
    error_message = "Compare numeric major/minor parts while passing the caller's valid chart version through unchanged."
  }
}

run "scheduled_backups_accept_double_digit_minor_chart_version" {
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.10.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  assert {
    condition = (
      local.chart_version_parts[0] == 5 && local.chart_version_parts[1] == 10 &&
      helm_release.ao_data_platform[0].version == "5.10.0" &&
      yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.enabled
    )
    error_message = "Compare numeric major/minor parts while passing the caller's valid chart version through unchanged."
  }
}

run "scheduled_backups_accept_v_prefix_chart_version" {
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "v5.2.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  assert {
    condition = (
      local.chart_version_parts[0] == 5 && local.chart_version_parts[1] == 2 &&
      helm_release.ao_data_platform[0].version == "v5.2.0" &&
      yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.enabled
    )
    error_message = "Compare numeric major/minor parts while passing the caller's valid chart version through unchanged."
  }
}

run "scheduled_backups_reject_incomplete_chart_version" {
  # Storage, domains, and replica settings satisfy the other Helm checks.
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [helm_release.ao_data_platform]
}

run "scheduled_backups_reject_invalid_patch_chart_version" {
  # Storage, domains, and replica settings satisfy the other Helm checks.
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.not-a-number"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [helm_release.ao_data_platform]
}

run "scheduled_backups_reject_version_range_chart_version" {
  # Storage, domains, and replica settings satisfy the other Helm checks.
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = ">=5.2.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [helm_release.ao_data_platform]
}

run "scheduled_backups_reject_older_major_with_large_minor_chart_version" {
  # Storage, domains, and replica settings satisfy the other Helm checks.
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "4.1002.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [helm_release.ao_data_platform]
}

run "scheduled_backups_use_a_published_development_chart" {
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0-dev.gabcdef1"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  assert {
    condition = (
      helm_release.ao_data_platform[0].chart == "oci://registry-1.docker.io/montecarlodata/ao-data-platform" &&
      helm_release.ao_data_platform[0].version == "5.2.0-dev.gabcdef1" &&
      yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.enabled &&
      yamldecode(helm_release.ao_data_platform[0].values[0]).llmWorker.image.repository == "registry-1.docker.io/montecarlodata/ao-llm-worker"
    )
    error_message = "Development backups must use the published chart and exact version, with the same worker image registry as a release installation."
  }
}

run "scheduled_backups_reject_unversioned_development_builds" {
  # Storage, domains, and replica settings satisfy the other Helm checks.
  command = plan

  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "0.0.0-dev.gabcdef1"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }

  expect_failures = [helm_release.ao_data_platform]
}

run "published_charts_require_registry" {
  command = plan

  variables {
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm                  = { chart_version = "5.2.0-dev.gabcdef1" }
  }

  expect_failures = [var.helm]
}

run "published_charts_require_version" {
  command = plan

  variables {
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm                  = { chart_registry = "oci://registry-1.docker.io/montecarlodata" }
  }

  expect_failures = [var.helm]
}

run "probe_password_and_revision_are_wired_without_exposing_passwords" {
  command = plan
  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse = { backup = {
        enabled               = true
        image                 = "altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4"
        api_password_revision = "rotation-2"
      } }
    }
  }
  assert {
    condition = (
      aws_secretsmanager_secret.clickhouse_backup_probe[0].name == "test-cluster/clickhouse/backup-probe-credentials" &&
      aws_secretsmanager_secret.clickhouse_backup_probe[0].kms_key_id == aws_kms_key.pipeline_secrets.arn &&
      nonsensitive(aws_secretsmanager_secret_version.clickhouse_backup_probe[0].secret_string) == "22222222222222222222222222222222" &&
      contains(jsondecode(aws_iam_role_policy.external_secrets[0].policy).Statement[0].Resource, aws_secretsmanager_secret.clickhouse_backup_probe[0].arn) &&
      nonsensitive(kubernetes_secret_v1.clickhouse_backup_api[0].data.revision) == "rotation-2" &&
      yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.api.passwordRevision == "rotation-2"
    )
    error_message = "The probe password must be encrypted, readable by External Secrets, and the API revision must agree between Secret and chart."
  }
}

run "backup_rejects_missing_image" {
  command = plan
  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true } }
    }
  }
  expect_failures = [var.helm]
}

run "backup_rejects_tag_only_image" {
  command = plan
  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup:2.8.1" } }
    }
  }
  expect_failures = [var.helm]
}

run "backup_rejects_empty_revision" {
  command = plan
  variables {
    helm = { deploy_charts = false, clickhouse = { backup = { api_password_revision = "" } } }
  }
  expect_failures = [var.helm]
}

run "backup_rejects_unsafe_revision" {
  command = plan
  variables {
    helm = { deploy_charts = false, clickhouse = { backup = { api_password_revision = "bad/value" } } }
  }
  expect_failures = [var.helm]
}

run "backup_accepts_stock_digest_without_tag" {
  command = plan
  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true, image = "altinity/clickhouse-backup@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }
  assert {
    condition     = yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.sidecar.image == var.helm.clickhouse.backup.image
    error_message = "The supported stock image reference must reach the chart unchanged."
  }
}

run "backup_accepts_stock_docker_hub_prefix" {
  command = plan
  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true, image = "docker.io/altinity/clickhouse-backup:2.8.1@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }
  assert {
    condition     = yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.sidecar.image == var.helm.clickhouse.backup.image
    error_message = "The supported stock image reference must reach the chart unchanged."
  }
}

run "backup_accepts_stock_registry_prefix" {
  command = plan
  variables {
    clickhouse_backup     = { bucket_name = "test-clickhouse-backups" }
    clickhouse_domain     = "clickhouse.example.com"
    otel_collector_domain = "otel.example.com"
    helm = {
      chart_registry = "oci://registry-1.docker.io/montecarlodata"
      chart_version  = "5.2.0"
      clickhouse     = { backup = { enabled = true, image = "registry-1.docker.io/altinity/clickhouse-backup@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } }
    }
  }
  assert {
    condition     = yamldecode(helm_release.ao_data_platform[0].values[0]).clickhouse.backup.sidecar.image == var.helm.clickhouse.backup.image
    error_message = "The supported stock image reference must reach the chart unchanged."
  }
}

run "backup_rejects_custom_repository" {
  command = plan
  variables {
    helm = { deploy_charts = false, clickhouse = { backup = { image = "registry.example.com/backup@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } } }
  }
  expect_failures = [var.helm]
}

run "backup_rejects_other_version" {
  command = plan
  variables {
    helm = { deploy_charts = false, clickhouse = { backup = { image = "altinity/clickhouse-backup:2.8.0@sha256:08016b048f7e6035c048501315c2a788e5a782f15f168e042c7bd48d5a388cc4" } } }
  }
  expect_failures = [var.helm]
}

run "backup_rejects_unverified_digest" {
  command = plan
  variables {
    helm = { deploy_charts = false, clickhouse = { backup = { image = "altinity/clickhouse-backup:2.8.1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } } }
  }
  expect_failures = [var.helm]
}
