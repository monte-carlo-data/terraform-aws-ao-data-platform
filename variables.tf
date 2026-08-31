# --- AWS Configuration ---

variable "region" {
  description = "The AWS region to deploy resources into."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.region))
    error_message = "region must be a valid AWS region identifier (lowercase letters, digits, and hyphens, e.g. \"us-east-1\") — it is interpolated into provisioner shell commands and resource names."
  }
}

# --- Tagging ---

variable "tags" {
  description = <<-EOT
    Tags applied to every taggable AWS resource this module creates, and
    propagated to the VPC and EKS child modules. Use for cost allocation and
    ownership. Defaults to none.

    Note: a handful of resources are not AWS-taggable and carry no tags
    regardless — the KMS alias, Route 53 records, inline IAM policies, and the
    Kubernetes/Helm resources. Provider-level default_tags (configured on your
    aws provider) also apply and stack with these.
  EOT
  type        = map(string)
  default     = {}
}

# --- Cluster Configuration ---

variable "cluster" {
  description = <<-EOT
    EKS cluster configuration.

    - create: when true, a new EKS cluster is provisioned; when false, an existing
      cluster identified by existing_cluster_name is targeted.
    - name: name for the new cluster, or leave null to use the default "monte-carlo".
      Intentionally generic — the cluster may host other MC services (e.g. egress agent).
    - existing_cluster_name: required when create = false.
    - node_instance_type: EC2 instance type for the main managed node group (ignored
      when create = false).
    - main_node_group_size: optional explicit size (desired + min) for the main
      managed node group. When null (default), resolves to 2 — the stateless tier
      (OTel, llm-worker, cert-manager, external-secrets, coredns, aws-load-balancer-
      controller, external-dns) benefits from a 2-node HA floor on the main pool
      regardless of whether the dedicated CH NG is active. Set explicitly to 1 to
      opt into a cost-shrunk single-node main pool when HA isn't a requirement.
      max_size remains fixed at 10 to allow autoscaling burst.
    - endpoint_public_access: whether the EKS API server keeps its public
      endpoint. Defaults to true. The private endpoint is always enabled, so
      setting this false yields a private-only control plane — every machine
      that runs terraform/kubectl/helm against the cluster (CI included; this
      module's own local-exec provisioners too) must then reach the API over a
      private path (VPN, VPC peering, or a runner inside the VPC).
    - endpoint_public_access_cidrs: CIDR blocks allowed to reach the public
      endpoint. Defaults to ["0.0.0.0/0"] (unrestricted). When restricting,
      include the egress CIDRs of every machine that runs Terraform or kubectl
      against the cluster — hosted CI runners without stable egress IPs will
      otherwise lose access mid-pipeline.
      Both endpoint fields only apply when create = true; an existing cluster's
      endpoint configuration is managed wherever that cluster is managed.
  EOT
  type = object({
    create                       = optional(bool, true)
    name                         = optional(string, "monte-carlo")
    existing_cluster_name        = optional(string, null)
    node_instance_type           = optional(string, "t3.large")
    main_node_group_size         = optional(number, null)
    endpoint_public_access       = optional(bool, true)
    endpoint_public_access_cidrs = optional(list(string), ["0.0.0.0/0"])
  })
  default = {}

  validation {
    condition     = var.cluster.create || var.cluster.existing_cluster_name != null
    error_message = "existing_cluster_name is required when create = false."
  }

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.cluster.name))
    error_message = "cluster.name may only contain alphanumeric characters, hyphens, and underscores (required for KMS alias naming)."
  }

  validation {
    condition     = var.cluster.existing_cluster_name == null || can(regex("^[a-zA-Z0-9_-]+$", var.cluster.existing_cluster_name))
    error_message = "cluster.existing_cluster_name may only contain alphanumeric characters, hyphens, and underscores — it is interpolated into provisioner shell commands and resource names."
  }

  validation {
    condition     = var.cluster.main_node_group_size == null || (var.cluster.main_node_group_size >= 1 && var.cluster.main_node_group_size <= 10)
    error_message = "cluster.main_node_group_size must be between 1 and 10 when set. 0 leaves cluster add-ons (CoreDNS, kube-proxy, EBS CSI controller) with no nodes to schedule on; values > 10 exceed the module's hardcoded max_size and would be rejected by the EKS API at apply."
  }

  validation {
    condition     = var.cluster.endpoint_public_access_cidrs == null || alltrue([for c in coalesce(var.cluster.endpoint_public_access_cidrs, []) : can(cidrnetmask(c))])
    error_message = "cluster.endpoint_public_access_cidrs must be a list of valid CIDR blocks (e.g. \"203.0.113.0/24\")."
  }

  validation {
    condition     = var.cluster.endpoint_public_access || var.cluster.endpoint_public_access_cidrs == null || var.cluster.endpoint_public_access_cidrs == ["0.0.0.0/0"]
    error_message = "cluster.endpoint_public_access_cidrs cannot be restricted while cluster.endpoint_public_access = false: a private-only endpoint has no public CIDRs to allow-list, and EKS rejects any value other than [\"0.0.0.0/0\"] in that case (an opaque InvalidParameterException at apply). Restrict reachability via private networking (VPN/peering) instead, or keep endpoint_public_access = true to use the CIDR allow-list."
  }
}

# --- Dedicated ClickHouse Node Group ---

variable "clickhouse_node_group" {
  description = <<-EOT
    Configuration for the dedicated single-AZ ClickHouse node group.

    The dedicated CH NG is auto-created when helm.deploy_charts = true AND
    cluster.create = true, and managed while
    manage_legacy_clickhouse_node_group = true (the retirement gate for the
    clustered/HA migration). When those conditions hold, the module creates a
    single-node EKS managed node group pinned to availability_zone, tainted
    dedicated=clickhouse:NoSchedule, and wires the matching nodeSelector +
    toleration onto the chart's ClickHouse pod template automatically. The
    module expects chart_version >= "1.3.0" (the chart removed its OTel
    anti-affinity rule in favor of this structural separation). This is
    the structural fix for the scheduler-deadlock failure mode in chart
    1.2.x where the CH PV's AZ-lock (via EBS) combined with pod-level
    OTel anti-affinity could leave CH unschedulable.

    availability_zone: AZ to pin the dedicated NG to. When null (default),
    resolves to the first AZ from data.aws_availability_zones.available —
    alphabetical, so typically the "-1a" zone for the region. Override
    when the existing ClickHouse PV is in a different AZ: EBS volumes are
    AZ-locked, so the dedicated node group MUST live in the same AZ as
    the PV, or the CH pod cannot schedule.

    instance_type: EC2 instance type for the dedicated ClickHouse node.
    Defaults to r5.xlarge (4 vCPU, 32 GiB — fits a single CH pod plus
    DaemonSets). Independent from cluster.node_instance_type because the
    two pools host different workload shapes — ClickHouse is memory-bound
    (OLAP) while the main pool runs CPU-leaning stateless workloads (OTel
    collector, llm-worker), so each pool benefits from a different
    instance class. The module defaults reflect that: t3.large for the
    main pool (cheap baseline for stateless workloads, with burstable
    CPU) and r5.xlarge here (memory-optimized floor for OLAP).

    Has no effect when helm.deploy_charts = false or cluster.create = false
    (for existing clusters, manage the dedicated node group externally
    and supply matching clickhouse.nodeSelector + clickhouse.tolerations
    to the chart directly).

    use_latest_ami_release_version: whether the dedicated CH node group
    tracks AWS's latest recommended EKS-optimized AMI. Defaults to false —
    the CH node is no-drift pinned, so its AMI cannot change on an
    unrelated apply. This matters because ClickHouse is a single-replica,
    AZ-locked StatefulSet: any node roll is a ~2 min outage. The
    underlying eks module's own default (true) re-resolves the AMI to the
    latest build on EVERY apply, bouncing CH whenever AWS publishes a new
    AMI — including on an apply made for an entirely unrelated change.
    Leave false; setting it true opts the stateful CH node back into
    per-apply AMI drift.

    ami_release_version: the explicit EKS-optimized AMI build to pin the CH
    node to (e.g. "1.35.5-20260527"), normally supplied via tfvars. null
    (default) means no version of record — the node keeps whatever AMI it
    currently runs and still does not drift, because
    use_latest_ami_release_version = false skips the AMI lookup entirely.
    Set an explicit build to make the pin auditable and to perform a
    deliberate AMI bump: changing this value rolls the CH node exactly
    once (the module hardcodes force_update_version = true on this NG so
    the roll completes despite the single-replica PodDisruptionBudget).
    The build's minor MUST match the cluster kubernetes_version (EKS
    rejects e.g. a 1.34.x build on a 1.35 cluster). Ignored when
    use_latest_ami_release_version = true, which overrides it.
  EOT
  type = object({
    availability_zone              = optional(string)
    instance_type                  = optional(string, "r5.xlarge")
    use_latest_ami_release_version = optional(bool, false)
    ami_release_version            = optional(string)
  })
  default = {}

  validation {
    condition     = !(var.clickhouse_node_group.use_latest_ami_release_version && var.clickhouse_node_group.ami_release_version != null)
    error_message = "clickhouse_node_group.ami_release_version is ignored when use_latest_ami_release_version = true (use_latest overrides the explicit pin, so the pin would silently do nothing). Set use_latest_ami_release_version = false to pin to ami_release_version, or clear ami_release_version to track the latest AMI."
  }
}

# --- ClickHouse / Keeper HA Topology ---
# These variables stand up the clustered/HA node-group topology (per-AZ, AZ-pinned
# node groups for ClickHouse replicas and Keeper voters). All are additive and
# default to a no-op: with the AZ lists empty, no new node groups are created and
# the module behaves exactly as the single-instance deployment did.

variable "clickhouse_availability_zones" {
  description = <<-EOT
    Explicit AZ names for the dedicated per-AZ ClickHouse node groups that back a
    clustered/HA deployment (1 shard x N replicas). One managed node group is created
    per entry, keyed by AZ name (clickhouse-<az>). EBS volumes are AZ-locked, so each
    replica's node group must be single-AZ; placement is driven by these explicit AZ
    names rather than a positional index into the available-AZ data source (which can
    silently remap "the first AZ" to a different physical zone across applies).

    IMPORTANT: element 0 MUST be the AZ of the existing single-instance ClickHouse PV
    (the AZ that var.clickhouse_node_group.availability_zone resolves to). During the
    in-place migration the running ClickHouse pod relocates onto clickhouse-<element-0>
    and reattaches its existing AZ-locked volume; a mismatch strands that volume and
    leaves the pod Pending. A plan-time precondition on the Helm release enforces the
    match; set enforce_clickhouse_volume_az_match = false to skip it when there is no
    existing volume to preserve (fresh HA stand-up or deliberate re-ingest).

    When create_vpc = true, entries must be a subset of the AZs the module's private
    subnets were placed in (the first N of the available-AZ data source) — otherwise
    the per-AZ subnet postcondition fails at plan time.

    Empty (default) creates no per-AZ CH node groups: the module keeps only the legacy
    single ClickHouse node group. Set this (e.g. 2 AZs for RF=2) to stand up the HA
    topology. The list length is the ceiling for clickhouse_replica_count.

    Only applies to module-created clusters: when cluster.create = false no per-AZ
    node groups are created. For existing clusters, attach tainted single-AZ node
    groups out-of-band (see the README's "Clustered / HA topology" section).
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for az in var.clickhouse_availability_zones : can(regex("^[a-z0-9-]+$", az))])
    error_message = "clickhouse_availability_zones entries must be AZ names (lowercase letters, digits, hyphens), e.g. \"us-east-1a\"."
  }

  validation {
    condition     = length(var.clickhouse_availability_zones) == length(distinct(var.clickhouse_availability_zones))
    error_message = "clickhouse_availability_zones must not contain duplicate AZ names (one node group is created per entry)."
  }
}

variable "keeper_availability_zones" {
  description = <<-EOT
    Explicit AZ names for the dedicated per-AZ ClickHouse Keeper node groups (one voter
    per AZ, keeper-<az>). Keeper quorum needs an odd number of voters across distinct
    failure domains — 3 is standard (tolerates one AZ loss, keeping 2/3); 1 for dev.
    Like clickhouse_availability_zones, placement is by explicit AZ name because
    Keeper's EBS volumes are AZ-locked.

    Empty (default) creates no keeper node groups. When set, this list's length is the
    single source of truth for BOTH the number of keeper node groups AND the
    keeper.replicasCount passed to the chart — so voter count and node capacity cannot
    drift.

    Requires cluster.create = true: the keeper node groups are only created for
    module-created clusters, so on an existing cluster the chart's keeper node
    selector would match no nodes — a plan-time precondition on the Helm release
    rejects that combination.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for az in var.keeper_availability_zones : can(regex("^[a-z0-9-]+$", az))])
    error_message = "keeper_availability_zones entries must be AZ names (lowercase letters, digits, hyphens), e.g. \"us-east-1a\"."
  }

  validation {
    condition     = length(var.keeper_availability_zones) == length(distinct(var.keeper_availability_zones))
    error_message = "keeper_availability_zones must not contain duplicate AZ names (one keeper node group / voter is created per entry)."
  }

  validation {
    condition     = length(var.keeper_availability_zones) == 0 || length(var.keeper_availability_zones) % 2 == 1
    error_message = "keeper_availability_zones must have an odd length — Keeper quorum needs an odd voter count (typically 3, or 1 for dev). Empty disables keeper node groups."
  }
}

variable "clickhouse_replica_count" {
  description = <<-EOT
    Number of ClickHouse replicas, passed to the chart as clickhouse.replicasCount.
    TF-owned and defaulted to 1 so that bumping helm.chart_version — to a chart
    whose own default is or becomes 2 (it is 2 from chart 3.0.0) — never silently
    scales replicas against not-yet-converted tables.

    Raising above 1 requires chart_version >= "3.0.0", the replicated-schema
    release. On clusters with pre-existing data that is necessary but not
    sufficient: every existing table must additionally have been converted to a
    replicated engine first — raising the count against unconverted tables
    starts an empty second replica instead of a copy. See the chart's
    migration-ordering guidance and the README section "Clustered / HA
    topology".

    Must not exceed the number of per-AZ ClickHouse node groups available to place
    replicas on (max(length(clickhouse_availability_zones), 1)). That ceiling is
    enforced by a precondition on the Helm release rather than a variable validation,
    because it references two variables (cross-variable validation would require
    Terraform >= 1.9, and this module supports >= 1.3).
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.clickhouse_replica_count >= 1
    error_message = "clickhouse_replica_count must be at least 1."
  }
}

variable "clickhouse_ha_node_group" {
  description = <<-EOT
    Configuration for the dedicated per-AZ ClickHouse node groups (clickhouse-<az>)
    used by the clustered/HA topology. Kept separate from clickhouse_node_group so the
    go-forward instance type can differ from the legacy single node group WITHOUT
    re-typing the legacy one — re-typing a managed node group replaces its instances,
    which would roll the running ClickHouse pod.

    instance_type defaults to r6i.xlarge (memory-optimized, current generation).

    use_latest_ami_release_version / ami_release_version behave like their
    clickhouse_node_group counterparts: the AMI is pinned by default (no per-apply
    drift), and at RF=2 the pin also stops an uncontrolled "latest AMI" lookup from
    trying to roll BOTH single-AZ replicas in one apply (which the PDB would then block
    mid-apply). Set ami_release_version for a deliberate, one-at-a-time bump; the
    build's minor must match the cluster's kubernetes_version.
  EOT
  type = object({
    instance_type                  = optional(string, "r6i.xlarge")
    use_latest_ami_release_version = optional(bool, false)
    ami_release_version            = optional(string)
  })
  default = {}

  validation {
    condition     = !(var.clickhouse_ha_node_group.use_latest_ami_release_version && var.clickhouse_ha_node_group.ami_release_version != null)
    error_message = "clickhouse_ha_node_group.ami_release_version is ignored when use_latest_ami_release_version = true. Set use_latest_ami_release_version = false to pin to ami_release_version, or clear ami_release_version to track the latest AMI."
  }
}

variable "keeper_node_group" {
  description = <<-EOT
    Configuration for the dedicated per-AZ ClickHouse Keeper node groups (keeper-<az>).
    One node group (one voter) is created per keeper_availability_zones entry; there is
    intentionally NO replica_count field here — the voter count is derived from
    length(keeper_availability_zones) so the node groups and the chart's
    keeper.replicasCount cannot drift.

    instance_type defaults to m6i.large (non-burstable: a throttled quorum voter risks
    spurious leader elections; 2 vCPU is the non-burstable floor).

    storage_size / storage_class configure the Keeper PVC requested via the chart's
    keeper values (NOT the node's root disk). Default gp3 (WaitForFirstConsumer,
    reclaim Delete) is sufficient — a replaced Keeper re-syncs its state from quorum,
    so Retain is not required.

    use_latest_ami_release_version / ami_release_version: the AMI is pinned by default
    like the ClickHouse node groups. With 3 single-AZ voters, an uncontrolled "latest
    AMI" lookup could roll all three at once and lose quorum; pinning forces deliberate,
    one-at-a-time bumps via ami_release_version.
  EOT
  type = object({
    instance_type                  = optional(string, "m6i.large")
    storage_size                   = optional(string, "10Gi")
    storage_class                  = optional(string, "gp3")
    use_latest_ami_release_version = optional(bool, false)
    ami_release_version            = optional(string)
  })
  default = {}

  validation {
    condition     = !(var.keeper_node_group.use_latest_ami_release_version && var.keeper_node_group.ami_release_version != null)
    error_message = "keeper_node_group.ami_release_version is ignored when use_latest_ami_release_version = true. Set use_latest_ami_release_version = false to pin to ami_release_version, or clear ami_release_version to track the latest AMI."
  }
}

variable "enforce_clickhouse_volume_az_match" {
  description = <<-EOT
    Whether a plan-time precondition on the Helm release requires element 0 of
    clickhouse_availability_zones to match the AZ of the existing single-instance
    ClickHouse volume (the AZ clickhouse_node_group.availability_zone resolves to).
    Defaults to true: during the in-place HA migration the running ClickHouse pod
    relocates onto clickhouse-<element-0> and reattaches its AZ-locked EBS volume,
    so a mismatch strands the volume and leaves the pod Pending — with no other
    plan-time signal.

    Set to false only when there is genuinely no existing volume to preserve: a
    fresh HA stand-up (no single-instance deployment preceded it) or a deliberate
    re-ingest migration that abandons the old volume. Has no effect when
    clickhouse_availability_zones is empty or on existing (non-module-created)
    clusters, where the module creates no per-AZ node groups.
  EOT
  type        = bool
  default     = true
}

variable "manage_legacy_clickhouse_node_group" {
  description = <<-EOT
    Whether the module manages the legacy single-instance ClickHouse node group (the
    "clickhouse" managed node group at eks.tf). Defaults to true (unchanged behavior).

    During the HA migration this is flipped to false in a final, post-cutover apply to
    retire the now-empty legacy node group once the ClickHouse pod has relocated onto a
    per-AZ node group — a config change, so no module release is needed to remove it.
    Only has an effect when the dedicated CH node group would otherwise be created
    (helm.deploy_charts = true and cluster.create = true).
  EOT
  type        = bool
  default     = true
}

# --- Networking ---

variable "networking" {
  description = <<-EOT
    VPC and networking configuration.

    When create_vpc = true, a new VPC with public and private subnets is created.
    When create_vpc = false, provide existing_vpc_id and existing_private_subnet_ids.
    At least two private subnets in different AZs are required for the managed node group.

    The private subnets (module-created, or existing_private_subnet_ids) also pin
    NLB placement: the module renders them into the aws-load-balancer-subnets
    annotation on both LoadBalancer Services, so the LB controller places NLB ENIs
    there instead of auto-discovering subnets — in a VPC without
    kubernetes.io/role/internal-elb subnet tags, discovery falls back to a
    lexicographic per-AZ pick that can land ENIs in unrelated subnets sharing the
    VPC. The controller accepts at most one subnet per AZ in that annotation, so
    keep existing_private_subnet_ids to one subnet per AZ.

    control_plane_subnet_ids mirrors the upstream EKS module input of the same name:
    when set, it alone populates the cluster's vpc_config (control-plane ENI
    placement), while existing_private_subnet_ids keeps driving node-group subnet
    resolution. An EKS cluster's control-plane AZ set is immutable after creation —
    AWS rejects a vpc_config update whose subnets span a different AZ set, and
    Terraform only surfaces that at apply time. Worker nodes have no such
    restriction, so to add node capacity in an AZ the cluster wasn't created in,
    append the new subnet to existing_private_subnet_ids and pin
    control_plane_subnet_ids to the creation-time subnets. Empty (default) leaves
    behavior unchanged: the control plane uses existing_private_subnet_ids.
  EOT
  type = object({
    create_vpc                  = optional(bool, true)
    vpc_cidr                    = optional(string, "10.18.0.0/16")
    private_subnet_cidrs        = optional(list(string), ["10.18.1.0/24", "10.18.2.0/24", "10.18.3.0/24"])
    public_subnet_cidrs         = optional(list(string), ["10.18.4.0/24", "10.18.5.0/24", "10.18.6.0/24"])
    existing_vpc_id             = optional(string, null)
    existing_private_subnet_ids = optional(list(string), [])
    control_plane_subnet_ids    = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = var.networking.create_vpc || var.networking.existing_vpc_id != null
    error_message = "existing_vpc_id is required when create_vpc = false."
  }

  validation {
    condition     = var.networking.create_vpc || length(var.networking.existing_private_subnet_ids) >= 2
    error_message = "At least two existing_private_subnet_ids are required when create_vpc = false."
  }

  validation {
    condition     = length(var.networking.control_plane_subnet_ids) == 0 || !var.networking.create_vpc
    error_message = "control_plane_subnet_ids requires create_vpc = false. When the module creates the VPC, its subnet IDs are unknown until apply, so any value here would reference foreign subnets; module-created clusters place the control plane in every private subnet at creation."
  }

  validation {
    condition     = length(var.networking.control_plane_subnet_ids) == 0 || length(var.networking.control_plane_subnet_ids) >= 2
    error_message = "At least two control_plane_subnet_ids (in different AZs) are required when set — EKS requires the control plane to span at least two AZs."
  }
}

# --- Pipeline Configuration ---

variable "otel_collector_domain" {
  description = <<-EOT
    Domain name for the OTel Collector HTTPS endpoint (e.g. "otel.acme.com").
    Passed to the ao-data-platform chart; the chart creates the NLB Service with the
    appropriate external-dns and TLS annotations. When null, no domain is configured
    and the chart falls back to the raw NLB hostname.
  EOT
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = <<-EOT
    Route 53 hosted zone ID for clickhouse_domain and otel_collector_domain. When set, Terraform creates
    IRSA roles for cert-manager (ACME DNS-01 challenge records) and external-dns (automatic CNAME
    management), and installs the external-dns controller.
    When null, DNS and certificate management must be handled manually.
  EOT
  type        = string
  default     = null
}

variable "clickhouse_domain" {
  description = <<-EOT
    Domain name for the ClickHouse TCP+TLS endpoint (e.g. "clickhouse.acme.com").
    Passed to the ao-data-platform chart; the chart creates the NLB Service with the
    appropriate external-dns and TLS annotations. The cert-manager ACME issuer issues
    a Let's Encrypt certificate for this domain so external clients can connect without
    distributing a custom CA cert. When null, the chart falls back to the raw NLB hostname.
  EOT
  type        = string
  default     = null
}

variable "clickhouse_nlb_allowed_source_ranges" {
  description = <<-EOT
    CIDR ranges permitted to connect to the internal ClickHouse NLB. Whenever any restriction is
    in effect, the VPC's own CIDR block(s) are added to the allow-list automatically, so enabling
    one never locks out in-VPC clients. Note the distinction between null and an empty list:

    - null (default): no restriction — the NLB accepts traffic from any source that can reach it
      (in-VPC clients included, as is anything else with a network path).
    - [] (empty list): restricted to the VPC CIDR block(s) only.
    - ["10.20.0.0/16", ...]: restricted to the VPC CIDR block(s) plus the listed ranges.

    Enforced via the AWS Load Balancer Controller load-balancer-source-ranges annotation on the
    Service, so the restriction only takes effect when helm.deploy_charts = true. With the charts
    not deployed there is no Service to annotate, and the value has no effect.

    Note: the NLB uses an internal scheme, so a listed range is only reachable if a private
    network path into the VPC already exists (e.g. VPN, VPC peering, Transit Gateway, or a
    subnet router). Adding a CIDR here does not by itself create network reachability.
  EOT
  type        = list(string)
  default     = null

  validation {
    condition     = var.clickhouse_nlb_allowed_source_ranges == null || alltrue([for c in coalesce(var.clickhouse_nlb_allowed_source_ranges, []) : can(cidrnetmask(c))])
    error_message = "clickhouse_nlb_allowed_source_ranges must be a list of valid CIDR blocks (e.g. \"10.0.0.0/16\")."
  }
}

variable "otel_collector_nlb_allowed_source_ranges" {
  description = <<-EOT
    CIDR ranges permitted to connect to the internal OTel Collector NLB. Whenever any restriction
    is in effect, the VPC's own CIDR block(s) are added to the allow-list automatically, so
    enabling one never locks out in-VPC clients. Note the distinction between null and an empty
    list:

    - null (default): no restriction — the NLB accepts traffic from any source that can reach it
      (in-VPC clients included, as is anything else with a network path).
    - [] (empty list): restricted to the VPC CIDR block(s) only.
    - ["10.20.0.0/16", ...]: restricted to the VPC CIDR block(s) plus the listed ranges.

    Enforced via the AWS Load Balancer Controller load-balancer-source-ranges annotation on the
    Service, so the restriction only takes effect when helm.deploy_charts = true. With the charts
    not deployed there is no Service to annotate, and the value has no effect.

    Note: the NLB uses an internal scheme, so a listed range is only reachable if a private
    network path into the VPC already exists (e.g. VPN, VPC peering, Transit Gateway, or a
    subnet router). Adding a CIDR here does not by itself create network reachability.
  EOT
  type        = list(string)
  default     = null

  validation {
    condition     = var.otel_collector_nlb_allowed_source_ranges == null || alltrue([for c in coalesce(var.otel_collector_nlb_allowed_source_ranges, []) : can(cidrnetmask(c))])
    error_message = "otel_collector_nlb_allowed_source_ranges must be a list of valid CIDR blocks (e.g. \"10.0.0.0/16\")."
  }
}

variable "clickhouse_ttl_days" {
  description = "ClickHouse data retention TTL in days. Passed through to the ao-data-platform Helm chart."
  type        = number
  default     = 30
}

# --- Helm Deployment ---

variable "helm" {
  description = <<-EOT
    Helm chart deployment configuration.

    deploy_charts: when true (default), the ao-data-platform Helm chart is deployed by
    Terraform. Set to false to manage the Helm release separately — passwords are
    available as Kubernetes Secrets (synced by ESO) and in Secrets Manager.

    chart_registry: OCI registry URL for the ao-data-platform Helm chart (e.g.
    "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"). Required when
    deploy_charts = true.

    chart_version: version of the ao-data-platform chart to deploy (e.g. "1.3.0").
    Required when deploy_charts = true. This module expects chart_version >= "1.3.0"
    — the chart removed its OTel anti-affinity rule in favor of the dedicated
    ClickHouse node group this module creates (see clickhouse_node_group).
    Nothing in the module gates this at apply time; a 1.2.x caller will apply
    cleanly and hit the original scheduler deadlock at runtime.

    The clustered/HA Keeper topology (keeper_availability_zones) requires
    chart_version >= "2.3.0" — the first chart version exposing the keeper.*
    values; an older chart ignores them, leaving the keeper node groups empty.
    The converse also matters: on chart >= 2.3.0 Keeper is intrinsic and renders
    on every install, so bumping chart_version alone — without setting
    keeper_availability_zones — deploys the chart's default 3-voter Keeper
    ensemble onto the main node pool. Bump the chart version and set the
    topology variables together. The replicated table schema ships at chart
    3.0.0 — required before raising clickhouse_replica_count above 1 (see that
    variable for the full conditions).

    The module wires the chart's least-privilege ClickHouse user model
    (schema_owner / llm_worker / monte_carlo ExternalSecrets + otel.restrictGrants),
    which the chart consumes at version >= 2.0.0. It stays compatible with
    pre-2.0.0 charts during migration: the otel ExternalSecret is dual-wired at
    both the legacy (clickhouse.externalSecret) and 2.0.0 (clickhouse.otel.externalSecret)
    paths, and the per-user keys are simply ignored by older charts. The legacy
    otel path is transitional and removed once all chart-deployed cells are on
    >= 2.0.0.

    install_*: set false for any component already installed in the cluster to skip
    reinstalling it. Terraform will still create any dependent resources (e.g.
    ClusterSecretStore, ExternalSecret) but skip the Helm release itself.

    clickhouse.otel.restrict_grants forwards clickhouse.otel.restrictGrants to the
    chart. When true, the otel ingest user is restricted (via config grants) to
    INSERT on the telemetry source tables only; when false (default) otel keeps
    broad access. Requires chart version >= 2.0.0 (the flag is ignored by older
    charts). Intended to be flipped to true only after external readers have moved
    to the monte_carlo user.

    clickhouse.admin optionally provisions the gated break-glass superuser
    (`admin`). When { enabled = true }, the module creates its Secrets Manager
    secret + ExternalSecret pipeline and enables the chart's admin user (which
    stays loopback-only by default — reachable only via pod-exec). When disabled
    (the default), no admin secret is created and clickhouse_admin_credentials_secret_arn
    is null. Requires chart version >= 2.0.0. The password is supplied via
    var.clickhouse_passwords.admin (or auto-generated).

    clickhouse.readonly_user optionally provisions a second SELECT-only ClickHouse
    user (`readonly_user`, profile: readonly). When { enabled = true }, the module
    creates a Secrets Manager secret + ExternalSecret pipeline mirroring the otel
    user and forwards the toggle to the chart. Requires chart version >= 1.2.0.
    Leave null (or set enabled = false) to skip. The user's password is supplied
    via var.clickhouse_passwords.readonly_user (or auto-generated).

    llm_worker.bedrock_region overrides the AWS region the in-cluster LLM worker
    targets when calling Bedrock. Defaults to var.region; set explicitly when the
    cluster lives in a region without the desired Bedrock model availability.

    llm_worker.image_repository overrides the LLM-worker container image repo;
    defaults to deriving from chart_registry (same ECR account/region, repo
    "ao-llm-worker"). llm_worker.image_tag pins the image tag; defaults to
    "latest-aws". Pin to a released tag (e.g. "1.1.0-aws") for production.

    clickhouse.resources, opentelemetry_collector.resources, and llm_worker.resources
    are optional Kubernetes resource requests/limits passed through to the chart for
    each workload. Each accepts { requests = { ... }, limits = { ... } } with
    map-of-string values keyed by resource name (cpu, memory, ephemeral-storage, etc.).
    Omit to let the chart use its own defaults.

    opentelemetry_collector.replica_count and llm_worker.replica_count optionally
    override the replica count of those workloads (default null = the chart controls
    it). Because the collector and llm-worker share this release with ClickHouse, a
    plain `terraform apply` re-renders and would reset a manually-scaled Deployment.
    llm_worker.replica_count = 0 pauses the worker as config that survives an apply
    (set back to null/non-zero to resume). opentelemetry_collector.replica_count = 0
    is NOT honored by the chart: the module renders replicaCount = 0 into the values,
    but the chart's collector template treats 0 as unset and deploys its default
    count. To stop ingest for a maintenance window, act upstream of the collector
    instead — e.g. deny consumption on the SQS queues feeding the awss3 receivers, or
    pause OTLP senders. Non-zero collector overrides work as expected.

    opentelemetry_collector.awss3_receivers configures OTel Collector awss3
    receivers that ingest OTLP traces from S3 via SQS notifications — one map
    entry per SQS-queue/S3-bucket pair. Each entry renders a receiver with
    component ID "awss3/<key>" appended to the trace pipeline, and the module
    attaches an inline SQS + S3 read policy covering every enabled receiver to
    the otel-collector IRSA role. Per entry: enabled defaults to true (set
    false to keep the entry without rendering it); sqs_region and s3_region
    default to var.region; s3_prefix defaults to "" and is normalized
    internally to include a single trailing "/" when non-empty. Every receiver
    must consume its own dedicated SQS queue: in SQS mode a receiver deletes
    messages whose S3 records it filtered out (bucket/prefix mismatch), so
    receivers sharing a queue silently lose notifications — give each receiver
    its own dedicated queue; to feed several receivers from one bucket's
    events, fan the bucket's notifications out via SNS with a separate queue
    per receiver. The map key "trace-export-ingest" is reserved for enabled
    entries while var.trace_export_ingest is set — the module synthesizes that
    receiver for the trace-export ingest leg. A disabled entry under that key
    is dropped from the merge before rendering, so it is fine to keep (e.g. to
    stage a future receiver).

    opentelemetry_collector.awss3_receiver (singular) is the deprecated
    single-receiver form: use awss3_receivers instead. It continues to work
    throughout v2.x and renders identically to before — under the bare "awss3"
    component ID — and may be combined with awss3_receivers entries; it will
    only be removed in a future major version. Unlike map entries, its enabled
    flag is required. Leave null (or omit) to keep it disabled.
  EOT
  type = object({
    deploy_charts                        = optional(bool, true)
    chart_registry                       = optional(string, null)
    chart_version                        = optional(string, null)
    install_cert_manager                 = optional(bool, true)
    install_aws_load_balancer_controller = optional(bool, true)
    install_external_secrets_operator    = optional(bool, true)
    install_external_dns                 = optional(bool, true)

    clickhouse = optional(object({
      storage_size = optional(string, "500Gi")
      resources = optional(object({
        requests = optional(map(string), null)
        limits   = optional(map(string), null)
      }), null)
      otel = optional(object({
        restrict_grants = optional(bool, false)
      }), {})
      admin = optional(object({
        enabled = bool
      }), null)
      readonly_user = optional(object({
        enabled = bool
      }), null)
    }), {})

    opentelemetry_collector = optional(object({
      replica_count = optional(number, null)
      resources = optional(object({
        requests = optional(map(string), null)
        limits   = optional(map(string), null)
      }), null)
      awss3_receiver = optional(object({
        enabled       = bool
        sqs_queue_arn = string
        sqs_queue_url = string
        sqs_region    = optional(string, null)
        s3_bucket     = string
        s3_region     = optional(string, null)
        s3_prefix     = optional(string, "")
      }), null)
      awss3_receivers = optional(map(object({
        enabled       = optional(bool, true)
        sqs_queue_arn = string
        sqs_queue_url = string
        sqs_region    = optional(string, null)
        s3_bucket     = string
        s3_region     = optional(string, null)
        s3_prefix     = optional(string, "")
      })), {})
    }), {})

    llm_worker = optional(object({
      replica_count    = optional(number, null)
      bedrock_region   = optional(string, null)
      image_repository = optional(string, null)
      image_tag        = optional(string, "latest-aws")
      resources = optional(object({
        requests = optional(map(string), null)
        limits   = optional(map(string), null)
      }), null)
    }), {})
  })
  default = {}

  validation {
    condition     = !var.helm.deploy_charts || var.helm.chart_registry != null
    error_message = "helm.chart_registry is required when deploy_charts = true."
  }

  validation {
    condition     = var.helm.chart_registry == null || startswith(var.helm.chart_registry, "oci://")
    error_message = "helm.chart_registry must start with \"oci://\"."
  }

  validation {
    condition     = !var.helm.deploy_charts || var.helm.chart_version != null
    error_message = "helm.chart_version is required when deploy_charts = true."
  }

  validation {
    condition     = alltrue([for name, r in var.helm.opentelemetry_collector.awss3_receivers : can(regex("^[a-zA-Z0-9_-]+$", name))])
    error_message = "helm.opentelemetry_collector.awss3_receivers keys may only contain alphanumeric characters, hyphens, and underscores — each key becomes the OTel component ID \"awss3/<key>\" in the rendered collector config."
  }

  validation {
    condition = length(distinct(concat(
      try(var.helm.opentelemetry_collector.awss3_receiver.enabled, false) ? [var.helm.opentelemetry_collector.awss3_receiver.sqs_queue_arn] : [],
      [for r in values(var.helm.opentelemetry_collector.awss3_receivers) : r.sqs_queue_arn if r.enabled],
      ))) == length(concat(
      try(var.helm.opentelemetry_collector.awss3_receiver.enabled, false) ? [var.helm.opentelemetry_collector.awss3_receiver.sqs_queue_arn] : [],
      [for r in values(var.helm.opentelemetry_collector.awss3_receivers) : r.sqs_queue_arn if r.enabled],
    ))
    error_message = "Every enabled awss3 receiver (helm.opentelemetry_collector.awss3_receiver and awss3_receivers entries) must consume its own dedicated SQS queue — duplicate sqs_queue_arn values are rejected. In SQS mode each receiver deletes messages whose S3 records it filtered out, so receivers sharing a queue silently lose notifications."
  }
}

# --- Trace Export Ingest ---

variable "trace_export_ingest" {
  description = <<-EOT
    Optional trace-export ingest leg. When set, the module provisions the
    resources an external trace producer needs to deliver OTLP trace files
    into this deployment's collector: a dedicated S3 ingest bucket with a
    short object lifecycle, an SQS queue wired to the bucket's object-created
    notifications, an awss3 receiver consuming that queue, and a writer IAM
    role an external execution role can assume (external-ID guarded) to
    upload trace files. Leave null (the default) to create none of this —
    unset, the module plans identically to previous releases.

    producer_execution_role_arn is the external execution role trusted to assume
    the writer role. It accepts an exact role ARN or a wildcard pattern in
    the role-NAME portion only (e.g. "arn:aws:iam::123456789012:role/etl-*")
    so the external role can be re-provisioned without re-applying this
    module. The account ID must be literal — it anchors the trust policy's
    principal — and the pattern is the effective principal boundary within
    that account, so keep it as narrow as possible.

    The writer role's trust policy also carries an sts:ExternalId condition
    (confused-deputy guard), supplied separately via the sensitive
    trace_export_external_id variable — required whenever this block is set.

    agent_role_arn optionally grants one additional role s3:PutObject on the
    ingest prefix via the bucket policy — for producers that write directly
    instead of assuming the writer role. It must be a well-formed IAM role
    ARN with a literal 12-digit account ID; unlike producer_execution_role_arn
    it is embedded verbatim as a bucket-policy Principal rather than matched
    via a trust-policy condition, so no wildcards are permitted anywhere in
    the ARN.

    bucket_name overrides the default ingest bucket name,
    "<cluster-name>-<region>-trace-export-ingest-<account-id>". It must name a
    bucket that does NOT already exist: the module always creates and owns this
    bucket (force_destroy — it holds transit data). Pointing bucket_name at a
    pre-existing bucket adopts that bucket into this module's state — its
    bucket policy and event-notification configuration are REPLACED with the
    module's own, and a later teardown or unset of trace_export_ingest
    deletes its contents.

    S3 caps bucket names at 63 characters. The default spends the region, the
    fixed "-trace-export-ingest-" segment, and the 12-digit account ID on top of
    the cluster name — roughly 43 characters in us-east-1, more in longer region
    names — leaving about 20 characters for the cluster name (fewer still in a
    long region). A cluster name that overflows this trips the name-format
    precondition at plan time, which names bucket_name as the escape hatch.

    prefix (default "traces/") is the key prefix the producer writes under;
    the receiver, lifecycle rule, notification filter, and IAM grants are all
    scoped to it. Multi-segment prefixes ("traces/tenant-a/") are supported.

    lifecycle_days (default 3) expires objects under the prefix and aborts
    incomplete multipart uploads at the same age — the bucket is transit,
    not storage.

    kms_key_arn optionally encrypts the bucket with a customer-managed KMS
    key (SSE-KMS with S3 Bucket Keys) instead of the default SSE-S3, and
    widens the writer and collector policies with the matching KMS
    permissions. Those are identity-policy grants on same-account roles, so
    they take effect only if the CMK's key policy delegates to the account;
    a tightened key policy must name the collector IRSA role and the writer
    role explicitly. Cross-account KMS access cannot be granted from here, so
    when agent_role_arn is also set the key policy must itself grant that
    role kms:GenerateDataKey/kms:Encrypt or its SSE-KMS PUTs fail.
  EOT
  type = object({
    producer_execution_role_arn = string
    agent_role_arn              = optional(string, null)
    bucket_name                 = optional(string, null)
    prefix                      = optional(string, "traces/")
    lifecycle_days              = optional(number, 3)
    kms_key_arn                 = optional(string, null)
  })
  default = null

  validation {
    condition = var.trace_export_ingest == null ? true : (
      can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:role/.+$", var.trace_export_ingest.producer_execution_role_arn)) &&
      length(replace(replace(replace(element(split(":role/", var.trace_export_ingest.producer_execution_role_arn), 1), "*", ""), "?", ""), "/", "")) > 0
    )
    error_message = "trace_export_ingest.producer_execution_role_arn must be an IAM role ARN with a literal 12-digit account ID (\"arn:<partition>:iam::<account-id>:role/<name>\"). Wildcards (\"*\" and \"?\") are allowed only in the role-name portion, and the name must not consist of wildcards alone — this pattern is the effective principal boundary of the writer role's trust policy."
  }

  validation {
    condition = var.trace_export_ingest == null || var.trace_export_ingest.agent_role_arn == null ? true : (
      can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:role/.+$", var.trace_export_ingest.agent_role_arn)) &&
      length(replace(replace(element(split(":role/", var.trace_export_ingest.agent_role_arn), 1), "*", ""), "/", "")) > 0 &&
      !can(regex("\\*", var.trace_export_ingest.agent_role_arn))
    )
    error_message = "trace_export_ingest.agent_role_arn must be an exact IAM role ARN with a literal 12-digit account ID (\"arn:<partition>:iam::<account-id>:role/<name>\"). Unlike producer_execution_role_arn, which is matched via a StringLike trust-policy condition, this value is embedded verbatim as the ingest bucket policy's Principal — IAM does not glob-match wildcards there, so no wildcards are permitted anywhere in this ARN."
  }

  validation {
    condition     = var.trace_export_ingest == null ? true : can(regex("^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*/?$", var.trace_export_ingest.prefix))
    error_message = "trace_export_ingest.prefix must be one or more \"/\"-separated segments of [a-zA-Z0-9_.-] characters with no leading \"/\" and no empty segments (e.g. \"traces/\" or \"traces/tenant-a/\"); a single trailing \"/\" is optional and normalized internally."
  }

  validation {
    condition     = var.trace_export_ingest == null ? true : var.trace_export_ingest.lifecycle_days >= 1
    error_message = "trace_export_ingest.lifecycle_days must be at least 1."
  }
}

variable "trace_export_external_id" {
  description = <<-EOT
    The sts:ExternalId condition value baked into the trace-export writer
    role's trust policy (confused-deputy guard). Required when
    trace_export_ingest is set; leave null (default) otherwise. Supply the
    value issued by the system driving the export; minimum length 8.

    Marked sensitive, so it is redacted from plan/apply output and CI logs.
    Supply via a .tfvars file or TF_VAR_trace_export_external_id rather than
    -var on a command line. Terraform state still contains the value —
    protect state accordingly. It is echoed back via the sensitive
    trace_export_external_id output.
  EOT
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.trace_export_external_id == null ? true : length(var.trace_export_external_id) >= 8
    error_message = "trace_export_external_id must be at least 8 characters long."
  }
}

# --- ClickHouse Credentials ---

variable "clickhouse_passwords" {
  description = <<-EOT
    Passwords for the ClickHouse SQL users. Every field is optional — any
    password left null is auto-generated. Supplied or generated, each password
    is stored in Secrets Manager and synced into the cluster by the External
    Secrets Operator; passwords never pass through Helm values.

    Marked ephemeral and sensitive: values are omitted from Terraform state and
    plan files entirely, and redacted in plan/apply output and CI logs. Supply
    via a .tfvars file or TF_VAR_clickhouse_passwords rather than -var on a
    command line. Ephemeral variables accept ordinary values, so existing
    callers need no change.

    Note the provider still reads the secret during plan/refresh (aws provider
    issue #42383), so plan-time IAM is unchanged — write-only removes the value
    from state and plan files, not from the provider's in-memory plan path.

    admin is only used when helm.clickhouse.admin.enabled = true, and
    readonly_user only when helm.clickhouse.readonly_user.enabled = true.
  EOT
  type = object({
    admin         = optional(string, null)
    otel          = optional(string, null)
    monte_carlo   = optional(string, null)
    schema_owner  = optional(string, null)
    llm_worker    = optional(string, null)
    readonly_user = optional(string, null)
  })
  default   = {}
  sensitive = true
  ephemeral = true
}

variable "clickhouse_password_versions" {
  description = <<-EOT
    Version counter per ClickHouse user, driving each secret's
    secret_string_wo_version. Because the password is a write-only argument,
    Terraform cannot detect drift on it — the secret is rewritten ONLY when the
    matching version here changes. This is the rotation lever.

    Bump one field to rotate one user (e.g. admin after a break-glass use);
    bump all six to rotate the deployment. Bumping a field WITHOUT supplying the
    matching clickhouse_passwords value writes a freshly generated password.

    Leave at the default of 1 for a fresh install and for the write-only
    migration — see "Migrating to v3.0.0" in this README.
  EOT
  type = object({
    admin         = optional(number, 1)
    otel          = optional(number, 1)
    monte_carlo   = optional(number, 1)
    schema_owner  = optional(number, 1)
    llm_worker    = optional(number, 1)
    readonly_user = optional(number, 1)
  })
  default = {}
}

# --- Storage ---

variable "clickhouse_storage_class" {
  description = <<-EOT
    Name of the Kubernetes StorageClass the ClickHouse StatefulSet requests.

    Defaults to "clickhouse-gp3" — the dedicated StorageClass this module
    creates (gp3, reclaimPolicy=Retain, tuned via storage_class_clickhouse_gp3).
    New deployments get Retain + tuned IOPS from the first apply.

    Set to "gp3" for a deployment that ALREADY provisioned ClickHouse on the
    shared "gp3" class: a StatefulSet's volumeClaimTemplates are immutable, so
    flipping storageClassName on a live StatefulSet is rejected by the
    Kubernetes API and fails the Helm upgrade. Such deployments must stay on
    the class they were first created with.

    May also be set to any StorageClass managed out-of-band (the module does
    not create it; it must exist in the cluster before the ClickHouse PVC is
    provisioned, or the PVC stays Pending).
  EOT
  type        = string
  default     = "clickhouse-gp3"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.clickhouse_storage_class))
    error_message = "clickhouse_storage_class must be a valid Kubernetes StorageClass name (lowercase alphanumeric, '-' and '.', starting and ending alphanumeric)."
  }
}

variable "storage_class_clickhouse_gp3" {
  description = <<-EOT
    Parameters for the dedicated "clickhouse-gp3" StorageClass this module
    creates. These configure that StorageClass only — the cluster's shared
    "gp3" class is never modified.

    iops / throughput size the gp3 volumes provisioned from clickhouse-gp3.
    They default to the AWS gp3 baseline (3000 IOPS / 125 MB/s) — raise per
    measured ClickHouse merge load. Note: iops/throughput are set at volume
    creation time, so changing them here only affects newly provisioned
    volumes; existing volumes are resized in place via EBS Elastic Volumes
    (aws ec2 modify-volume), separate from this module.
  EOT
  type = object({
    iops       = optional(number, 3000)
    throughput = optional(number, 125)
  })
  default = {}

  validation {
    condition     = var.storage_class_clickhouse_gp3.iops >= 3000 && var.storage_class_clickhouse_gp3.iops <= 16000
    error_message = "storage_class_clickhouse_gp3.iops must be between 3000 and 16000 (the gp3 provisioned-IOPS range)."
  }

  validation {
    condition     = var.storage_class_clickhouse_gp3.throughput >= 125 && var.storage_class_clickhouse_gp3.throughput <= 1000
    error_message = "storage_class_clickhouse_gp3.throughput must be between 125 and 1000 MB/s (the gp3 throughput range)."
  }

  validation {
    condition     = var.storage_class_clickhouse_gp3.throughput <= var.storage_class_clickhouse_gp3.iops * 0.25
    error_message = "storage_class_clickhouse_gp3.throughput (MB/s) may not exceed 0.25 x iops (the gp3 throughput-to-IOPS ratio limit) — e.g. 1000 MB/s requires >= 4000 IOPS."
  }
}
