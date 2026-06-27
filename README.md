# terraform-aws-ao-data-platform

Terraform module that deploys the Monte Carlo Agent Observability data platform on AWS. Provisions a full pipeline from OTel Collector through to ClickHouse on EKS, ready for the MC Agent to connect to.

**What gets deployed:**
- EKS cluster + VPC (or targets an existing cluster)
- ClickHouse (via `ao-data-platform` Helm chart)
- OTel Collector (via `ao-data-platform` Helm chart)
- Cluster controllers: AWS Load Balancer Controller, cert-manager, External Secrets Operator, external-dns
- ACM certificates, Route 53 records, IAM/IRSA roles, Secrets Manager secrets

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.3
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for cluster access

> **Note:** `terraform apply` runs `local-exec` provisioners that invoke `aws eks update-kubeconfig` (needed to `kubectl wait` for ESO CRDs and apply the ClusterSecretStore). This modifies the `~/.kube/config` of the machine running Terraform: the cluster's context is added (or refreshed) and becomes the current context.

## Usage

The `kubernetes` and `helm` providers must be configured in your root module using this module's outputs. This enables a single-pass `terraform apply` — Terraform automatically defers Kubernetes/Helm resources until after the EKS cluster is provisioned.

> **Note:** Pin the `helm` provider to `~> 2.0`. The examples below use its v2 configuration syntax (the nested `kubernetes { ... }` block); helm provider v3 changed this to a top-level `kubernetes` argument and is not yet supported.

### Full deployment (new VPC + new cluster)

```hcl
terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "kubernetes" {
  host                   = module.ao_data_platform.eks_cluster_endpoint
  cluster_ca_certificate = module.ao_data_platform.eks_cluster_ca_certificate
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.ao_data_platform.eks_cluster_name, "--region", "us-east-1"]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.ao_data_platform.eks_cluster_endpoint
    cluster_ca_certificate = module.ao_data_platform.eks_cluster_ca_certificate
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.ao_data_platform.eks_cluster_name, "--region", "us-east-1"]
    }
  }
}

module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 1.0"

  region                = "us-east-1"
  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"
  hosted_zone_id        = "Z1234567890ABC"

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "1.5.0"
  }
}
```

See [`examples/new_cluster/`](examples/new_cluster/) for a complete copy-paste starting point.

### Existing cluster

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 1.0"

  region = "us-east-1"

  cluster = {
    create                = false
    existing_cluster_name = "my-cluster"
  }

  networking = {
    create_vpc                  = false
    existing_vpc_id             = "vpc-0abc123"
    existing_private_subnet_ids = ["subnet-aaa", "subnet-bbb"]
  }

  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"
  hosted_zone_id        = "Z1234567890ABC"

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "1.5.0"
  }
}
```

See [`examples/existing_cluster/`](examples/existing_cluster/) for the full configuration including provider setup.

### Infrastructure only (manage Helm separately)

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 1.0"

  region = "us-east-1"

  helm = {
    deploy_charts = false
  }
}
```

When `deploy_charts = false`, Terraform provisions all AWS infrastructure and installs cluster controllers but does not deploy the `ao-data-platform` chart. Run `helm install ao-data-platform` separately using the module outputs to configure chart values.

### Restricting the EKS API endpoint

By default a new cluster's API server is reachable on its public endpoint from anywhere (`0.0.0.0/0`), matching the EKS default. The private endpoint is always enabled. Two `cluster` fields harden this:

```hcl
cluster = {
  # Allow only specific source ranges on the public endpoint…
  endpoint_public_access_cidrs = ["203.0.113.0/24"]

  # …or disable the public endpoint entirely (private-only control plane).
  endpoint_public_access = false
}
```

**Before restricting, account for every machine that talks to the API server** — not just operator laptops. `terraform apply` itself needs the API: the `kubernetes`/`helm` providers and this module's `local-exec` provisioners (`aws eks update-kubeconfig` + `kubectl`) all connect to it. That includes CI:

- With `endpoint_public_access_cidrs`, include the egress CIDRs of your CI runners. Hosted runners without stable egress IPs (e.g. default cloud CI fleets) cannot be allow-listed this way and will lose access mid-pipeline.
- With `endpoint_public_access = false`, every apply and `kubectl` invocation must reach the API over a private path: VPN, VPC peering, Transit Gateway, or a runner inside the VPC.

Both fields only apply when `cluster.create = true`. Changes apply in place — restricting (or re-opening) the endpoint does not recreate the cluster.

### Tuning workload resources

Each managed workload (ClickHouse, OTel Collector, LLM worker) exposes optional Kubernetes resource requests/limits via `helm.<workload>.resources`. Omit a workload (or its `resources` field) to fall back to the chart's own defaults — start modest in dev, tune up for prod.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 1.0"

  region                = "us-east-1"
  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"
  hosted_zone_id        = "Z1234567890ABC"

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "1.5.0"

    clickhouse = {
      resources = {
        requests = { cpu = "2", memory = "8Gi" }
        limits   = { cpu = "4", memory = "16Gi" }
      }
    }
    opentelemetry_collector = {
      resources = {
        requests = { memory = "2Gi" }
        limits   = { memory = "6Gi" }
      }
    }
    llm_worker = {
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { cpu = "2", memory = "4Gi" }
      }
    }
  }
}
```

`requests` and `limits` are maps keyed by Kubernetes resource name, so any name the chart accepts works (`cpu`, `memory`, `ephemeral-storage`, hugepages, GPUs, etc.). Either map can be omitted independently.

### AWS S3 receiver for the OTel Collector

Set `helm.opentelemetry_collector.awss3_receiver` to have the OTel Collector ingest OTLP traces from objects in an S3 bucket, notified via an SQS queue. When `enabled = true`, the module:

- Overrides the chart's `awss3` receiver block with the supplied SQS URL/region and S3 bucket/region/prefix, and appends `awss3` to the trace pipeline so the receiver is actually wired up.
- Attaches an inline policy to the `otel-collector` IRSA role granting `sqs:ReceiveMessage`/`DeleteMessage`/`GetQueueAttributes`/`GetQueueUrl` on the queue and `s3:GetObject`/`GetBucketLocation` on the bucket.

`sqs_region` and `s3_region` default to `var.region` when omitted; `s3_prefix` defaults to `""` (any object in the bucket) and is normalized internally to include a single trailing `/` when non-empty (so `"traces"` and `"traces/"` behave identically). Leave `awss3_receiver` unset (or `null`) to keep the receiver disabled — existing deployments are unaffected.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 1.0"

  region                = "us-east-1"
  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"
  hosted_zone_id        = "Z1234567890ABC"

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "1.5.0"

    opentelemetry_collector = {
      awss3_receiver = {
        enabled       = true
        sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:otel-traces"
        sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/otel-traces"
        s3_bucket     = "acme-otel-traces"
        # sqs_region / s3_region default to var.region
        # s3_prefix defaults to ""
      }
    }
  }
}
```

### Read-only ClickHouse user

Set `helm.clickhouse.readonly_user = { enabled = true }` to provision a SELECT-only ClickHouse user — SQL username `readonly_user`, `profile: readonly`. When `enabled = true`, the module:

- Generates a 32-character random password (or uses a caller-supplied `clickhouse_passwords.readonly_user` instead) and stores it in Secrets Manager at `<cluster_name>/clickhouse/readonly-user-credentials`, KMS-encrypted with the existing pipeline key.
- Extends the External Secrets Operator IRSA policy so ESO can read the new secret.
- Forwards `clickhouse.readonlyUser.{enabled, externalSecret.*}` into the `ao-data-platform` chart values; the chart provisions the SQL user and a second ExternalSecret that syncs the password from Secrets Manager into K8s.

The provisioned secret ARN is exposed as `clickhouse_readonly_user_credentials_secret_arn`.

**Requires `ao-data-platform` chart >= 1.2.0.** Older chart versions silently ignore the `clickhouse.readonlyUser` values key — the Secrets Manager secret is created by terraform, but no SQL user is provisioned by the chart. Pin `helm.chart_version` accordingly when enabling.

Leave `helm.clickhouse.readonly_user` unset (or `null`) to disable; existing consumers are unaffected.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 1.0"

  region                = "us-east-1"
  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"
  hosted_zone_id        = "Z1234567890ABC"

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "1.5.0"

    clickhouse = {
      readonly_user = {
        enabled = true
      }
    }
  }

  # Optional; omit to auto-generate the password.
  # clickhouse_passwords = { readonly_user = "..." }
}
```

### Dedicated ClickHouse node group

The module auto-creates a dedicated single-AZ EKS managed node group for ClickHouse whenever `helm.deploy_charts = true` and `cluster.create = true`. No explicit toggle. This module expects `helm.chart_version >= "1.3.0"` — older chart versions bundle their own OTel/CH anti-affinity rule and structurally don't use the dedicated NG. Nothing in the module gates this at apply time; a 1.2.x caller will apply cleanly and hit the original scheduler deadlock at runtime. When both conditions hold, the module:

- Creates a second managed node group (one node, single-AZ) pinned to `var.clickhouse_node_group.availability_zone` (or, when null, the first AZ from `data.aws_availability_zones.available`).
- Applies a `dedicated=clickhouse:NoSchedule` taint to the node group so only pods that tolerate it can land there.
- Automatically sets `clickhouse.nodeSelector` and `clickhouse.tolerations` on the helm release so the ClickHouse pod targets the dedicated node exclusively. No manual helm-values plumbing required.
- Leaves the main node group at its default size of 2. The stateless tier (OTel, llm-worker, controllers) still benefits from a 2-node HA floor even after CH moves to the dedicated NG — node-drain operations on the main pool then have somewhere to spill the stateless workloads. Set `cluster.main_node_group_size = 1` explicitly to opt into a single-node main pool when HA isn't a requirement.

This pattern enforces scheduling separation between ClickHouse and the controllers that previously competed for its node (OTel collector, llm-worker, and other Deployment workloads run on the main node group). DaemonSets (kube-proxy, aws-node, ebs-csi-node, etc.) continue to co-locate with ClickHouse on the dedicated node by design — they tolerate the taint and are required wherever a node exists. The OTel-vs-ClickHouse pod anti-affinity rule was removed from the `ao-data-platform` chart in 1.3.0 in favor of this stronger structural separation — the anti-affinity approach was vulnerable to scheduler deadlocks when the cluster topology forced the only viable node for ClickHouse to be occupied by OTel first.

**EBS volumes are AZ-locked.** The dedicated NG MUST live in the same AZ as the existing ClickHouse PV, or the CH pod can't schedule on it. The module defaults to the region's first AZ alphabetically; verify the `clickhouse_node_group.availability_zone` output during plan/apply review, and override `var.clickhouse_node_group.availability_zone` if needed.

**Upgrade impact from chart < 1.3.0.** Bumping `helm.chart_version` from a 1.2.x release to `>= "1.3.0"` enables this module's dedicated CH NG behavior — the apply creates the dedicated CH NG alongside the existing main NG (main NG stays at its default size of 2; total cluster grows by one node). To opt into a cost-shrunk single-node main pool instead, set `cluster.main_node_group_size = 1` explicitly. **For existing deployments with ClickHouse data to preserve:** set `clickhouse_node_group.availability_zone` to the existing CH PV's AZ before applying, so the dedicated NG lands in the same AZ and the StatefulSet re-attaches the existing EBS volume in place. EBS volumes are AZ-locked and cannot follow the StatefulSet — if the resolved dedicated-NG AZ doesn't match the PV's AZ, the CH pod stays `Pending` and the only forward path is deleting the PVC out-of-band (re-ingest required).

**Operational note — single-replica ClickHouse on a 1-node NG has no HA.** The CH StatefulSet runs as a single replica on the dedicated single-AZ node, with no surge headroom (a maxSurge replica can't land on a different node since the EBS PV is AZ-locked, and the dedicated NG has only one node). The chart's PodDisruptionBudget (`minAvailable: 1`) blocks voluntary `kubectl drain` evictions, but doesn't help during node replacement (EKS AMI rolls bypass PDBs after a grace period; the only replica is evicted with no replacement available). Node-drain operations — including routine EKS AMI rolls of the dedicated NG, node-group resizing, or manual draining — therefore incur ClickHouse downtime for the duration of the pod restart (~30-90s on a healthy node). This is a documented limitation of the single-AZ, single-replica design. Hardening beyond it (CH replication via the operator, or multi-replica with shared storage) is out of scope for this module.

For existing clusters (`cluster.create = false`), the module does not manage the dedicated NG — attach a tainted (`dedicated=clickhouse:NoSchedule`) single-AZ node group to the cluster out-of-band, and pass matching `clickhouse.nodeSelector` + `clickhouse.tolerations` to the chart's ClickHouse pod template via your own helm release values. The `clickhouse_node_group` variable has no effect on this path.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 1.0"

  region                = "us-east-1"
  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"
  hosted_zone_id        = "Z1234567890ABC"

  # Optional — set when the existing CH PV is not in the region's first AZ.
  # When omitted, defaults to data.aws_availability_zones.available.names[0].
  clickhouse_node_group = {
    availability_zone = "us-east-1b"
  }

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "1.5.0"
  }
}
```

### ClickHouse storage class

This module creates two cluster-scoped StorageClasses: a general-purpose `gp3` (the module's baseline EBS class — EKS clusters ship only `gp2` by default) and a dedicated `clickhouse-gp3`. The ClickHouse StatefulSet uses `clickhouse-gp3` by default (`clickhouse_storage_class`). `clickhouse-gp3` is a `gp3` class hardened for stateful data in two ways:

- **`reclaimPolicy: Retain`** — deleting the ClickHouse PVC leaves the backing EBS volume intact, so data survives an accidental claim deletion (the volume must then be cleaned up or re-attached manually).
- **Explicit, tunable IOPS/throughput** via `storage_class_clickhouse_gp3` — defaults to the `gp3` baseline (3000 IOPS / 125 MB/s); raise per measured ClickHouse merge load (valid ranges: IOPS 3000–16000, throughput 125–1000 MB/s, with throughput ≤ 0.25 × IOPS). These apply at volume-creation time, so a change only affects **newly provisioned** volumes; resize an existing volume in place with AWS EBS Elastic Volumes (`aws ec2 modify-volume`).

The `storage_class_clickhouse_gp3` settings tune **only** `clickhouse-gp3`; the general-purpose `gp3` class is always created at the AWS baseline and is never altered by them. (This is also why the ClickHouse hardening lives in a separate class instead of being applied to `gp3`: a StorageClass's parameters are immutable in Kubernetes, so changing `gp3` in place would force a disruptive replacement.)

**Existing deployments already running ClickHouse on `gp3`:** set `clickhouse_storage_class = "gp3"` to keep using it. A StatefulSet's `volumeClaimTemplates.storageClassName` is immutable, so switching a live ClickHouse StatefulSet to a different class is rejected by the Kubernetes API and fails the Helm upgrade (non-destructive — ClickHouse keeps running on its existing volume). To gain `Retain` protection on an already-provisioned volume without a StatefulSet rebuild, patch the live PV directly (this field *is* mutable):

```bash
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

To use a StorageClass you manage outside this module, set `clickhouse_storage_class` to its name (the module will not create it — it must already exist in the cluster, or the ClickHouse PVC stays `Pending`).

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `region` | `string` | required | AWS region to deploy into |
| `tags` | `map(string)` | `{}` | Tags applied to every taggable AWS resource the module creates and propagated to the VPC/EKS child modules. Non-taggable resources (KMS alias, Route 53 records, inline IAM policies, Kubernetes/Helm) carry no tags. Provider `default_tags` also apply and stack with these. |
| `cluster.create` | `bool` | `true` | Create a new EKS cluster (`true`) or target an existing one (`false`) |
| `cluster.name` | `string` | `"monte-carlo"` | Name of the cluster to create |
| `cluster.existing_cluster_name` | `string` | `null` | Required when `cluster.create = false` |
| `cluster.node_instance_type` | `string` | `"t3.large"` | EC2 instance type for the main managed node group |
| `cluster.endpoint_public_access` | `bool` | `true` | Whether the EKS API server keeps its public endpoint. The private endpoint is always enabled. Set `false` for a private-only control plane — every machine running Terraform/kubectl (CI included) must then reach the API over a private path. See "Restricting the EKS API endpoint". Only applies when `cluster.create = true`. |
| `cluster.endpoint_public_access_cidrs` | `list(string)` | `["0.0.0.0/0"]` | CIDR blocks allowed to reach the public API endpoint. Include the egress CIDRs of every machine that runs Terraform or kubectl against the cluster. See "Restricting the EKS API endpoint". Only applies when `cluster.create = true`. |
| `cluster.main_node_group_size` | `number` | `null` (resolves to 2) | Optional explicit size (desired + min) for the main EKS managed node group. When `null` (default), resolves to `2` — keeps a 2-node HA floor on the stateless tier even when the dedicated CH NG is active. Set explicitly to `1` to opt into a cost-shrunk single-node main pool. Validated to the range `[1, 10]` when set; `max_size` stays at 10 for autoscaling burst. |
| `clickhouse_node_group` | `object` | `{}` (all defaults) | Configuration for the dedicated single-AZ ClickHouse node group. Shape: `{ availability_zone = optional(string), instance_type = optional(string, "r5.xlarge"), use_latest_ami_release_version = optional(bool, false), ami_release_version = optional(string) }`. The dedicated NG is auto-created when `helm.deploy_charts = true` AND `cluster.create = true` — see the "Dedicated ClickHouse node group" section. `availability_zone`: when null, defaults to the first AZ from `data.aws_availability_zones.available` (alphabetical) — override when the ClickHouse PV is in a different AZ (EBS volumes are AZ-locked). `instance_type`: EC2 instance type for the dedicated node; defaults to `r5.xlarge`. `use_latest_ami_release_version`: defaults to `false` — the CH NG is no-drift pinned, so its AMI won't change on an unrelated apply (see "ClickHouse node group AMI"). `ami_release_version`: optional explicit AMI build to pin to (e.g. `"1.35.5-20260527"`); `null` (default) still prevents drift but records no specific build. Has no effect when `cluster.create = false`. |
| `networking.create_vpc` | `bool` | `true` | Create a new VPC or use an existing one |
| `networking.vpc_cidr` | `string` | `"10.18.0.0/16"` | CIDR block for the created VPC. The default is a placeholder meant to be overridden — pick a range that doesn't collide with your existing networks (peering or VPN into a colliding range is painful to retrofit). Only applies when `create_vpc = true` |
| `networking.private_subnet_cidrs` | `list(string)` | `["10.18.1.0/24", "10.18.2.0/24", "10.18.3.0/24"]` | Private subnet CIDRs for the created VPC; must sit inside `vpc_cidr`. Override together with it |
| `networking.public_subnet_cidrs` | `list(string)` | `["10.18.4.0/24", "10.18.5.0/24", "10.18.6.0/24"]` | Public subnet CIDRs for the created VPC; must sit inside `vpc_cidr`. Override together with it |
| `networking.existing_vpc_id` | `string` | `null` | Required when `create_vpc = false` |
| `networking.existing_private_subnet_ids` | `list(string)` | `[]` | Required when `create_vpc = false` (min 2 subnets in different AZs) |
| `otel_collector_domain` | `string` | `null` | Domain for the OTel Collector HTTPS NLB endpoint |
| `clickhouse_domain` | `string` | `null` | Domain for the ClickHouse TCP+TLS NLB endpoint |
| `clickhouse_nlb_allowed_source_ranges` | `list(string)` | `null` | CIDR ranges permitted to reach the internal ClickHouse NLB. `null` (default) = no restriction (any source that can reach the NLB); `[]` = restricted to the VPC CIDR block(s) only; `["x.x.x.x/n", …]` = VPC CIDR block(s) **plus** the listed ranges. The VPC CIDR is always folded in when a restriction is in effect, so enabling one never locks out in-VPC clients. Enforced via the AWS Load Balancer Controller `load-balancer-source-ranges` annotation. The NLB is internal-scheme, so a listed range is only reachable if a private network path into the VPC already exists (VPN, peering, Transit Gateway, subnet router); adding a CIDR does not by itself create reachability. |
| `otel_collector_nlb_allowed_source_ranges` | `list(string)` | `null` | CIDR ranges permitted to reach the internal OTel Collector NLB. Same semantics as `clickhouse_nlb_allowed_source_ranges` (`null` = no restriction, `[]` = VPC-only, list = VPC + listed ranges). |
| `hosted_zone_id` | `string` | `null` | Route 53 hosted zone ID; enables automatic DNS and cert-manager/external-dns IRSA roles |
| `clickhouse_ttl_days` | `number` | `30` | ClickHouse data retention TTL in days |
| `clickhouse_storage_class` | `string` | `"clickhouse-gp3"` | Name of the StorageClass the ClickHouse StatefulSet requests. Defaults to `clickhouse-gp3` (the dedicated `Retain` class this module creates). Set to `"gp3"` for a deployment that already provisioned ClickHouse on the shared `gp3` class — a StatefulSet's `storageClassName` is immutable, so an existing deployment must stay on its original class. May also name any StorageClass managed out-of-band (the module will not create it). See "ClickHouse storage class". |
| `storage_class_clickhouse_gp3` | `object` | `{}` (all defaults) | Parameters for the dedicated `clickhouse-gp3` StorageClass this module creates (never modifies the shared `gp3` class). Shape: `{ iops = optional(number, 3000), throughput = optional(number, 125) }`. Defaults to the `gp3` baseline; raise per measured ClickHouse merge load. Validated to `gp3` limits (IOPS 3000–16000, throughput 125–1000 MB/s, throughput ≤ 0.25 × IOPS). Applies only to newly provisioned volumes. |
| `helm.deploy_charts` | `bool` | `true` | Deploy the `ao-data-platform` chart from Terraform |
| `helm.chart_registry` | `string` | `null` | OCI registry URL for the `ao-data-platform` chart (e.g. `oci://123456789012.dkr.ecr.us-east-1.amazonaws.com`). Required when `deploy_charts = true`. |
| `helm.chart_version` | `string` | `null` | Version of the `ao-data-platform` chart to deploy. Required when `deploy_charts = true`. |
| `helm.install_aws_load_balancer_controller` | `bool` | `true` | Skip if LBC is already installed in the cluster |
| `helm.install_cert_manager` | `bool` | `true` | Skip if cert-manager is already installed |
| `helm.install_external_secrets_operator` | `bool` | `true` | Skip if ESO is already installed |
| `helm.install_external_dns` | `bool` | `true` | Skip if external-dns is already installed |
| `helm.llm_worker.bedrock_region` | `string` | `null` | AWS region the in-cluster LLM worker targets for Bedrock; defaults to `var.region` when unset |
| `helm.llm_worker.image_repository` | `string` | `null` | LLM-worker container image repo override. Defaults to deriving from `chart_registry` (same ECR account/region, repo `ao-llm-worker`). |
| `helm.llm_worker.image_tag` | `string` | `"latest"` | LLM-worker container image tag. |
| `helm.clickhouse.resources` | `object` | `null` | Kubernetes resource requests/limits for the ClickHouse pods. Shape: `{ requests = map(string), limits = map(string) }`. Omit to use chart defaults. |
| `helm.clickhouse.otel.restrict_grants` | `bool` | `false` | Forwards `clickhouse.otel.restrictGrants` to the chart. When `true`, the `otel` ingest user is restricted to `INSERT` on the telemetry source tables only; `false` keeps it broad. **Requires chart version >= 2.0.0** (ignored by older charts). Flip to `true` only after external readers have moved to the `monte_carlo` user. |
| `helm.clickhouse.admin` | `object` | `null` | Optionally provisions the gated break-glass superuser (`admin`). Shape: `{ enabled = bool }`. When `enabled = true`, a Secrets Manager secret + ExternalSecret pipeline is created and the chart's admin user is enabled (loopback-only by default — reachable only via pod-exec); the password comes from `clickhouse_passwords.admin` (or is auto-generated). When disabled (default), no admin secret is created. **Requires chart version >= 2.0.0.** Omit (or `null`) to disable. |
| `helm.clickhouse.readonly_user` | `object` | `null` | Optionally provisions a second SELECT-only ClickHouse user (`readonly_user`, profile `readonly`). Shape: `{ enabled = bool }`. When `enabled = true`, a Secrets Manager secret + ExternalSecret pipeline mirroring the otel user is created and the toggle is forwarded to the chart; the password comes from `clickhouse_passwords.readonly_user` (or is auto-generated). **Requires chart version >= 1.2.0.** Omit (or `null`) to disable. |
| `clickhouse_passwords` | `object` (sensitive) | `{}` (all auto-generated) | Passwords for the ClickHouse SQL users. Shape: `{ admin = optional(string), otel = optional(string), monte_carlo = optional(string), schema_owner = optional(string), llm_worker = optional(string), readonly_user = optional(string) }`. Any field left null is auto-generated. Marked `sensitive`, so caller-supplied values are redacted in plan/apply output and CI logs — supply via a `.tfvars` file or `TF_VAR_clickhouse_passwords`. Stored in Secrets Manager and synced into the cluster by ESO; never passed through Helm values. Values remain readable in Terraform state — protect state accordingly. |
| `helm.opentelemetry_collector.resources` | `object` | `null` | Kubernetes resource requests/limits for the OTel Collector pods. Same shape as `helm.clickhouse.resources`. Omit to use chart defaults. |
| `helm.opentelemetry_collector.awss3_receiver` | `object` | `null` | Optional awss3 receiver config for the OTel Collector. When set with `enabled = true`, emits chart values that activate the receiver and appends `awss3` to the trace pipeline, and attaches SQS + S3 read permissions to the otel-collector IRSA role. Shape: `{ enabled = bool, sqs_queue_arn = string, sqs_queue_url = string, sqs_region = optional(string), s3_bucket = string, s3_region = optional(string), s3_prefix = optional(string, "") }`. Omit (or leave `null`) to disable. |
| `helm.llm_worker.resources` | `object` | `null` | Kubernetes resource requests/limits for the LLM-worker pods. Same shape as `helm.clickhouse.resources`. Omit to use chart defaults. |

## Outputs

| Name | Description |
|------|-------------|
| `eks_cluster_name` | Cluster name — use with `aws eks update-kubeconfig` |
| `eks_cluster_endpoint` | EKS control plane endpoint |
| `eks_cluster_ca_certificate` | PEM-encoded cluster CA certificate; use with `eks_cluster_endpoint` and `eks_cluster_name` to configure the `kubernetes` and `helm` providers |
| `eks_cluster_security_group_id` | Security group ID attached to the EKS cluster control plane. Null when `cluster.create = false` |
| `montecarlo_namespace` | Kubernetes namespace where all pipeline components (ClickHouse, OTel Collector, MC Agent) are installed |
| `oidc_provider_arn` | OIDC provider ARN |
| `otel_collector_irsa_role_arn` | IAM role ARN for the OTel Collector pods (IRSA) |
| `llm_worker_irsa_role_arn` | IAM role ARN for the LLM Worker pods (IRSA) |
| `otel_collector_certificate_arn` | ACM certificate ARN for the OTel Collector domain |
| `clickhouse_certificate_arn` | ACM certificate ARN for the ClickHouse domain |
| `clickhouse_admin_credentials_secret_arn` | Secrets Manager ARN for the ClickHouse admin password. Null when `helm.clickhouse.admin` is disabled. |
| `clickhouse_otel_credentials_secret_arn` | Secrets Manager ARN for the ClickHouse otel user password |
| `clickhouse_monte_carlo_credentials_secret_arn` | Secrets Manager ARN for the ClickHouse monte_carlo user password — retrieve and provide to MC during onboarding |
| `clickhouse_schema_owner_credentials_secret_arn` | Secrets Manager ARN for the ClickHouse schema_owner user password |
| `clickhouse_llm_worker_credentials_secret_arn` | Secrets Manager ARN for the ClickHouse llm_worker user password |
| `clickhouse_readonly_user_credentials_secret_arn` | Secrets Manager ARN for the password of the ClickHouse SQL user `readonly_user` (profile: readonly, SELECT-only). Null when `helm.clickhouse.readonly_user` is disabled. |
| `clickhouse_node_group` | Identity of the dedicated ClickHouse node group when active: `{ availability_zone, instance_type, size, label = { key, value }, taint = { key, value, effect } }`. Null when not active. Useful for verifying the resolved AZ during plan/apply review. |

## After Deployment

Configure kubectl access:

```bash
aws eks update-kubeconfig --name <eks_cluster_name> --region <region>
```

Retrieve the ClickHouse credentials for MC onboarding:

```bash
aws secretsmanager get-secret-value \
  --secret-id <clickhouse_monte_carlo_credentials_secret_arn> \
  --query SecretString --output text
```

## Cluster versioning & upgrades

The Kubernetes version and the core EKS add-ons are pinned to explicit versions
rather than tracking "latest". Pinning keeps every upgrade a deliberate,
reviewable change in a plan, instead of one that drifts in unnoticed on an
unrelated apply.

### Kubernetes version

`kubernetes_version` is pinned in the module (currently `1.35`). To upgrade:

1. Choose the next supported Kubernetes version — EKS upgrades the control plane
   one minor version at a time (e.g. `1.35` → `1.36`, never skipping a minor).
   See the [EKS Kubernetes versions](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
   docs for the currently supported list.
2. Confirm the add-on versions below and your own workloads support the target,
   then bump `kubernetes_version` and apply. The control plane upgrades first;
   the managed node groups then roll to a matching AMI. The pinned ClickHouse
   node group is the exception — its AMI must be bumped in the same apply (see
   [ClickHouse node group AMI](#clickhouse-node-group-ami) below).
3. Upgrade on a regular cadence. AWS provides standard support for each minor
   version for a limited window before it moves to (paid) extended support and
   is eventually force-upgraded, so staying within a minor or two of the latest
   avoids a rushed jump.

### ClickHouse node group AMI

The dedicated ClickHouse node group pins its AMI, while the main node group
tracks the latest EKS-optimized AMI. This split is deliberate:

- **ClickHouse node group — pinned (`use_latest_ami_release_version = false`, the
  default).** ClickHouse runs as a single-replica, AZ-locked StatefulSet, so
  replacing its node is a brief outage — the EBS volume detaches, a new node
  boots, and the pod reattaches, roughly a couple of minutes with no standby to
  fail over to. With the upstream EKS default (`use_latest = true`), Terraform
  re-resolves the node group's AMI to AWS's latest recommended build on *every*
  apply, so any apply — even one for an unrelated change — can replace the
  ClickHouse node the moment AWS publishes a new AMI. Pinning removes that
  trigger: the AMI changes only when you change it.
- **Main node group — latest (unpinned).** It hosts only stateless workloads,
  which reschedule without downtime, so it keeps AWS's free security
  auto-patching.

`clickhouse_node_group.ami_release_version` is the explicit build to pin to (e.g.
`"1.35.5-20260527"`). Leaving it `null` (the default) still prevents drift — the
node keeps whatever AMI it already runs — but records no specific version. Set an
explicit build to make the pin auditable and to perform deliberate updates.

**Pinning makes AMI patching your responsibility.** AWS will not patch a pinned
node for you, so:

1. **Update on a schedule** — monthly is a good default, quarterly a sensible
   floor — to pick up kernel / OS / container-runtime security fixes, and
   out-of-band for a critical node-level CVE. Each update replaces the ClickHouse
   node once (~2 min), so run it in a maintenance window. The point of pinning is
   to control *when* that bounce happens, not to patch less often.
2. **Don't let the pin go stale.** AWS eventually deprecates and then disables old
   AMI builds; a very old pin can become unlaunchable, which would break node
   replacement and scale-out. A monthly/quarterly cadence keeps you clear of that.
3. **Find the current recommended build** for your cluster's Kubernetes version:
   ```bash
   aws ssm get-parameter \
     --name /aws/service/eks/optimized-ami/<kubernetes_version>/amazon-linux-2023/x86_64/standard/recommended/release_version \
     --query Parameter.Value --output text
   ```

To update the AMI, set `clickhouse_node_group.ami_release_version` and apply. The
node is replaced exactly once and the apply completes even though ClickHouse is a
single replica behind a PodDisruptionBudget — the module sets
`force_update_version = true` on this node group for that reason.

**Kubernetes minor upgrades with a pinned node group.** A node group's Kubernetes
version and its AMI build must share a minor — EKS rejects, for example, a
`1.35.x` AMI on a `1.36` node group. So when you bump `kubernetes_version`, bump
`clickhouse_node_group.ami_release_version` to a matching-minor build **in the
same apply**. Do not raise `kubernetes_version` while leaving the ClickHouse pin
on the old minor — the apply will fail. The module does not expose a per-node-group
Kubernetes version, so the control plane and the ClickHouse node move together;
coupling both values in one apply replaces the ClickHouse node once.

### EKS add-ons

The `vpc-cni`, `coredns`, `kube-proxy`, and `aws-ebs-csi-driver` add-ons are
pinned to explicit `addon_version`s (not `most_recent`). To bump one, list the
versions available for your cluster's Kubernetes version and pick the default
(or a newer compatible build):

```bash
aws eks describe-addon-versions \
  --kubernetes-version <ver> --addon-name <addon> \
  --query 'addons[0].addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion'
```

Each add-on build targets a range of cluster versions, so bump the add-ons
alongside a Kubernetes upgrade and review the version change before applying.

### Network policy enforcement

The `vpc-cni` add-on is configured with `enableNetworkPolicy = "true"`, so the
cluster's CNI can enforce Kubernetes [`NetworkPolicy`](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
resources. This module ships **no** `NetworkPolicy` objects — all pod-to-pod
traffic is allowed by default until you define your own. Enabling the engine up
front lets you adopt policies later without reconfiguring the add-on (which
restarts the CNI pods).

## Development

```bash
make sanity-check   # fmt check + validate (CI pipeline)
make test           # variable-validation tests (requires Terraform >= 1.7)
```

`make test` runs `terraform test` against `tests/*.tftest.hcl`. Tests cover the input safety nets (`cluster.main_node_group_size` range, the existing-cluster guard) using `mock_provider` — see the test file's preamble for the explicit scope and known coverage gaps. The module itself stays at `required_version >= 1.3`; the test floor is a dev-tool requirement only.

To release a new version, create and push a tag: `git tag v0.1.0 && git push origin v0.1.0`

## License

See [LICENSE](LICENSE).

## Security

See [SECURITY.md](SECURITY.md).
