// Validation tests for the ao-data-platform module.
//
// Scope: variable-level rejection paths only — the safety nets that fire at
// terraform-plan time before any provider data sources are read, catching
// invalid inputs before they reach AWS. Each test uses `expect_failures`,
// so the validation fires and short-circuits the plan; no real AWS calls
// are needed.
//
// What's NOT covered here:
//   - "Accepted value" cases (e.g., main_node_group_size = 1 passes). These
//     would require Terraform to plan past variable validation into module
//     resolution, which pulls in the EKS module's data sources (IAM, KMS,
//     OIDC, etc.). Mocking that surface is brittle and high-maintenance.
//     Every real apply exercises the accepted path.
//   - The postcondition on data.aws_subnets.ch_node_group_az_subnets (AZ
//     must match a private subnet) — also requires real-or-mocked subnet
//     data. Exercised by every apply.
//   - The resolution locals (clickhouse_az_resolved,
//     main_node_group_size_resolved) — simple coalesce chains; regressions
//     would show up in plan diffs during code review.
//
// Requires Terraform >= 1.7 for mock_provider. The module itself stays at
// required_version >= 1.3; these .tftest.hcl files are dev-only and
// no-op on older Terraform versions.

mock_provider "aws" {
  # data.aws_availability_zones.available is read unconditionally in main.tf
  # to resolve the dedicated CH NG default AZ; without this override the
  # mock returns an empty list and crashes `names[0]` before any variable
  # validation gets a chance to fire.
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  # The cluster.create = false path (used by the storage-validation runs below
  # to keep module.eks out of the plan) reads the existing cluster's OIDC
  # issuer; without a populated identity the mock returns an empty list and
  # crashes identity[0] before the variable validations fire. Only consumed by
  # runs where data.aws_eks_cluster.existing[0] exists (create = false);
  # inert for the create = true runs above.
  override_data {
    target = data.aws_eks_cluster.existing[0]
    values = {
      identity = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/TESTOIDC" }] }]
      # base64("test-ca") — local.cluster_ca_certificate base64decodes this.
      certificate_authority = [{ data = "dGVzdC1jYQ==" }]
    }
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}

mock_provider "tls" {
  # aws_iam_openid_connect_provider.cluster[0] (create = false path) indexes
  # data.tls_certificate.cluster[0].certificates[0]; the mock otherwise returns
  # an empty list and crashes the index. Paired with the aws_eks_cluster
  # override above.
  override_data {
    target = data.tls_certificate.cluster[0]
    values = {
      certificates = [{ sha1_fingerprint = "0123456789abcdef0123456789abcdef01234567" }]
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

# Minimal valid baseline reused by every run unless overridden.
variables {
  region                = "us-east-1"
  otel_collector_domain = "otel.example.com"
  clickhouse_domain     = "clickhouse.example.com"

  helm = {
    deploy_charts = false
  }

  cluster = {
    create = true
    name   = "test-cluster"
  }

  networking = {
    create_vpc                  = false
    existing_vpc_id             = "vpc-12345678"
    existing_private_subnet_ids = ["subnet-aaaa1111", "subnet-bbbb2222"]
  }
}

# --- cluster.main_node_group_size range validation ---
#
# The safety net rejects values that would leave cluster add-ons
# unschedulable (0) or exceed the module's hardcoded max_size (>10).

run "main_ng_size_zero_rejected" {
  command = plan
  variables {
    cluster = {
      create               = true
      name                 = "test-cluster"
      main_node_group_size = 0
    }
  }
  expect_failures = [var.cluster]
}

run "main_ng_size_eleven_rejected" {
  command = plan
  variables {
    cluster = {
      create               = true
      name                 = "test-cluster"
      main_node_group_size = 11
    }
  }
  expect_failures = [var.cluster]
}

# --- cluster validity guard ---
#
# When cluster.create = false, existing_cluster_name must be set.

run "existing_cluster_name_required_when_not_creating" {
  command = plan
  variables {
    cluster = {
      create = false
      name   = "ignored-when-not-creating"
    }
  }
  expect_failures = [var.cluster]
}

# --- local-exec interpolation guards ---
#
# existing_cluster_name and region are interpolated into the single-quoted
# shell commands of the ESO provisioners (aws eks update-kubeconfig). The
# validations restrict both to shell-inert character sets, so a value
# containing a quote cannot break out of the quoting.

run "existing_cluster_name_with_quote_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "ignored-when-not-creating"
      existing_cluster_name = "bad'name"
    }
  }
  expect_failures = [var.cluster]
}

# cluster.create = false keeps module.eks out of the plan: a var.region
# failure doesn't gate module.eks (its arguments don't reference region),
# so with a creatable cluster the run would surface unrelated mock errors
# from inside the EKS module. (Same reasoning as the storage runs below.)
run "region_with_quote_rejected" {
  command = plan
  variables {
    region = "us-east-1'; touch /tmp/pwned; '"
    cluster = {
      create                = false
      name                  = "ignored-when-not-creating"
      existing_cluster_name = "test-cluster"
    }
  }
  expect_failures = [var.region]
}

# --- cluster.endpoint_public_access_cidrs CIDR validation ---

run "endpoint_public_access_cidr_invalid_rejected" {
  command = plan
  variables {
    cluster = {
      create                       = true
      name                         = "test-cluster"
      endpoint_public_access_cidrs = ["not-a-cidr"]
    }
  }
  expect_failures = [var.cluster]
}

# Disabling the public endpoint while restricting CIDRs is rejected up front:
# EKS requires publicAccessCidrs = ["0.0.0.0/0"] when the public endpoint is
# off, so the combination otherwise fails at apply with an opaque
# InvalidParameterException.
run "endpoint_private_only_with_restricted_cidrs_rejected" {
  command = plan
  variables {
    cluster = {
      create                       = true
      name                         = "test-cluster"
      endpoint_public_access       = false
      endpoint_public_access_cidrs = ["203.0.113.0/24"]
    }
  }
  expect_failures = [var.cluster]
}

# --- storage_class_clickhouse_gp3 gp3-parameter guards ---
#
# The clickhouse-gp3 StorageClass exposes iops/throughput; the validations
# reject values outside gp3's real limits (iops 3000-16000, throughput
# 125-1000) and the throughput-to-IOPS ratio limit (throughput <= 0.25 * iops).
#
# These runs set cluster.create = false so module.eks is not instantiated:
# the storage variables aren't EKS dependencies, so with a creatable cluster
# the plan would walk into the EKS module (mockable IAM surface) before these
# validation nodes are reached. Disabling the cluster lets the variable
# validation be the only thing that can fail. (Same reasoning as the file
# preamble's "accepted value" note.)

run "ch_storage_iops_below_min_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    storage_class_clickhouse_gp3 = {
      iops = 2000
    }
  }
  expect_failures = [var.storage_class_clickhouse_gp3]
}

run "ch_storage_throughput_above_max_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    storage_class_clickhouse_gp3 = {
      iops       = 16000
      throughput = 1200
    }
  }
  expect_failures = [var.storage_class_clickhouse_gp3]
}

run "ch_storage_throughput_exceeds_ratio_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    # In range individually (iops 3000, throughput 800) but 800 > 0.25 * 3000.
    storage_class_clickhouse_gp3 = {
      iops       = 3000
      throughput = 800
    }
  }
  expect_failures = [var.storage_class_clickhouse_gp3]
}

# --- clickhouse_storage_class name validation ---
#
# Must be a valid Kubernetes StorageClass name (DNS-style).

run "ch_storage_class_invalid_name_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    clickhouse_storage_class = "Bad_Name"
  }
  expect_failures = [var.clickhouse_storage_class]
}

# --- NLB allowed-source-range CIDR validation ---
#
# Each list entry must parse as a CIDR block (can(cidrnetmask(...))). null and
# [] are accepted (no restriction / VPC-only); a malformed entry is rejected.
#
# Like the storage runs above, these set cluster.create = false so module.eks
# is not instantiated. These variables gate nothing in the EKS graph, so with a
# creatable cluster the plan would walk into the EKS module and fail there
# before the variable validation node is reached, masking the expected failure.
# Disabling the cluster lets the CIDR validation be the only thing that fails.

run "ch_nlb_source_range_invalid_cidr_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    clickhouse_nlb_allowed_source_ranges = ["10.0.0.0/16", "not-a-cidr"]
  }
  expect_failures = [var.clickhouse_nlb_allowed_source_ranges]
}

run "otel_nlb_source_range_invalid_cidr_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    otel_collector_nlb_allowed_source_ranges = ["300.0.0.0/8"]
  }
  expect_failures = [var.otel_collector_nlb_allowed_source_ranges]
}

# clickhouse_node_group rejects the "pinned but ignored" misconfiguration:
# use_latest_ami_release_version = true silently overrides ami_release_version
# (the eks-managed-node-group resolves release_version = use_latest ? <latest> :
# ami_release_version), so an explicit pin set alongside use_latest = true does
# nothing. The validation refuses the combination rather than letting the pin
# quietly no-op. Like the runs above, cluster.create = false keeps module.eks
# out of the plan so the variable validation is the only thing that fails.
run "ch_ami_pin_with_use_latest_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    clickhouse_node_group = {
      use_latest_ami_release_version = true
      ami_release_version            = "1.35.5-20260527"
    }
  }
  expect_failures = [var.clickhouse_node_group]
}

# --- account-global IAM role names are region-qualified ---
#
# IAM roles are account-global, so two deployments sharing one AWS account
# (same cluster.name, different regions) must get distinct role names. The
# names embed var.region via local.region_qualified_name. otel_collector and
# llm_worker are created unconditionally; aws_load_balancer_controller and
# external_secrets are count-gated on helm.install_* (both default true, so
# count = 1 here) — covering 4/7 IRSA roles at zero extra setup. The remaining
# three are left out by design: ebs_csi_controller is gated on cluster.create
# (which every run here holds false to keep module.eks out), and cert_manager /
# external_dns need hosted_zone_id, which drags in the aws_route53_record cert-
# validation resources whose for_each is apply-unknown and fails a plan-only
# run. cluster.create = false keeps module.eks out of the plan (same reasoning
# as the runs above); effective_cluster_name resolves to existing_cluster_name.

run "irsa_role_names_are_region_qualified" {
  command = plan
  variables {
    region = "us-west-2"
    cluster = {
      create                = false
      name                  = "ignored-when-not-creating"
      existing_cluster_name = "test-cluster"
    }
  }
  assert {
    condition     = aws_iam_role.otel_collector.name == "test-cluster-us-west-2-otel-collector"
    error_message = "otel_collector IRSA role name must be region-qualified: <cluster>-<region>-otel-collector"
  }
  assert {
    condition     = aws_iam_role.llm_worker.name == "test-cluster-us-west-2-llm-worker"
    error_message = "llm_worker IRSA role name must be region-qualified: <cluster>-<region>-llm-worker"
  }
  assert {
    condition     = aws_iam_role.aws_load_balancer_controller[0].name == "test-cluster-us-west-2-aws-load-balancer-controller"
    error_message = "aws_load_balancer_controller IRSA role name must be region-qualified: <cluster>-<region>-aws-load-balancer-controller"
  }
  assert {
    condition     = aws_iam_role.external_secrets[0].name == "test-cluster-us-west-2-external-secrets"
    error_message = "external_secrets IRSA role name must be region-qualified: <cluster>-<region>-external-secrets"
  }
}

# --- clickhouse_passwords suppress the generated random_password ---
#
# The random_password.clickhouse_* resources are count-gated on whether the
# caller supplied that password: count = nonsensitive(var.clickhouse_passwords.<k> == null).
# The nonsensitive() wrapper is load-bearing — count cannot derive from a
# sensitive value, and clickhouse_passwords is sensitive — so a regression here
# either breaks plan (count from a sensitive value) or silently orphans a
# generated password. These two runs pin both directions of the gate.
#
# cluster.create = false keeps module.eks out of the plan (random_password is
# not an EKS dependency); admin.enabled and readonly_user.enabled = true exercise
# the compound gates on clickhouse_admin / clickhouse_readonly_user
# (enabled && password == null). The admin-disabled direction is pinned by
# clickhouse_admin_disabled_creates_no_secret below.

run "clickhouse_passwords_omitted_generate_random" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      clickhouse = {
        admin         = { enabled = true }
        readonly_user = { enabled = true }
      }
    }
  }
  assert {
    condition     = length(random_password.clickhouse_admin) == 1
    error_message = "clickhouse_admin password must be generated when clickhouse_passwords.admin is null."
  }
  # Pin the enabled direction of the admin secret gate: generating the password is
  # not enough — the Secrets Manager secret + version must also be created, or the
  # break-glass credential never lands in Secrets Manager for ESO to sync.
  assert {
    condition     = length(aws_secretsmanager_secret.clickhouse_admin_password) == 1
    error_message = "clickhouse_admin secret must be created when helm.clickhouse.admin is enabled."
  }
  assert {
    condition     = length(aws_secretsmanager_secret_version.clickhouse_admin_password) == 1
    error_message = "clickhouse_admin secret version must be created when helm.clickhouse.admin is enabled."
  }
  assert {
    condition     = length(random_password.clickhouse_otel) == 1
    error_message = "clickhouse_otel password must be generated when clickhouse_passwords.otel is null."
  }
  assert {
    condition     = length(random_password.clickhouse_monte_carlo) == 1
    error_message = "clickhouse_monte_carlo password must be generated when clickhouse_passwords.monte_carlo is null."
  }
  assert {
    condition     = length(random_password.clickhouse_schema_owner) == 1
    error_message = "clickhouse_schema_owner password must be generated when clickhouse_passwords.schema_owner is null."
  }
  assert {
    condition     = length(random_password.clickhouse_llm_worker) == 1
    error_message = "clickhouse_llm_worker password must be generated when clickhouse_passwords.llm_worker is null."
  }
  assert {
    condition     = length(random_password.clickhouse_readonly_user) == 1
    error_message = "clickhouse_readonly_user password must be generated when readonly_user is enabled and clickhouse_passwords.readonly_user is null."
  }
}

run "clickhouse_passwords_supplied_suppress_random" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      clickhouse = {
        admin         = { enabled = true }
        readonly_user = { enabled = true }
      }
    }
    clickhouse_passwords = {
      admin         = "supplied-admin"
      otel          = "supplied-otel"
      monte_carlo   = "supplied-mc"
      schema_owner  = "supplied-schema-owner"
      llm_worker    = "supplied-llm-worker"
      readonly_user = "supplied-ro"
    }
  }
  assert {
    condition     = length(random_password.clickhouse_admin) == 0
    error_message = "clickhouse_admin password must NOT be generated when clickhouse_passwords.admin is supplied."
  }
  assert {
    condition     = length(random_password.clickhouse_otel) == 0
    error_message = "clickhouse_otel password must NOT be generated when clickhouse_passwords.otel is supplied."
  }
  assert {
    condition     = length(random_password.clickhouse_monte_carlo) == 0
    error_message = "clickhouse_monte_carlo password must NOT be generated when clickhouse_passwords.monte_carlo is supplied."
  }
  assert {
    condition     = length(random_password.clickhouse_schema_owner) == 0
    error_message = "clickhouse_schema_owner password must NOT be generated when clickhouse_passwords.schema_owner is supplied."
  }
  assert {
    condition     = length(random_password.clickhouse_llm_worker) == 0
    error_message = "clickhouse_llm_worker password must NOT be generated when clickhouse_passwords.llm_worker is supplied."
  }
  assert {
    condition     = length(random_password.clickhouse_readonly_user) == 0
    error_message = "clickhouse_readonly_user password must NOT be generated when clickhouse_passwords.readonly_user is supplied."
  }
}

# --- admin is gated: disabled (default) creates no secret ---
#
# admin defaults off. With no helm.clickhouse.admin block, neither the password
# nor the Secrets Manager secret/version may be created — this pins the gate so a
# regression can't silently resurrect the orphan admin secret.

run "clickhouse_admin_disabled_creates_no_secret" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
    }
  }
  assert {
    condition     = length(random_password.clickhouse_admin) == 0
    error_message = "clickhouse_admin password must NOT be generated when helm.clickhouse.admin is disabled."
  }
  assert {
    condition     = length(aws_secretsmanager_secret.clickhouse_admin_password) == 0
    error_message = "clickhouse_admin secret must NOT be created when helm.clickhouse.admin is disabled."
  }
  # The disabled admin output contract is the one piece of output behavior a
  # plan-only run can verify (resource ARNs are unknown under the mock, but the
  # null branch is statically known).
  assert {
    condition     = output.clickhouse_admin_credentials_secret_arn == null
    error_message = "clickhouse_admin_credentials_secret_arn must be null when helm.clickhouse.admin is disabled."
  }
  # schema_owner and llm_worker are always provisioned (no enabled gate), even on
  # the admin-disabled baseline. These are single (uncounted) resources, so assert
  # a configured attribute directly — this both confirms the secret is in the plan
  # and pins the always-on contract: a future refactor adding a count gate would
  # turn these bare references into an error (forcing a [0] index), failing here.
  assert {
    condition     = endswith(aws_secretsmanager_secret.clickhouse_schema_owner_password.name, "/clickhouse/schema-owner-credentials")
    error_message = "clickhouse_schema_owner secret must always be created."
  }
  assert {
    condition     = endswith(aws_secretsmanager_secret.clickhouse_llm_worker_password.name, "/clickhouse/llm-worker-credentials")
    error_message = "clickhouse_llm_worker secret must always be created."
  }
}

# --- var.tags propagates to taggable AWS resources ---
#
# tags is threaded onto every taggable resource the module creates. Assert it
# on a representative resource per kind that is created unconditionally on the
# cluster.create = false path (keeps module.eks out of the plan, same as the
# runs above): an IRSA role, the KMS key, and a Secrets Manager secret. Assert
# the configured `tags` attribute, not the provider-computed `tags_all` (which
# folds in default_tags and is unknown under the mock).

run "tags_propagate_to_resources" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    tags = {
      Team = "ao"
    }
  }
  assert {
    condition     = aws_iam_role.otel_collector.tags["Team"] == "ao"
    error_message = "var.tags must propagate to the otel_collector IRSA role."
  }
  assert {
    condition     = aws_kms_key.pipeline_secrets.tags["Team"] == "ao"
    error_message = "var.tags must propagate to the pipeline_secrets KMS key."
  }
  assert {
    condition     = aws_secretsmanager_secret.clickhouse_otel_password.tags["Team"] == "ao"
    error_message = "var.tags must propagate to a ClickHouse Secrets Manager secret."
  }
}
