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
    cluster.create = true. When that pair holds, the module creates a
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

# --- Networking ---

variable "networking" {
  description = <<-EOT
    VPC and networking configuration.

    When create_vpc = true, a new VPC with public and private subnets is created.
    When create_vpc = false, provide existing_vpc_id and existing_private_subnet_ids.
    At least two private subnets in different AZs are required for the managed node group.
  EOT
  type = object({
    create_vpc                  = optional(bool, true)
    vpc_cidr                    = optional(string, "10.18.0.0/16")
    private_subnet_cidrs        = optional(list(string), ["10.18.1.0/24", "10.18.2.0/24", "10.18.3.0/24"])
    public_subnet_cidrs         = optional(list(string), ["10.18.4.0/24", "10.18.5.0/24", "10.18.6.0/24"])
    existing_vpc_id             = optional(string, null)
    existing_private_subnet_ids = optional(list(string), [])
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
    "ao-llm-worker"). llm_worker.image_tag pins the image tag; defaults to "latest".

    clickhouse.resources, opentelemetry_collector.resources, and llm_worker.resources
    are optional Kubernetes resource requests/limits passed through to the chart for
    each workload. Each accepts { requests = { ... }, limits = { ... } } with
    map-of-string values keyed by resource name (cpu, memory, ephemeral-storage, etc.).
    Omit to let the chart use its own defaults.

    opentelemetry_collector.awss3_receiver optionally enables the OTel Collector's
    awss3 receiver to ingest OTLP traces from S3 via SQS notifications. When set
    with enabled = true, the module overrides the chart's awss3 receiver config
    with the supplied SQS/S3 values, appends "awss3" to the trace pipeline, and
    attaches an inline SQS + S3 read policy to the otel-collector IRSA role.
    sqs_region and s3_region default to var.region; s3_prefix defaults to ""
    and is normalized internally to include a single trailing "/" when non-empty.
    Leave null (or omit) to keep the receiver disabled.
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
    }), {})

    llm_worker = optional(object({
      bedrock_region   = optional(string, null)
      image_repository = optional(string, null)
      image_tag        = optional(string, "latest")
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
}

# --- ClickHouse Credentials ---

variable "clickhouse_passwords" {
  description = <<-EOT
    Passwords for the ClickHouse SQL users. Every field is optional — any
    password left null is auto-generated. Supplied or generated, each password
    is stored in Secrets Manager and synced into the cluster by the External
    Secrets Operator; passwords never pass through Helm values.

    The variable is marked sensitive, so caller-supplied values are redacted
    in plan/apply output and CI logs. Supply via a .tfvars file or
    TF_VAR_clickhouse_passwords rather than -var on a command line. Note that
    Terraform state still contains the values — protect state accordingly.

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
