locals {
  effective_cluster_name = var.cluster.create ? var.cluster.name : var.cluster.existing_cluster_name

  # Region-qualified base for account-global IAM role names. IAM roles are
  # account-global, so two deployments of this module in one AWS account
  # (different regions, same cluster.name) would otherwise collide on role
  # names — the second deployment can't CreateRole and its apply aborts.
  # Embedding the region keeps them distinct. Region-scoped names (KMS alias,
  # Secrets Manager secrets, the EKS cluster) don't collide and intentionally
  # keep using effective_cluster_name.
  region_qualified_name = "${local.effective_cluster_name}-${var.region}"

  effective_vpc_id             = var.networking.create_vpc ? module.vpc[0].vpc_id : var.networking.existing_vpc_id
  effective_private_subnet_ids = var.networking.create_vpc ? module.vpc[0].private_subnets : var.networking.existing_private_subnet_ids

  # The dedicated CH NG is auto-created whenever we deploy the chart and
  # own the cluster (this module only manages node groups for clusters
  # it creates). Label and taint values stay constants so the node-group
  # definition and the helm values block below cannot drift.
  clickhouse_node_placement_enabled = var.helm.deploy_charts && var.cluster.create
  clickhouse_node_label_key         = "dedicated"
  clickhouse_node_label_value       = "clickhouse"

  # Keeper node-group label/taint. Mirrors the ClickHouse constants above so the
  # keeper node groups and the chart's keeper nodeSelector/tolerations cannot
  # drift. Same "dedicated" key, distinct value → a separate scheduling tenant,
  # so a ClickHouse node failure can't also remove a Keeper voter.
  keeper_node_label_key   = "dedicated"
  keeper_node_label_value = "keeper"

  # Resolved AZ for the dedicated CH NG: explicit override, else first
  # AZ from data.aws_availability_zones.available (alphabetical — typically
  # "-1a" for the region).
  clickhouse_az_resolved = coalesce(
    var.clickhouse_node_group.availability_zone,
    data.aws_availability_zones.available.names[0],
  )

  # Resolved main NG size. Defaults to 2 unconditionally — the dedicated
  # CH NG offloads ClickHouse, but the stateless tier (OTel, llm-worker,
  # cert-manager, external-secrets, coredns, aws-load-balancer-controller,
  # external-dns) still benefits from a 2-node HA floor on the main pool.
  # Set cluster.main_node_group_size = 1 explicitly to opt into the
  # cost-shrunk single-node main pool when HA isn't a requirement.
  main_node_group_size_resolved = coalesce(var.cluster.main_node_group_size, 2)

  # nonsensitive() unwraps the sensitivity tag that data.aws_subnets.ids
  # carries in some aws-provider versions — without it, the resulting list
  # poisons the EKS module's for_each over node-group subnet_ids with an
  # "Invalid for_each argument" error. Safe here: subnet IDs aren't secret.
  clickhouse_node_group_subnet_ids = local.clickhouse_node_placement_enabled ? nonsensitive(tolist(setintersection(
    toset(data.aws_subnets.ch_node_group_az_subnets[0].ids),
    toset(local.effective_private_subnet_ids)
  ))) : []

  # Union of the explicit CH + keeper AZ names — the set of AZs the HA topology
  # needs a single-AZ subnet for. Drives the per-AZ data.aws_subnets fan-out in
  # vpc.tf. Empty (no HA node groups) when neither list is set.
  ha_node_group_azs = distinct(concat(var.clickhouse_availability_zones, var.keeper_availability_zones))

  # Per-AZ subnet lists for the HA node groups, keyed by AZ name. Each is the
  # AZ's subnets intersected with the cluster's private subnets (excludes any
  # public subnet in the same AZ). nonsensitive() for the same reason as
  # clickhouse_node_group_subnet_ids above — the values feed the EKS module's
  # for_each over node-group subnet_ids. Empty maps when placement is disabled.
  clickhouse_subnet_ids_by_az = local.clickhouse_node_placement_enabled ? {
    for az in var.clickhouse_availability_zones : az => nonsensitive(tolist(setintersection(
      toset(data.aws_subnets.ha_node_group_az_subnets[az].ids),
      toset(local.effective_private_subnet_ids)
    )))
  } : {}
  keeper_subnet_ids_by_az = local.clickhouse_node_placement_enabled ? {
    for az in var.keeper_availability_zones : az => nonsensitive(tolist(setintersection(
      toset(data.aws_subnets.ha_node_group_az_subnets[az].ids),
      toset(local.effective_private_subnet_ids)
    )))
  } : {}

  cluster_endpoint       = var.cluster.create ? module.eks[0].cluster_endpoint : data.aws_eks_cluster.existing[0].endpoint
  cluster_ca_certificate = base64decode(var.cluster.create ? module.eks[0].cluster_certificate_authority_data : data.aws_eks_cluster.existing[0].certificate_authority[0].data)

  # OIDC: for new clusters the EKS module manages the provider; for existing clusters we create it.
  oidc_provider_arn = var.cluster.create ? module.eks[0].oidc_provider_arn : aws_iam_openid_connect_provider.cluster[0].arn
  oidc_provider_url = var.cluster.create ? module.eks[0].oidc_provider : trimprefix(data.aws_eks_cluster.existing[0].identity[0].oidc[0].issuer, "https://")

  # Use caller-supplied passwords when provided, otherwise fall back to generated
  # ones. Either way the value is sensitive (var.clickhouse_passwords is a
  # sensitive variable; random_password.result is provider-sensitive), so these
  # locals are redacted everywhere downstream.
  clickhouse_otel_password         = var.clickhouse_passwords.otel != null ? var.clickhouse_passwords.otel : random_password.clickhouse_otel[0].result
  clickhouse_monte_carlo_password  = var.clickhouse_passwords.monte_carlo != null ? var.clickhouse_passwords.monte_carlo : random_password.clickhouse_monte_carlo[0].result
  clickhouse_schema_owner_password = var.clickhouse_passwords.schema_owner != null ? var.clickhouse_passwords.schema_owner : random_password.clickhouse_schema_owner[0].result
  clickhouse_llm_worker_password   = var.clickhouse_passwords.llm_worker != null ? var.clickhouse_passwords.llm_worker : random_password.clickhouse_llm_worker[0].result

  # admin is a gated break-glass superuser (off by default), so — like
  # readonly_user — its password, secret, and chart wiring are all conditional
  # on its enabled flag.
  clickhouse_admin_enabled = try(var.helm.clickhouse.admin.enabled, false)
  clickhouse_admin_password = local.clickhouse_admin_enabled ? (
    var.clickhouse_passwords.admin != null ? var.clickhouse_passwords.admin : random_password.clickhouse_admin[0].result
  ) : null

  clickhouse_readonly_user_enabled = try(var.helm.clickhouse.readonly_user.enabled, false)
  clickhouse_readonly_user_password = local.clickhouse_readonly_user_enabled ? (
    var.clickhouse_passwords.readonly_user != null ? var.clickhouse_passwords.readonly_user : random_password.clickhouse_readonly_user[0].result
  ) : null

  llm_worker_image_repository = var.helm.deploy_charts ? coalesce(
    var.helm.llm_worker.image_repository,
    "${replace(var.helm.chart_registry, "oci://", "")}/ao-llm-worker",
  ) : null

  # Singleton maps for chart-values merging — empty when the caller didn't set
  # resources, otherwise { resources = { ... } } with null requests/limits keys
  # filtered out so we don't shadow chart defaults at sub-key level.
  helm_clickhouse_resources_block = var.helm.clickhouse.resources != null ? {
    resources = { for k, v in var.helm.clickhouse.resources : k => v if v != null }
  } : {}
  helm_otel_resources_block = var.helm.opentelemetry_collector.resources != null ? {
    resources = { for k, v in var.helm.opentelemetry_collector.resources : k => v if v != null }
  } : {}
  # Normalized awss3 S3 prefix: empty string stays empty; any non-empty value
  # gets exactly one trailing "/". Consumed by both the receiver config and the
  # IAM resource ARN below — keeps "traces" and "traces/" equivalent, and stops
  # a bare prefix from over-matching sibling keys (e.g. "traces*" matching
  # "tracesfoo") in the GetObject resource ARN.
  awss3_s3_prefix_normalized = try(var.helm.opentelemetry_collector.awss3_receiver.enabled, false) ? (
    var.helm.opentelemetry_collector.awss3_receiver.s3_prefix == "" ? "" : "${trimsuffix(var.helm.opentelemetry_collector.awss3_receiver.s3_prefix, "/")}/"
  ) : ""
  # awss3 receiver override. Empty when disabled; helm-merged into the chart's
  # opentelemetry-collector values when enabled. The pipelines.traces.receivers
  # list MUST mirror the chart's default list plus "awss3" — helm replaces lists
  # wholesale. If the chart adds a third trace receiver in a future version,
  # update this list.
  helm_otel_awss3_block = try(var.helm.opentelemetry_collector.awss3_receiver.enabled, false) ? {
    config = {
      receivers = {
        awss3 = {
          sqs = {
            queue_url = var.helm.opentelemetry_collector.awss3_receiver.sqs_queue_url
            region    = coalesce(var.helm.opentelemetry_collector.awss3_receiver.sqs_region, var.region)
          }
          s3downloader = {
            region    = coalesce(var.helm.opentelemetry_collector.awss3_receiver.s3_region, var.region)
            s3_bucket = var.helm.opentelemetry_collector.awss3_receiver.s3_bucket
            s3_prefix = local.awss3_s3_prefix_normalized
          }
        }
      }
      service = { pipelines = { traces = { receivers = ["otlp", "awss3"] } } }
    }
  } : {}
  helm_llm_worker_resources_block = var.helm.llm_worker.resources != null ? {
    resources = { for k, v in var.helm.llm_worker.resources : k => v if v != null }
  } : {}
  # Per-user ExternalSecret config forwarded into the ao-data-platform chart so
  # ESO syncs each ClickHouse user's password from Secrets Manager into the K8s
  # Secret the chart consumes. The secretStoreRef is the same ClusterSecretStore
  # for every user; only the remoteRef key differs. Keyed by the chart's per-user
  # value key (chart >= 2.0.0). readonly_user is wired separately below because it
  # is gated.
  clickhouse_user_external_secret = {
    for user, slug in {
      otel        = "otel-credentials"
      schemaOwner = "schema-owner-credentials"
      llmWorker   = "llm-worker-credentials"
      monteCarlo  = "monte-carlo-credentials"
      } : user => {
      secretStoreRef = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
      remoteRef      = { key = "${local.effective_cluster_name}/clickhouse/${slug}" }
    }
  }

  # Singleton map merged into clickhouse helm values when readonly_user is enabled.
  # Mirrors the otel ExternalSecret shape: ESO syncs from Secrets Manager into
  # the K8s Secret the chart consumes.
  helm_clickhouse_readonly_user_block = local.clickhouse_readonly_user_enabled ? {
    readonlyUser = {
      enabled = true
      externalSecret = {
        secretStoreRef = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
        remoteRef      = { key = "${local.effective_cluster_name}/clickhouse/readonly-user-credentials" }
      }
    }
  } : {}

  # Singleton map merged into clickhouse helm values when the gated admin
  # break-glass user is enabled. Wires the chart's admin user to its Secrets
  # Manager password; the chart's loopback-only networksIp default is left
  # in place, so admin stays reachable only via pod-exec.
  helm_clickhouse_admin_block = local.clickhouse_admin_enabled ? {
    admin = {
      enabled = true
      externalSecret = {
        secretStoreRef = { name = "aws-secrets-manager", kind = "ClusterSecretStore" }
        remoteRef      = { key = "${local.effective_cluster_name}/clickhouse/admin-credentials" }
      }
    }
  } : {}

  # Singleton maps merged into clickhouse helm values when the dedicated CH
  # node group is enabled. Wires the K8s-side nodeSelector + toleration to
  # match the taint applied on the node group above. Split into two singletons
  # to keep the type shape consistent with the existing chart-values merging
  # pattern (one key per block; empty when disabled — Terraform rejects a
  # combined block because the true and false branches would have inconsistent
  # object types).
  helm_clickhouse_node_selector_block = local.clickhouse_node_placement_enabled ? {
    nodeSelector = {
      (local.clickhouse_node_label_key) = local.clickhouse_node_label_value
    }
  } : {}
  helm_clickhouse_tolerations_block = local.clickhouse_node_placement_enabled ? {
    tolerations = [{
      key      = local.clickhouse_node_label_key
      operator = "Equal"
      value    = local.clickhouse_node_label_value
      effect   = "NoSchedule"
    }]
  } : {}

  # Keeper values, merged into the ao-data-platform release at the top level.
  # Emitted only when keeper_availability_zones is set — opting into the keeper
  # topology implies a keeper-capable chart (>= 2.2.0, the first version
  # exposing keeper.*; see the chart_version notes on var.helm in variables.tf).
  # replicaCount is derived from the AZ-list length so it cannot drift from the
  # keeper node-group count.
  helm_keeper_block = length(var.keeper_availability_zones) > 0 ? {
    keeper = {
      replicaCount = length(var.keeper_availability_zones)
      storageClass = var.keeper_node_group.storage_class
      storageSize  = var.keeper_node_group.storage_size
      nodeSelector = {
        (local.keeper_node_label_key) = local.keeper_node_label_value
      }
      tolerations = [{
        key      = local.keeper_node_label_key
        operator = "Equal"
        value    = local.keeper_node_label_value
        effect   = "NoSchedule"
      }]
    }
  } : {}

  # Optional replica-count overrides for the collector and llm-worker. null
  # (default) omits the key so the chart controls the count; setting it (e.g. 0)
  # pins the count as config that survives a `helm upgrade` — used to pause and
  # resume ingest during the HA migration window without a manual kubectl scale
  # being reset by the next apply.
  helm_otel_replica_block = var.helm.opentelemetry_collector.replica_count != null ? {
    replicaCount = var.helm.opentelemetry_collector.replica_count
  } : {}
  helm_llm_worker_replica_block = var.helm.llm_worker.replica_count != null ? {
    replicaCount = var.helm.llm_worker.replica_count
  } : {}

  # NLB source-range restriction. Each NLB is restricted only when its
  # *_nlb_allowed_source_ranges variable is set (non-null); when null the
  # source-range annotation is omitted and the NLB keeps its default
  # (unrestricted) source ranges. When restricted, the VPC's own CIDR block(s)
  # are folded into the allow-list so enabling a restriction never locks out
  # in-VPC clients. data.aws_vpc.selected is read only when at least one NLB is
  # restricted.
  clickhouse_nlb_restricted = var.helm.deploy_charts && var.clickhouse_nlb_allowed_source_ranges != null
  otel_nlb_restricted       = var.helm.deploy_charts && var.otel_collector_nlb_allowed_source_ranges != null
  nlb_source_ranges_enabled = local.clickhouse_nlb_restricted || local.otel_nlb_restricted
  vpc_cidr_blocks           = local.nlb_source_ranges_enabled ? data.aws_vpc.selected[0].cidr_block_associations[*].cidr_block : []

  clickhouse_nlb_source_ranges     = local.clickhouse_nlb_restricted ? concat(local.vpc_cidr_blocks, var.clickhouse_nlb_allowed_source_ranges) : null
  otel_collector_nlb_source_ranges = local.otel_nlb_restricted ? concat(local.vpc_cidr_blocks, var.otel_collector_nlb_allowed_source_ranges) : null
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_partition" "current" {}
data "aws_availability_zones" "available" {}
