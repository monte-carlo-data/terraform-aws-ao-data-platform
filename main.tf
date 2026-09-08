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
  # Enabled awss3 receivers normalized into one map keyed by OTel component ID:
  # the deprecated singular form renders under the bare "awss3" ID — identical
  # to how it always rendered — and each awss3_receivers entry under
  # "awss3/<key>". Regions coalesce to var.region. S3 prefixes are normalized —
  # an empty string stays empty; any non-empty value gets exactly one trailing
  # "/" — keeping "traces" and "traces/" equivalent, and stopping a bare prefix
  # from over-matching sibling keys (e.g. "traces*" matching "tracesfoo") in
  # the IAM GetObject resource ARN. kms_key_arn projects to null except on the
  # synthesized trace-export-ingest entry below (see otel_awss3_receiver_kms_keys).
  # Single source of truth for the rendered receiver config, the trace-pipeline
  # receiver list, and every statement in the awss3-receiver IAM policy —
  # including the collector's KMS-decrypt grant, which is derived from this
  # map rather than reading var.trace_export_ingest directly.
  #
  # When var.trace_export_ingest is set, the module synthesizes one more entry
  # — "awss3/trace-export-ingest", consuming the module-created ingest
  # bucket/queue (s3.tf/sqs.tf) via the plan-known name locals below — so the
  # render, pipeline list, and collector read policy pick it up through the
  # same path as caller-configured receivers. A caller map key that would
  # collide is rejected by a precondition on the ingest queue.
  otel_awss3_receivers = {
    for id, r in merge(
      try(var.helm.opentelemetry_collector.awss3_receiver.enabled, false) ? { "awss3" = var.helm.opentelemetry_collector.awss3_receiver } : {},
      { for name, m in var.helm.opentelemetry_collector.awss3_receivers : "awss3/${name}" => m if m.enabled },
      local.trace_export_ingest_enabled ? {
        "awss3/trace-export-ingest" = {
          sqs_queue_arn = local.trace_export_ingest_queue_arn
          sqs_queue_url = local.trace_export_ingest_queue_url
          sqs_region    = null
          s3_bucket     = local.trace_export_ingest_bucket
          s3_region     = null
          s3_prefix     = local.trace_export_ingest_prefix
          kms_key_arn   = var.trace_export_ingest.kms_key_arn
        }
      } : {},
      ) : id => {
      sqs_queue_arn = r.sqs_queue_arn
      sqs_queue_url = r.sqs_queue_url
      sqs_region    = coalesce(r.sqs_region, var.region)
      s3_bucket     = r.s3_bucket
      s3_region     = coalesce(r.s3_region, var.region)
      s3_prefix     = r.s3_prefix == "" ? "" : "${trimsuffix(r.s3_prefix, "/")}/"
      # Only the synthesized trace-export-ingest entry carries a KMS key —
      # caller-configured awss3_receiver/awss3_receivers entries have no such
      # field in their object schema (variables.tf), so they project to null.
      kms_key_arn = try(r.kms_key_arn, null)
    }
  }
  # Every non-null kms_key_arn across the normalized receiver map, deduped —
  # today only the synthesized trace-export-ingest entry can carry one, but
  # the collector's KMS-decrypt grant (iam.tf) is built from this local so it
  # stays map-driven if that ever changes. Empty when no receiver has a CMK.
  otel_awss3_receiver_kms_keys = distinct([for r in values(local.otel_awss3_receivers) : r.kms_key_arn if r.kms_key_arn != null])
  # awss3 receivers override. Empty when no receiver is enabled; helm-merged
  # into the chart's opentelemetry-collector values otherwise. The
  # pipelines.traces.receivers list MUST mirror the chart's default list plus
  # our awss3 component IDs — helm replaces lists wholesale. If the chart adds
  # another default trace receiver in a future version, update this list.
  helm_otel_awss3_block = length(local.otel_awss3_receivers) > 0 ? {
    config = {
      receivers = {
        for id, r in local.otel_awss3_receivers : id => {
          sqs = {
            queue_url = r.sqs_queue_url
            region    = r.sqs_region
          }
          s3downloader = {
            region    = r.s3_region
            s3_bucket = r.s3_bucket
            s3_prefix = r.s3_prefix
          }
        }
      }
      service = { pipelines = { traces = { receivers = concat(["otlp"], sort(keys(local.otel_awss3_receivers))) } } }
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
      # The overlap password (YET-2680). Always wired, because the secret always
      # exists; it is the sentinel "-" in steady state, and the chart's ESO
      # template renders single-method auth for it. Requires chart >= 5.0.0
      # (ignored by older charts, which is what makes module adoption inert).
      previousKey = "${local.effective_cluster_name}/clickhouse/${replace(slug, "-credentials", "-previous-credentials")}"
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
        # Overlap password for rotations (YET-2680) — see clickhouse_user_external_secret.
        previousKey = "${local.effective_cluster_name}/clickhouse/readonly-user-previous-credentials"
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
        # Overlap password for rotations (YET-2680) — see clickhouse_user_external_secret.
        previousKey = "${local.effective_cluster_name}/clickhouse/admin-previous-credentials"
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
  # topology implies a keeper-capable chart (>= 2.3.0, the first version
  # exposing keeper.*; see the chart_version notes on var.helm in variables.tf).
  # replicasCount is derived from the AZ-list length so it cannot drift from the
  # keeper node-group count.
  helm_keeper_block = length(var.keeper_availability_zones) > 0 ? {
    keeper = {
      # Plural key: chart >= 2.3.0 renamed keeper.replicaCount -> keeper.replicasCount
      # (matching the CHK CRD field and clickhouse.replicasCount).
      replicasCount = length(var.keeper_availability_zones)
      storageClass  = var.keeper_node_group.storage_class
      storageSize   = var.keeper_node_group.storage_size
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

# Read only when the trace-export ingest block is set — the account ID feeds
# the default ingest bucket name and the constructed queue ARN/URL below.
data "aws_caller_identity" "trace_export_ingest" {
  count = var.trace_export_ingest != null ? 1 : 0
}

# --- Trace-export ingest (var.trace_export_ingest) ---
# Bucket and queue names are derived deterministically here — never read back
# from resource attributes — so everything downstream (receiver entry, queue
# policy, collector/writer IAM, outputs) is known at plan time; the ARNs and
# queue URL are string-built from the same name locals. All null when the
# block is unset, keeping the unset plan identical to previous releases.
locals {
  trace_export_ingest_enabled = var.trace_export_ingest != null

  # Same normalization as awss3-receiver prefixes above: exactly one trailing
  # "/" — keeping "traces" and "traces/" equivalent and stopping a bare prefix
  # from over-matching sibling keys in prefix-scoped IAM resource ARNs.
  trace_export_ingest_prefix = local.trace_export_ingest_enabled ? "${trimsuffix(var.trace_export_ingest.prefix, "/")}/" : null

  # S3 bucket names are globally unique, so the default is region_qualified_name
  # (cluster + region) plus the account ID — the same account-global stem the
  # writer role uses. The account ID alone is not enough: two applies in one
  # account with the same cluster name in different regions would otherwise
  # compute an identical name and collide on BucketAlreadyOwnedByYou.
  trace_export_ingest_bucket = local.trace_export_ingest_enabled ? coalesce(
    var.trace_export_ingest.bucket_name,
    "${local.region_qualified_name}-trace-export-ingest-${data.aws_caller_identity.trace_export_ingest[0].account_id}",
  ) : null
  trace_export_ingest_bucket_arn = local.trace_export_ingest_enabled ? "arn:${data.aws_partition.current.partition}:s3:::${local.trace_export_ingest_bucket}" : null

  # Trust anchoring for the writer role (iam.tf): the principal is the
  # external account's ROOT, derived from the validated execution-role ARN —
  # the variable validation guarantees its partition and 12-digit account
  # segments are literal — while the configured ARN/pattern itself lands in
  # the trust policy's aws:PrincipalArn condition. Wildcards therefore live
  # only in the condition, never in the principal.
  trace_export_producer_partition  = local.trace_export_ingest_enabled ? split(":", var.trace_export_ingest.producer_execution_role_arn)[1] : null
  trace_export_producer_account_id = local.trace_export_ingest_enabled ? split(":", var.trace_export_ingest.producer_execution_role_arn)[4] : null

  trace_export_ingest_queue_name = local.trace_export_ingest_enabled ? "${local.effective_cluster_name}-trace-export-ingest" : null
  trace_export_ingest_queue_arn  = local.trace_export_ingest_enabled ? "arn:${data.aws_partition.current.partition}:sqs:${var.region}:${data.aws_caller_identity.trace_export_ingest[0].account_id}:${local.trace_export_ingest_queue_name}" : null
  trace_export_ingest_queue_url  = local.trace_export_ingest_enabled ? "https://sqs.${var.region}.${data.aws_partition.current.dns_suffix}/${data.aws_caller_identity.trace_export_ingest[0].account_id}/${local.trace_export_ingest_queue_name}" : null

  # Derived (not read from the role resource) so the output stays plan-known;
  # the name is fixed by this module, so the ARN is deterministic.
  trace_export_writer_role_arn = local.trace_export_ingest_enabled ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.trace_export_ingest[0].account_id}:role/${local.region_qualified_name}-trace-export-writer" : null
}
