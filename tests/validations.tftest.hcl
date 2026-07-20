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
//   - The postcondition on data.aws_subnets.ch_node_group_az_subnets and the
//     matching per-AZ ha_node_group_az_subnets postcondition (AZ must match a
//     private subnet) — also requires real-or-mocked subnet data. Exercised by
//     every apply.
//   - The clustered/HA ENABLED-path node-group shapes: keeper node-group count
//     = AZ count, one ClickHouse node group per AZ (all desired = 1). These
//     need module.eks + subnet data in the plan (the same brittle surface as
//     above), so they are exercised by real applies + code review. Likewise the
//     placement-gated Helm-release preconditions (legacy node-group retirement
//     guard, volume-AZ match guard): their failing path requires cluster.create
//     = true, which drags module.eks into the plan. The rest of the HA surface
//     IS covered below: the DISABLED path by ha_topology_inert_by_default, the
//     clickhouse_replica_count <= AZ-count precondition by
//     replica_count_exceeding_az_count_rejected (it reads only variables, so
//     the keeper-precondition technique reaches it), and the pure
//     variable-derived locals (helm_keeper_block, ha_node_group_azs, the
//     pause-ingest replica overrides) by the enabled-path runs at the end.
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
  assert {
    condition     = aws_secretsmanager_secret.clickhouse_schema_owner_password.tags["Team"] == "ao"
    error_message = "var.tags must propagate to the clickhouse_schema_owner Secrets Manager secret."
  }
  assert {
    condition     = aws_secretsmanager_secret.clickhouse_llm_worker_password.tags["Team"] == "ao"
    error_message = "var.tags must propagate to the clickhouse_llm_worker Secrets Manager secret."
  }
}

# --- HA topology: AZ-list and node-group input validations ---
#
# Variable-level rejection paths for the clustered/HA inputs, same style as the
# guards above: each fires at plan time before any provider data source is read.
# deploy_charts = false keeps the helm chart_registry/chart_version validations
# from also firing, so each run isolates the single variable under test.

run "keeper_azs_even_length_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm                      = { deploy_charts = false }
    keeper_availability_zones = ["us-east-1a", "us-east-1b"]
  }
  expect_failures = [var.keeper_availability_zones]
}

run "keeper_azs_duplicate_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm                      = { deploy_charts = false }
    keeper_availability_zones = ["us-east-1a", "us-east-1a", "us-east-1a"]
  }
  expect_failures = [var.keeper_availability_zones]
}

run "clickhouse_azs_duplicate_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm                          = { deploy_charts = false }
    clickhouse_availability_zones = ["us-east-1a", "us-east-1a"]
  }
  expect_failures = [var.clickhouse_availability_zones]
}

# Entries must be AZ names (lowercase letters, digits, hyphens). Uppercase is
# the likely typo — AZ ids ("use1-az1") and region-only values still match the
# character class, so the regex is a lint, not a full AZ-name parser.

run "clickhouse_azs_invalid_name_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm                          = { deploy_charts = false }
    clickhouse_availability_zones = ["US-EAST-1B"]
  }
  expect_failures = [var.clickhouse_availability_zones]
}

# Single element: odd length and no duplicates, so the name regex is the only
# validation that can fail.
run "keeper_azs_invalid_name_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm                      = { deploy_charts = false }
    keeper_availability_zones = ["US-EAST-1A"]
  }
  expect_failures = [var.keeper_availability_zones]
}

run "clickhouse_replica_count_below_one_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm                     = { deploy_charts = false }
    clickhouse_replica_count = 0
  }
  expect_failures = [var.clickhouse_replica_count]
}

run "keeper_node_group_ami_pin_with_use_latest_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = { deploy_charts = false }
    keeper_node_group = {
      use_latest_ami_release_version = true
      ami_release_version            = "1.35.5-20260527"
    }
  }
  expect_failures = [var.keeper_node_group]
}

run "clickhouse_ha_node_group_ami_pin_with_use_latest_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = { deploy_charts = false }
    clickhouse_ha_node_group = {
      use_latest_ami_release_version = true
      ami_release_version            = "1.35.5-20260527"
    }
  }
  expect_failures = [var.clickhouse_ha_node_group]
}

# --- keeper AZs require a module-created cluster ---
#
# The per-AZ keeper node groups are only created when cluster.create = true, but the
# keeper helm block (nodeSelector = dedicated=keeper) is emitted whenever keeper AZs are
# set. On an existing cluster that pairing would leave every Keeper voter Pending, so a
# precondition on the Helm release rejects it. This is a disabled-path run — cluster.create
# = false keeps module.eks out of the plan; deploy_charts = true (with chart_registry /
# chart_version / domains supplied, hosted_zone_id left null so no route53 for_each) makes
# the Helm release exist so its precondition evaluates.

run "keeper_azs_require_module_created_cluster_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    clickhouse_domain         = "clickhouse.example.com"
    otel_collector_domain     = "otel.example.com"
    keeper_availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
    helm = {
      deploy_charts  = true
      chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
      chart_version  = "2.3.0"
    }
  }
  expect_failures = [helm_release.ao_data_platform]
}

# --- clickhouse_replica_count must not exceed the per-AZ node-group count ---
#
# Cross-variable precondition on the Helm release: you cannot request more
# replicas than there are per-AZ ClickHouse node groups to place them on (with
# no AZ list, only 1 replica is valid). The condition reads only the two
# variables, so the same technique as the keeper run above reaches it:
# cluster.create = false keeps module.eks and every subnet data source out of
# the plan, deploy_charts = true makes the Helm release exist so its
# preconditions evaluate, and every sibling precondition passes (domains set,
# keeper AZs empty, placement disabled) — the replica ceiling is the only
# check that can fail.

run "replica_count_exceeding_az_count_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    clickhouse_domain        = "clickhouse.example.com"
    otel_collector_domain    = "otel.example.com"
    clickhouse_replica_count = 2
    helm = {
      deploy_charts  = true
      chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
      chart_version  = "3.0.0"
    }
  }
  expect_failures = [helm_release.ao_data_platform]
}

# --- HA topology inert by default ---
#
# With no AZ lists set (and charts off), the module creates no keeper or per-AZ
# ClickHouse node groups and emits no keeper helm values — single-instance
# behavior is unchanged. Asserts the gating locals collapse to empty. (The
# enabled-path node-group shapes — keeper NG count = AZ count, one CH NG per AZ
# (desired=1) — need module.eks + real/mocked subnet data to plan and are
# exercised by real applies + code review, per this file's scope note above.
# The enabled-path helm-values locals are pure variable expressions and are
# asserted by ha_locals_derive_from_az_lists below.)

run "ha_topology_inert_by_default" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = { deploy_charts = false }
  }
  assert {
    condition     = length(local.keeper_node_groups) == 0
    error_message = "keeper_node_groups must be empty when no keeper topology / charts are configured."
  }
  assert {
    condition     = length(local.clickhouse_ha_node_groups) == 0
    error_message = "clickhouse_ha_node_groups must be empty when no ClickHouse HA topology / charts are configured."
  }
  assert {
    condition     = length(local.helm_keeper_block) == 0
    error_message = "helm_keeper_block must be empty when keeper_availability_zones is unset."
  }
}

# --- enabled-path HA locals derive purely from the AZ lists ---
#
# helm_keeper_block and ha_node_group_azs read only variables and constants —
# no module.eks or subnet data required (the per-AZ subnet data source is
# gated on placement, which deploy_charts = false disables). One run with 3
# keeper AZs and 2 ClickHouse AZs (one zone overlapping) pins both contracts:
# keeper.replicasCount derives from the keeper AZ-list length (voters and node
# capacity cannot drift), and ha_node_group_azs is the deduplicated union of
# the two lists that drives the per-AZ subnet fan-out.

run "ha_locals_derive_from_az_lists" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm                          = { deploy_charts = false }
    clickhouse_availability_zones = ["us-east-1a", "us-east-1b"]
    keeper_availability_zones     = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
  assert {
    condition     = local.helm_keeper_block.keeper.replicasCount == 3
    error_message = "keeper.replicasCount must equal length(keeper_availability_zones)."
  }
  assert {
    condition     = local.helm_keeper_block.keeper.nodeSelector["dedicated"] == "keeper"
    error_message = "The keeper helm block must pin pods to the dedicated=keeper node groups."
  }
  assert {
    condition     = length(local.ha_node_group_azs) == 3 && toset(local.ha_node_group_azs) == toset(["us-east-1a", "us-east-1b", "us-east-1c"])
    error_message = "ha_node_group_azs must be the deduplicated union of the ClickHouse and keeper AZ lists."
  }
}

# --- replica overrides: null omits the key, 0 renders 0 ---
#
# The collector and llm-worker replica_count overrides must render faithfully:
# null (the default) must OMIT replicaCount so the chart controls the count,
# while an explicit 0 must render replicaCount = 0. A truthiness regression
# that treats 0 as unset would silently no-op the llm-worker pause lever.
# Note the end-to-end behavior differs by workload even though the module-side
# rendering asserted here is correct for both: the chart's collector template
# itself treats 0 as unset (deploying its default count), so the collector
# zero renders but does not pause ingest — see the helm variable docs. Pure
# locals, so both directions are plan-assertable with charts off; one run per
# workload, each also pinning the other workload's null-omission.

run "otel_replica_override_zero_renders" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts           = false
      opentelemetry_collector = { replica_count = 0 }
    }
  }
  assert {
    condition     = local.helm_otel_replica_block.replicaCount == 0
    error_message = "helm_otel_replica_block must render replicaCount = 0 when opentelemetry_collector.replica_count = 0."
  }
  assert {
    condition     = length(local.helm_llm_worker_replica_block) == 0
    error_message = "helm_llm_worker_replica_block must omit replicaCount when llm_worker.replica_count is null."
  }
}

run "llm_worker_replica_override_zero_renders" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      llm_worker    = { replica_count = 0 }
    }
  }
  assert {
    condition     = local.helm_llm_worker_replica_block.replicaCount == 0
    error_message = "helm_llm_worker_replica_block must render replicaCount = 0 when llm_worker.replica_count = 0."
  }
  assert {
    condition     = length(local.helm_otel_replica_block) == 0
    error_message = "helm_otel_replica_block must omit replicaCount when opentelemetry_collector.replica_count is null."
  }
}

# --- awss3 receivers: map-key and dedicated-queue validations ---
#
# awss3_receivers map keys become OTel component IDs ("awss3/<key>"), so the
# charset is restricted to alphanumerics, hyphens, and underscores. And every
# enabled receiver (the deprecated singular included) must consume its own
# dedicated SQS queue: in SQS mode a receiver deletes messages whose S3
# records it filtered out, so receivers sharing a queue silently lose
# notifications — duplicates are rejected at plan time. cluster.create = false
# keeps module.eks out of the plan (same technique as the runs above).

run "awss3_receivers_invalid_key_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      opentelemetry_collector = {
        awss3_receivers = {
          "bad/key" = {
            sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:queue-one"
            sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/queue-one"
            s3_bucket     = "bucket-one"
          }
        }
      }
    }
  }
  expect_failures = [var.helm]
}

run "awss3_receivers_duplicate_queue_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      opentelemetry_collector = {
        awss3_receivers = {
          one = {
            sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:shared-queue"
            sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/shared-queue"
            s3_bucket     = "bucket-one"
          }
          two = {
            sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:shared-queue"
            sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/shared-queue"
            s3_bucket     = "bucket-two"
          }
        }
      }
    }
  }
  expect_failures = [var.helm]
}

# --- awss3 receivers: rendering (pure locals, charts off) ---
#
# The normalized receivers map and the rendered helm block read only variables,
# so the whole rendering contract is plan-assertable with deploy_charts = false
# (same technique as the replica-override runs above).
#
# Back-compat is the acceptance test: the deprecated singular form must render
# under the bare "awss3" component ID with a ["otlp", "awss3"] pipeline —
# byte-identical to what the module rendered before awss3_receivers existed —
# so existing single-receiver deployments see a zero diff on upgrade.

run "awss3_singular_renders_identically" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      opentelemetry_collector = {
        awss3_receiver = {
          enabled       = true
          sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:queue-one"
          sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/queue-one"
          s3_bucket     = "bucket-one"
          s3_prefix     = "traces"
        }
      }
    }
  }
  assert {
    # jsonencode on both sides: == on complex values demands exact type match,
    # and the block local's type reflects its conditional-to-{} construction.
    # Key order is deterministic (lexical) in jsonencode, so this is a
    # byte-identical comparison of the rendered structure.
    condition = jsonencode(local.helm_otel_awss3_block) == jsonencode({
      config = {
        receivers = {
          awss3 = {
            sqs = {
              queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/queue-one"
              region    = "us-east-1"
            }
            s3downloader = {
              region    = "us-east-1"
              s3_bucket = "bucket-one"
              s3_prefix = "traces/"
            }
          }
        }
        service = { pipelines = { traces = { receivers = ["otlp", "awss3"] } } }
      }
    })
    error_message = "The singular awss3_receiver must render exactly the pre-awss3_receivers shape: bare \"awss3\" component ID, regions coalesced to var.region, prefix normalized to one trailing \"/\", pipeline [\"otlp\", \"awss3\"]."
  }
  # Same zero-diff contract for IAM: with one enabled receiver the generalized
  # policy must render byte-identically to the single-receiver policy this
  # module has always attached (same statement order, single-element lists).
  assert {
    condition = aws_iam_role_policy.otel_collector_awss3_receiver[0].policy == jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage",
            "sqs:GetQueueAttributes",
            "sqs:GetQueueUrl",
          ]
          Resource = ["arn:aws:sqs:us-east-1:123456789012:queue-one"]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = ["arn:aws:s3:::bucket-one/traces/*"]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation"]
          Resource = ["arn:aws:s3:::bucket-one"]
        },
      ]
    })
    error_message = "With a single enabled receiver, the awss3-receiver IAM policy must render byte-identically to the pre-awss3_receivers policy (SQS on the queue ARN, GetObject on <bucket>/<normalized prefix>*, GetBucketLocation on the bucket)."
  }
}

run "awss3_map_renders_component_ids" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      opentelemetry_collector = {
        awss3_receivers = {
          bravo = {
            sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:queue-bravo"
            sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/queue-bravo"
            s3_bucket     = "bucket-bravo"
            s3_prefix     = "traces/"
          }
          alpha = {
            sqs_queue_arn = "arn:aws:sqs:us-west-2:123456789012:queue-alpha"
            sqs_queue_url = "https://sqs.us-west-2.amazonaws.com/123456789012/queue-alpha"
            sqs_region    = "us-west-2"
            s3_bucket     = "bucket-alpha"
            s3_region     = "us-west-2"
          }
        }
      }
    }
  }
  assert {
    condition     = jsonencode(keys(local.helm_otel_awss3_block.config.receivers)) == jsonencode(["awss3/alpha", "awss3/bravo"])
    error_message = "Each awss3_receivers entry must render under component ID awss3/<key>."
  }
  assert {
    condition     = jsonencode(local.helm_otel_awss3_block.config.service.pipelines.traces.receivers) == jsonencode(["otlp", "awss3/alpha", "awss3/bravo"])
    error_message = "The traces pipeline must be [\"otlp\"] plus the sorted awss3 component IDs."
  }
  assert {
    condition     = local.helm_otel_awss3_block.config.receivers["awss3/alpha"].sqs.region == "us-west-2" && local.helm_otel_awss3_block.config.receivers["awss3/alpha"].s3downloader.region == "us-west-2"
    error_message = "Explicit sqs_region / s3_region must render as given (not coalesced to var.region)."
  }
  assert {
    condition     = local.helm_otel_awss3_block.config.receivers["awss3/bravo"].sqs.region == "us-east-1" && local.helm_otel_awss3_block.config.receivers["awss3/bravo"].s3downloader.s3_prefix == "traces/"
    error_message = "Omitted regions must coalesce to var.region, and an already-slashed prefix must keep exactly one trailing \"/\"."
  }
  assert {
    condition     = local.helm_otel_awss3_block.config.receivers["awss3/alpha"].s3downloader.s3_prefix == ""
    error_message = "An omitted s3_prefix must render as the empty string (whole-bucket receiver)."
  }
  # The single awss3-receiver IAM policy spans every enabled receiver, with
  # each statement's resource list sorted for plan stability. An empty
  # normalized prefix must yield a whole-bucket GetObject ARN (<bucket>/*).
  assert {
    condition = jsonencode(jsondecode(aws_iam_role_policy.otel_collector_awss3_receiver[0].policy).Statement[0].Resource) == jsonencode([
      "arn:aws:sqs:us-east-1:123456789012:queue-bravo",
      "arn:aws:sqs:us-west-2:123456789012:queue-alpha",
    ])
    error_message = "The awss3-receiver policy's SQS statement must cover every enabled receiver's queue ARN, sorted."
  }
  assert {
    condition = jsonencode(jsondecode(aws_iam_role_policy.otel_collector_awss3_receiver[0].policy).Statement[1].Resource) == jsonencode([
      "arn:aws:s3:::bucket-alpha/*",
      "arn:aws:s3:::bucket-bravo/traces/*",
    ])
    error_message = "The awss3-receiver policy's GetObject statement must cover every enabled receiver's <bucket>/<normalized prefix>* ARN, sorted."
  }
  assert {
    condition = jsonencode(jsondecode(aws_iam_role_policy.otel_collector_awss3_receiver[0].policy).Statement[2].Resource) == jsonencode([
      "arn:aws:s3:::bucket-alpha",
      "arn:aws:s3:::bucket-bravo",
    ])
    error_message = "The awss3-receiver policy's GetBucketLocation statement must cover every enabled receiver's bucket ARN, sorted."
  }
}

# Both forms together: the singular keeps its legacy bare ID alongside the
# map's namespaced IDs — combining them must not rename (and thus restart)
# the existing receiver.

run "awss3_singular_and_map_render_together" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      opentelemetry_collector = {
        awss3_receiver = {
          enabled       = true
          sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:queue-one"
          sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/queue-one"
          s3_bucket     = "bucket-one"
        }
        awss3_receivers = {
          charlie = {
            sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:queue-charlie"
            sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/queue-charlie"
            s3_bucket     = "bucket-charlie"
            s3_prefix     = "pipelines/otel/traces/"
          }
        }
      }
    }
  }
  assert {
    condition     = jsonencode(keys(local.helm_otel_awss3_block.config.receivers)) == jsonencode(["awss3", "awss3/charlie"])
    error_message = "Singular + map must render both receivers: the legacy bare \"awss3\" ID and the namespaced map entry."
  }
  assert {
    condition     = jsonencode(local.helm_otel_awss3_block.config.service.pipelines.traces.receivers) == jsonencode(["otlp", "awss3", "awss3/charlie"])
    error_message = "The traces pipeline must contain otlp plus both awss3 component IDs, sorted."
  }
}

run "awss3_disabled_receivers_render_nothing" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      opentelemetry_collector = {
        awss3_receiver = {
          enabled       = false
          sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:queue-one"
          sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/queue-one"
          s3_bucket     = "bucket-one"
        }
        awss3_receivers = {
          off = {
            enabled       = false
            sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:queue-off"
            sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/queue-off"
            s3_bucket     = "bucket-off"
          }
        }
      }
    }
  }
  assert {
    condition     = length(local.otel_awss3_receivers) == 0
    error_message = "Disabled receivers (singular and map entries) must be filtered out of the normalized map."
  }
  assert {
    condition     = length(local.helm_otel_awss3_block) == 0
    error_message = "helm_otel_awss3_block must be empty when every awss3 receiver is disabled, so the chart's own collector config is left untouched."
  }
  assert {
    condition     = length(aws_iam_role_policy.otel_collector_awss3_receiver) == 0
    error_message = "The awss3-receiver IAM policy must not be created when every awss3 receiver is disabled."
  }
}

# The dedicated-queue guard also spans the deprecated singular form: a map
# entry reusing the singular receiver's queue is the same data-loss shape.

run "awss3_singular_and_map_duplicate_queue_rejected" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = {
      deploy_charts = false
      opentelemetry_collector = {
        awss3_receiver = {
          enabled       = true
          sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:shared-queue"
          sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/shared-queue"
          s3_bucket     = "bucket-one"
        }
        awss3_receivers = {
          two = {
            sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:shared-queue"
            sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/shared-queue"
            s3_bucket     = "bucket-two"
          }
        }
      }
    }
  }
  expect_failures = [var.helm]
}

# --- networking.control_plane_subnet_ids: guards + control-plane/node split ---
#
# The input pins the cluster's control-plane ENI subnets independently of node
# topology (a cluster's control-plane AZ set is immutable after creation). Its
# load-bearing invariant is that it influences ONLY the cluster's vpc_config —
# node-group subnet resolution must keep reading existing_private_subnet_ids
# unchanged. The node side of that invariant is asserted below on
# local.effective_private_subnet_ids; the cluster side is a direct passthrough
# to the upstream module's control_plane_subnet_ids (which coalesces to
# subnet_ids when empty, so the unset default is byte-identical to the
# pre-input behavior) — asserting on it would need module.eks in the plan,
# which this file's scope note excludes.

run "control_plane_subnets_single_entry_rejected" {
  command = plan
  variables {
    # create = false keeps module.eks out of the plan (same technique as the
    # storage-validation runs): the expected failure is on var.networking,
    # which doesn't gate module.eks's count, so the baseline create = true
    # would drag the EKS module's resources into the plan past the failure.
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    networking = {
      create_vpc                  = false
      existing_vpc_id             = "vpc-12345678"
      existing_private_subnet_ids = ["subnet-aaaa1111", "subnet-bbbb2222"]
      control_plane_subnet_ids    = ["subnet-aaaa1111"]
    }
  }
  expect_failures = [var.networking]
}

run "control_plane_subnets_with_created_vpc_rejected" {
  command = plan
  variables {
    # create = false for the same module.eks-avoidance reason as above.
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    networking = {
      create_vpc               = true
      control_plane_subnet_ids = ["subnet-aaaa1111", "subnet-bbbb2222"]
    }
  }
  expect_failures = [var.networking]
}

# The migration shape: existing_private_subnet_ids widened past the
# creation-time subnets, control_plane_subnet_ids pinned to them. Node-group
# subnet resolution must be exactly the widened list — the pin never narrows
# it, and the node-only subnet never leaks out of it.

run "control_plane_subnets_never_reach_node_resolution" {
  command = plan
  variables {
    cluster = {
      create                = false
      name                  = "test-cluster"
      existing_cluster_name = "test-cluster"
    }
    helm = { deploy_charts = false }
    networking = {
      create_vpc                  = false
      existing_vpc_id             = "vpc-12345678"
      existing_private_subnet_ids = ["subnet-aaaa1111", "subnet-bbbb2222", "subnet-cccc3333"]
      control_plane_subnet_ids    = ["subnet-aaaa1111", "subnet-bbbb2222"]
    }
  }
  assert {
    condition     = local.effective_private_subnet_ids == tolist(["subnet-aaaa1111", "subnet-bbbb2222", "subnet-cccc3333"])
    error_message = "Node-group subnet resolution (effective_private_subnet_ids) must be exactly existing_private_subnet_ids — control_plane_subnet_ids must never narrow or widen it."
  }
}
