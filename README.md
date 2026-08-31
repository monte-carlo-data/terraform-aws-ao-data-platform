# terraform-aws-ao-data-platform

Terraform module that deploys the Monte Carlo Agent Observability data platform on AWS. Provisions a full pipeline from OTel Collector through to ClickHouse on EKS, ready for the MC Agent to connect to.

**What gets deployed:**
- EKS cluster + VPC (or targets an existing cluster)
- ClickHouse (via `ao-data-platform` Helm chart)
- OTel Collector (via `ao-data-platform` Helm chart)
- Cluster controllers: AWS Load Balancer Controller, cert-manager, External Secrets Operator, external-dns
- ACM certificates, Route 53 records, IAM/IRSA roles, Secrets Manager secrets

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.11
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
  version = "~> 2.0"

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
  version = "~> 2.0"

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
  version = "~> 2.0"

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
  version = "~> 2.0"

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

### AWS S3 receivers for the OTel Collector

Set `helm.opentelemetry_collector.awss3_receivers` to have the OTel Collector ingest OTLP traces from objects in one or more S3 buckets, each notified via its own SQS queue — one map entry per queue/bucket pair. For every enabled entry, the module:

- Renders an `awss3` receiver with component ID `awss3/<key>`, configured with the supplied SQS URL/region and S3 bucket/region/prefix, and appends it to the trace pipeline so the receiver is actually wired up.
- Attaches an inline policy to the `otel-collector` IRSA role granting `sqs:ReceiveMessage`/`DeleteMessage`/`GetQueueAttributes`/`GetQueueUrl` on every receiver's queue and `s3:GetObject`/`GetBucketLocation` on every receiver's bucket.

**Give each receiver its own dedicated SQS queue — never share a queue.** In SQS mode a receiver fetches whatever object each notification names but filters the records against its own configured bucket/prefix, and it deletes messages whose records were all filtered out — so two receivers sharing one queue destroy each other's notifications. Duplicate `sqs_queue_arn` values across enabled receivers are rejected at plan time. To feed several consumers from one bucket's events, fan the bucket notification out via SNS with a queue per consumer.

Per entry: `enabled` defaults to `true` (set `false` to keep the entry without rendering it); `sqs_region` and `s3_region` default to `var.region`; `s3_prefix` defaults to `""` (any object in the bucket) and is normalized internally to include a single trailing `/` when non-empty (so `"traces"` and `"traces/"` behave identically). The map key `trace-export-ingest` is reserved for **enabled** entries while `trace_export_ingest` is set — the module synthesizes a receiver under the component ID `awss3/trace-export-ingest` for the [trace-export ingest leg](#trace-export-ingest-leg). A *disabled* entry under that key is dropped from the merge before rendering, so it is fine to keep (e.g. to stage a future receiver).

Note: adding, changing, or removing a receiver changes the collector's rendered config, which rolling-restarts the collector Deployment on apply.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 2.0"

  region                = "us-east-1"
  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"
  hosted_zone_id        = "Z1234567890ABC"

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "1.5.0"

    opentelemetry_collector = {
      awss3_receivers = {
        traces = {
          sqs_queue_arn = "arn:aws:sqs:us-east-1:123456789012:otel-traces"
          sqs_queue_url = "https://sqs.us-east-1.amazonaws.com/123456789012/otel-traces"
          s3_bucket     = "acme-otel-traces"
          # enabled defaults to true
          # sqs_region / s3_region default to var.region
          # s3_prefix defaults to ""
        }
      }
    }
  }
}
```

`helm.opentelemetry_collector.awss3_receiver` (singular) is the **deprecated** single-receiver form: use `awss3_receivers` for new configuration. It continues to work throughout v2.x and renders identically to before — under the bare `awss3` component ID, so existing deployments upgrading the module see a zero diff — and it may be combined with `awss3_receivers` entries. It will only be removed in a future major version.

### Trace-export ingest leg

Where `awss3_receivers` consumes buckets and queues you manage yourself, the optional top-level `trace_export_ingest` variable provisions the whole delivery leg for an external trace producer in one apply:

- A dedicated **ingest S3 bucket** (public-access blocked, TLS-only bucket policy, `force_destroy`) with a short object lifecycle — this is transit storage, not retention: objects under the ingest prefix expire after `lifecycle_days` (default 3), and incomplete multipart uploads are aborted at the same age. If set, `bucket_name` must name a bucket that does not already exist — the module creates and owns it.
- A dedicated **SQS queue** (14-day message retention, 300 s visibility timeout) receiving the bucket's `ObjectCreated` notifications for the ingest prefix, with a queue policy pinned to both the bucket ARN and this account.
- A synthesized **awss3 receiver** under the reserved component ID `awss3/trace-export-ingest`, wired into the collector's trace pipeline and read policy exactly like an `awss3_receivers` entry (an enabled entry under that map key is rejected while the block is set; a disabled one is dropped and fine to keep).
- A **writer IAM role** the external producer assumes to upload files: trust is anchored on the producer account's root, guarded by an `sts:ExternalId` condition (`trace_export_external_id`) and an `aws:PrincipalArn` `StringLike` condition on `producer_execution_role_arn`. That input accepts an exact role ARN or a wildcard in the role-**name** portion (e.g. `arn:aws:iam::210987654321:role/exporter-*`) so the producer role can be re-provisioned without re-applying this module — the account ID must be literal, and the pattern is the effective principal boundary, so keep it narrow. The role's only permission (absent a customer-managed KMS key) is `s3:PutObject` scoped to the ingest prefix; supplying `kms_key_arn` additionally grants `kms:GenerateDataKey`/`kms:Encrypt` on that key.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 2.0"

  # ... cluster/networking/helm configuration ...

  trace_export_ingest = {
    producer_execution_role_arn = "arn:aws:iam::210987654321:role/exporter-*"
    # bucket_name  defaults to "<cluster-name>-<region>-trace-export-ingest-<account-id>"
    # prefix       defaults to "traces/" (multi-segment prefixes supported)
    # lifecycle_days defaults to 3
    # agent_role_arn / kms_key_arn optional — see the Inputs table
  }
  trace_export_external_id = "value-issued-by-the-exporting-system" # sensitive
}
```

`trace_export_external_id` is a separate top-level variable, required when `trace_export_ingest` is set. It is marked `sensitive`, so caller-supplied values are redacted in plan/apply output and CI logs — supply it via a `.tfvars` file or `TF_VAR_trace_export_external_id`. The value remains readable in Terraform state — protect state accordingly.

The six `trace_export_*` outputs (bucket, prefix, writer-role ARN, external ID, queue ARN/name) carry everything the producer side and your monitoring need for registration — all null when the block is unset, and unset, the module plans identically to previous releases.

**Object format and key layout.** The receiver dispatches purely on the object key suffix: keys ending `.json` are decoded as OTLP JSON (one `ExportTraceServiceRequest` per object), `.binpb` as OTLP protobuf, and **anything else is skipped with only a collector warning** (`Unsupported file format`) — the object's Content-Type is ignored. Producers must write keys ending `.json` under the configured prefix; a date-partitioned layout (`<prefix>year=YYYY/month=MM/day=DD/traces-*.json`) is recommended, since the receiver's time-range (backfill) mode walks exactly that structure. Gzip (`.json.gz`) is auto-decompressed and needs no collector config change. This behavior was verified against OpenTelemetry Collector Contrib 0.150.1 (`awss3receiver` v0.150.0), the collector build bundled by the `opentelemetry-collector` subchart at the time of writing. The bundled collector version can change with a future `ao-data-platform` chart release — re-verify the suffix-dispatch behavior before adopting a chart that bumps it. With a mismatched collector build or a wrong key suffix, the failure is silent from the outside: **objects arrive in the bucket but no traces ingest**.

**Encryption.** The bucket defaults to SSE-S3 — defensible for days-lived transit data behind a public-access block, a TLS-only policy, and prefix-scoped IAM. Compliance baselines that require a customer-managed key can pass `kms_key_arn`: the bucket switches to SSE-KMS with S3 Bucket Keys (keeping per-object KMS request cost low), the writer role gains `kms:GenerateDataKey`/`kms:Encrypt`, and the collector role gains `kms:Decrypt` on that key.

These are IAM identity-policy grants on module-managed, same-account roles, so they only take effect if the CMK's **key policy** delegates access to the account (the default key policy does; a tightened compliance key policy may not — in which case the key policy must name the collector IRSA role and the writer role explicitly, or ingest silently fails with objects arriving but never decrypting). `agent_role_arn` is different: a cross-account principal's KMS access **cannot** be granted from this module — cross-account KMS always requires an explicit grant in the key's own policy. So when `agent_role_arn` and `kms_key_arn` are both set, the CMK's key policy must itself grant that role `kms:GenerateDataKey`/`kms:Encrypt`, or the agent's SSE-KMS PUTs fail `AccessDenied` and no trace data lands.

**Teardown.** Unsetting the block (or destroying) removes the whole leg; the bucket sets `force_destroy`, so in-flight transit objects do not block removal. Notifications already in the queue at teardown are simply discarded with it.

### Least-privilege ClickHouse users

The module provisions a per-access-path ClickHouse user model (`ao-data-platform` chart `>= 2.0.0`), where each component authenticates as a user scoped to what it does. Four users are always provisioned; two are opt-in.

| User | Used by | Provisioned |
|------|---------|-------------|
| `otel` | OTel Collector ingest | always |
| `schema_owner` | schema migrations (DDL) + materialized-view owner | always |
| `llm_worker` | LLM-worker queue reader/writer | always |
| `monte_carlo` | Monte Carlo data-source reads + agent queue producer | always |
| `admin` | break-glass superuser (loopback-only) | opt-in — `helm.clickhouse.admin` |
| `readonly_user` | human / MCP / JDBC read access | opt-in — `helm.clickhouse.readonly_user` (see below) |

For each provisioned user the module generates a 32-character password (or uses the matching `clickhouse_passwords.*` override), stores it in Secrets Manager KMS-encrypted with the pipeline key, grants the External Secrets Operator read access, and forwards the per-user `externalSecret` config into the chart so ESO syncs the password into Kubernetes. Each user's secret ARN is exposed as a `clickhouse_*_credentials_secret_arn` output. As of v3.0.0 generation is ephemeral and the write uses write-only arguments, so no password is stored in Terraform state or plan files.

- Set `helm.clickhouse.otel.restrict_grants = true` to tighten the `otel` ingest user to `INSERT`-only on the telemetry source tables. Flip this only after any external readers have moved to the `monte_carlo` user — see [Upgrading to v2.0.0](#upgrading-to-v200).
- Enable the gated break-glass `admin` superuser with `helm.clickhouse.admin = { enabled = true }`. It is reachable only over loopback by default (i.e. via `kubectl exec` into the ClickHouse pod). Disabled by default; when disabled no admin secret is created and `clickhouse_admin_credentials_secret_arn` is `null`.

**Requires `ao-data-platform` chart >= 2.0.0.** Older charts silently ignore the per-user values; the module stays compatible with them via a transitional dual-wiring of the `otel` credential.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 2.0"

  region                = "us-east-1"
  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"
  hosted_zone_id        = "Z1234567890ABC"

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "2.0.0"

    clickhouse = {
      # Gated break-glass superuser (loopback-only). Off by default.
      admin = { enabled = true }
      # Set true to tighten otel to INSERT-only, once external readers use
      # monte_carlo. Defaults to false (broad access) when omitted; uncomment
      # the line below to opt in.
      # otel = { restrict_grants = true }
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
  version = "~> 2.0"

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

The module auto-creates a dedicated single-AZ EKS managed node group for ClickHouse whenever `helm.deploy_charts = true` and `cluster.create = true`, gated by `manage_legacy_clickhouse_node_group` (default `true`; the flag exists so a migration to the clustered/HA topology can retire this node group via config — see "Clustered / HA topology"). This module expects `helm.chart_version >= "1.3.0"` — older chart versions bundle their own OTel/CH anti-affinity rule and structurally don't use the dedicated NG. Nothing in the module gates this at apply time; a 1.2.x caller will apply cleanly and hit the original scheduler deadlock at runtime. When both conditions hold, the module:

- Creates a second managed node group (one node, single-AZ) pinned to `var.clickhouse_node_group.availability_zone` (or, when null, the first AZ from `data.aws_availability_zones.available`).
- Applies a `dedicated=clickhouse:NoSchedule` taint to the node group so only pods that tolerate it can land there.
- Automatically sets `clickhouse.nodeSelector` and `clickhouse.tolerations` on the helm release so the ClickHouse pod targets the dedicated node exclusively. No manual helm-values plumbing required.
- Leaves the main node group at its default size of 2. The stateless tier (OTel, llm-worker, controllers) still benefits from a 2-node HA floor even after CH moves to the dedicated NG — node-drain operations on the main pool then have somewhere to spill the stateless workloads. Set `cluster.main_node_group_size = 1` explicitly to opt into a single-node main pool when HA isn't a requirement.

This pattern enforces scheduling separation between ClickHouse and the controllers that previously competed for its node (OTel collector, llm-worker, and other Deployment workloads run on the main node group). DaemonSets (kube-proxy, aws-node, ebs-csi-node, etc.) continue to co-locate with ClickHouse on the dedicated node by design — they tolerate the taint and are required wherever a node exists. The OTel-vs-ClickHouse pod anti-affinity rule was removed from the `ao-data-platform` chart in 1.3.0 in favor of this stronger structural separation — the anti-affinity approach was vulnerable to scheduler deadlocks when the cluster topology forced the only viable node for ClickHouse to be occupied by OTel first.

**EBS volumes are AZ-locked.** The dedicated NG MUST live in the same AZ as the existing ClickHouse PV, or the CH pod can't schedule on it. The module defaults to the region's first AZ alphabetically; verify the `clickhouse_node_group.availability_zone` output during plan/apply review, and override `var.clickhouse_node_group.availability_zone` if needed.

**Upgrade impact from chart < 1.3.0.** Bumping `helm.chart_version` from a 1.2.x release to `>= "1.3.0"` enables this module's dedicated CH NG behavior — the apply creates the dedicated CH NG alongside the existing main NG (main NG stays at its default size of 2; total cluster grows by one node). To opt into a cost-shrunk single-node main pool instead, set `cluster.main_node_group_size = 1` explicitly. **For existing deployments with ClickHouse data to preserve:** set `clickhouse_node_group.availability_zone` to the existing CH PV's AZ before applying, so the dedicated NG lands in the same AZ and the StatefulSet re-attaches the existing EBS volume in place. EBS volumes are AZ-locked and cannot follow the StatefulSet — if the resolved dedicated-NG AZ doesn't match the PV's AZ, the CH pod stays `Pending` and the only forward path is deleting the PVC out-of-band (re-ingest required).

**Operational note — single-replica ClickHouse on a 1-node NG has no HA.** The CH StatefulSet runs as a single replica on the dedicated single-AZ node, with no surge headroom (a maxSurge replica can't land on a different node since the EBS PV is AZ-locked, and the dedicated NG has only one node). A PodDisruptionBudget cannot protect a single replica: node replacement (EKS AMI rolls force-terminate past PDBs after a grace period) and voluntary drains alike leave the only replica evicted with no standby to serve. Node-drain operations — including routine EKS AMI rolls of the dedicated NG, node-group resizing, or manual draining — therefore incur ClickHouse downtime for the duration of the pod restart (~30-90s on a healthy node). This is a documented limitation of the single-AZ, single-replica design; the clustered/HA topology (see "Clustered / HA topology" below) removes it by running multiple replicas across AZs.

For existing clusters (`cluster.create = false`), the module does not manage the dedicated NG — attach a tainted (`dedicated=clickhouse:NoSchedule`) single-AZ node group to the cluster out-of-band, and pass matching `clickhouse.nodeSelector` + `clickhouse.tolerations` to the chart's ClickHouse pod template via your own helm release values. The `clickhouse_node_group` variable has no effect on this path.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 2.0"

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

### Clustered / HA topology

By default the module runs a single ClickHouse instance on one dedicated node group (above). To run ClickHouse in a clustered, highly-available configuration — multiple replicas backed by a ClickHouse Keeper ensemble, spread across availability zones — set the per-AZ topology variables. This requires `helm.chart_version >= "2.3.0"`, the first chart version with Keeper support (an older chart simply ignores the Keeper values, leaving the Keeper node groups empty); the replicated table schema — required to run more than one replica — ships at chart 3.0.0. The converse also matters: on chart >= 2.3.0 Keeper is intrinsic and renders on every install, so **bumping `helm.chart_version` alone — without setting `keeper_availability_zones` — deploys the chart's default 3-voter Keeper ensemble onto the main node pool**; bump the chart version and set the topology variables together. **The topology applies only to module-created clusters (`cluster.create = true`):** on an existing cluster, `keeper_availability_zones` is rejected by a plan-time precondition (the Keeper pods' node selector would match no nodes), and `clickhouse_availability_zones` creates no node groups. For existing clusters, attach tainted per-AZ node groups out-of-band — the same pattern as the dedicated node group above — and wire the scheduling values through your own helm release values.

**Node groups are per-AZ and AZ-pinned.** Each ClickHouse replica and each Keeper voter is a stateful pod backed by an EBS volume, and EBS volumes are AZ-locked — a volume cannot move between zones. So every replica and voter needs a single-AZ node group in its own zone, and placement is driven by **explicit AZ names**, not a positional index into the available-AZ list (which can silently remap "the first AZ" to a different physical zone across applies and strand a volume).

- `clickhouse_availability_zones` — one node group (`clickhouse-<az>`) per entry; the list length is the ceiling for `clickhouse_replica_count`. **Element 0 must be the AZ of the existing ClickHouse volume**, since that is the AZ the running pod stays pinned to. A plan-time precondition enforces the match; when there is genuinely no existing volume to preserve (a fresh HA stand-up, or a deliberate re-ingest migration), set `enforce_clickhouse_volume_az_match = false`.
- `keeper_availability_zones` — one voter node group (`keeper-<az>`) per entry. Keeper quorum requires an **odd** number of voters across distinct zones: 3 tolerates the loss of one AZ (2 of 3 remain); 1 for dev. The keeper voter count and the chart's `keeper.replicasCount` are both derived from this list, so they cannot drift.
- `clickhouse_replica_count` — replicas requested from the chart (`clickhouse.replicasCount`). Defaults to `1` and is validated (via a Helm-release precondition) to never exceed the number of `clickhouse_availability_zones`. Raising above `1` requires chart >= 3.0.0 and — on clusters with pre-existing data — tables already converted to replicated engines; against unconverted tables the second replica starts empty instead of as a copy.

**Three AZs is Keeper-driven.** ClickHouse itself needs only two AZs for two replicas; the third exists so the Keeper quorum spans three failure domains. The VPC created by this module already spans three AZs by default (`networking.private_subnet_cidrs` provisions three private subnets), so a 3-AZ Keeper + 2-AZ ClickHouse layout needs no networking change.

**Adding an AZ on an existing VPC: the cluster's AZ set is immutable.** On `create_vpc = false` deployments whose cluster was created with subnets in fewer AZs than the HA topology needs, the extra AZ cannot simply be appended to `networking.existing_private_subnet_ids`: that list also populates the cluster's `vpc_config`, and EKS pins the control-plane AZ set at cluster creation — a later update whose subnets span a different AZ set is rejected (`InvalidParameterException: Provided subnets belong to the AZs 'a,b,c'. But they should belong to the exact set of AZs 'a,b' in which subnets were provided during cluster creation`), and Terraform plans the change as a legal in-place update, only surfacing the error at apply. Worker nodes have no such restriction — a node group can run in any VPC subnet with routing; only control-plane ENI placement is pinned. So widen the node topology instead: append the new AZ's subnet to `existing_private_subnet_ids` **and** set `networking.control_plane_subnet_ids` to the cluster's creation-time subnets, which pins `vpc_config` while the wider list drives node placement. Side effects to expect: widening `existing_private_subnet_ids` **replaces the main node group** (a managed node group's subnet list is immutable, and the replacement is create-before-destroy), while single-AZ node groups — the dedicated ClickHouse node group and the per-AZ HA groups — are unaffected by subnets outside their AZ. It also **extends both NLBs into the new AZ**: the `aws-load-balancer-subnets` annotation renders from the same list, and the LB controller adds the new AZ's ENI in place.

**No autoscaler — capacity is pre-provisioned.** This module does not install a cluster autoscaler, so every AZ a stateful pod lands in must have a node group standing by. When `create_vpc = true`, the AZs you list must be among the first `length(networking.private_subnet_cidrs)` of the region's available AZs — that is where the module places private subnets. A plan-time postcondition rejects any listed AZ that has no matching private subnet.

**Staged, additive rollout.** The topology is designed to be introduced without disrupting a running single instance:

- The per-AZ ClickHouse node groups are created **active** (one node per AZ) as soon as the AZ list is set, symmetric with the Keeper node groups. They come up **empty** — no ClickHouse replica lands on them until `clickhouse_replica_count` is raised — so standing them up ahead of time validates capacity, subnets, AMI, and CSI outside any maintenance window, at the cost of a few idle nodes. (They are not created parked and scaled up later: the underlying EKS managed-node-group module ignores post-creation `desired_size` changes, so a later scale-up would be a silent no-op.)
- The chart upgrade itself is two-staged: first to 2.3.0 (Keeper support) in the same apply that sets the topology variables, then — with ingest stopped for the window (see the pause note below) — to 3.0.0, whose schema is replicated, before `clickhouse_replica_count` is raised. A running cluster can rest between the two stages indefinitely: chart 2.3.0 with the Keeper ensemble up and a single replica on the existing tables is a fully supported state.
- `clickhouse_replica_count` stays TF-owned at `1` until you deliberately raise it — this is the sole control over how many replicas run; bumping the chart version alone never scales replicas.
- `manage_legacy_clickhouse_node_group` (default `true`) keeps the original single-instance node group in place; it is flipped to `false` in a final apply to retire that node group once the replica has moved onto a per-AZ node group. A plan-time precondition rejects the flip while `clickhouse_availability_zones` is empty — that would remove every node carrying the `dedicated=clickhouse` label while the chart's ClickHouse node selector still requires it, leaving the pod `Pending`.
- `llm_worker.replica_count` (on the `helm` variable) lets the worker be paused as configuration (scaled to `0`) during a maintenance window and resumed afterward, surviving intervening applies. The collector's `opentelemetry_collector.replica_count = 0` is **not** honored by the chart — its template treats `0` as unset and deploys the default count — so stop ingest upstream of the collector instead: deny consumption on the SQS queues feeding the awss3 receivers, or pause OTLP senders.

**Cross-zone NLB routing is enabled** on both the ClickHouse and OTel Collector NLBs (via the `aws-load-balancer-attributes` Service annotation, in every topology). NLBs default cross-zone routing off, in which case an NLB ENI in an AZ with no healthy targets black-holes clients that resolve to it — with one replica per AZ, that turns every routine single-replica event (pod restart, node drain, AMI roll) into a multi-minute external degradation, and for the single-replica collector Deployment it leaves every out-of-AZ ENI permanently targetless. With cross-zone enabled, every ENI forwards to healthy targets in any AZ. Standard AWS inter-AZ data-transfer charges apply to cross-zone-routed connections (negligible at typical telemetry volumes).

**NLB subnet placement is explicit.** Both LoadBalancer Services also carry the `aws-load-balancer-subnets` annotation, pinning NLB ENIs to the module's private subnets (the module-created ones, or `networking.existing_private_subnet_ids`). Without it, the LB controller auto-discovers subnets — and in a VPC with no `kubernetes.io/role/internal-elb` subnet tags, discovery falls back to route-table classification and picks one subnet per AZ by lexicographically-lowest subnet ID: a lottery that can place ENIs in unrelated subnets sharing the VPC and expand the NLB into every AZ the VPC touches. Explicit placement is deterministic and keeps ENIs in subnets the platform owns. The controller accepts **at most one subnet per AZ** in this list. On existing deployments, upgrading to a module version with this annotation makes the controller re-set each NLB's subnets to the annotated list in place; removing an AZ deletes that AZ's ENI and terminates active connections through it — a brief, one-time blip, best scheduled in a quiet window.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 2.0"

  region                = "us-east-1"
  otel_collector_domain = "otel.acme.com"
  clickhouse_domain     = "clickhouse.acme.com"

  # Two ClickHouse replicas across two AZs, backed by a 3-node Keeper ensemble.
  # Element 0 of clickhouse_availability_zones is the AZ of the existing volume.
  clickhouse_availability_zones = ["us-east-1a", "us-east-1b"]
  keeper_availability_zones     = ["us-east-1a", "us-east-1b", "us-east-1c"]
  clickhouse_replica_count      = 2

  helm = {
    chart_registry = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com"
    chart_version  = "3.0.0" # replicated-schema release (Keeper support arrived in 2.3.0)
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
| `clickhouse_node_group` | `object` | `{}` (all defaults) | Configuration for the dedicated single-AZ ClickHouse node group. Shape: `{ availability_zone = optional(string), instance_type = optional(string, "r5.xlarge"), use_latest_ami_release_version = optional(bool, false), ami_release_version = optional(string) }`. The dedicated NG is auto-created when `helm.deploy_charts = true` AND `cluster.create = true`, and managed while `manage_legacy_clickhouse_node_group = true` — see the "Dedicated ClickHouse node group" section. `availability_zone`: when null, defaults to the first AZ from `data.aws_availability_zones.available` (alphabetical) — override when the ClickHouse PV is in a different AZ (EBS volumes are AZ-locked). `instance_type`: EC2 instance type for the dedicated node; defaults to `r5.xlarge`. `use_latest_ami_release_version`: defaults to `false` — the CH NG is no-drift pinned, so its AMI won't change on an unrelated apply (see "Pinned node group AMIs"). `ami_release_version`: optional explicit AMI build to pin to (e.g. `"1.35.5-20260527"`); `null` (default) still prevents drift but records no specific build. Has no effect when `cluster.create = false`. |
| `clickhouse_availability_zones` | `list(string)` | `[]` | Explicit AZ names for the per-AZ ClickHouse node groups of the clustered/HA topology (one `clickhouse-<az>` node group per entry). Empty (default) keeps the single-instance layout. Element 0 must be the AZ of the existing ClickHouse volume (enforced by a plan-time precondition; see `enforce_clickhouse_volume_az_match`). When `create_vpc = true`, entries must be among the first `length(networking.private_subnet_cidrs)` of the region's available AZs. Requires `cluster.create = true` (no node groups are created for existing clusters). See "Clustered / HA topology". |
| `keeper_availability_zones` | `list(string)` | `[]` | Explicit AZ names for the per-AZ ClickHouse Keeper node groups (one voter per entry). Must be an **odd** count across distinct AZs for quorum (3 typical, 1 for dev). Empty (default) creates no Keeper node groups. The list length is the single source of truth for both the voter node-group count and the chart's `keeper.replicasCount`. Requires `cluster.create = true` — rejected by a plan-time precondition on existing clusters. See "Clustered / HA topology". |
| `clickhouse_replica_count` | `number` | `1` | ClickHouse replicas requested from the chart (`clickhouse.replicasCount`). TF-owned and defaulted to `1` so a chart-version bump alone never scales replicas; the sole control over replica count. Enforced (via a Helm-release precondition) to be `<= max(length(clickhouse_availability_zones), 1)`. Raising above `1` requires chart >= 3.0.0 and prior conversion of existing tables to replicated engines. |
| `clickhouse_ha_node_group` | `object` | `{}` (all defaults) | Configuration for the per-AZ ClickHouse node groups (created active, one per `clickhouse_availability_zones` entry). Shape: `{ instance_type = optional(string, "r6i.xlarge"), use_latest_ami_release_version = optional(bool, false), ami_release_version = optional(string) }`. Kept separate from `clickhouse_node_group` so the go-forward instance type differs from the legacy node group without re-typing it (which would roll the running pod). AMI pinning behaves like `clickhouse_node_group`. |
| `keeper_node_group` | `object` | `{}` (all defaults) | Configuration for the per-AZ Keeper node groups. Shape: `{ instance_type = optional(string, "m6i.large"), storage_size = optional(string, "10Gi"), storage_class = optional(string, "gp3"), use_latest_ami_release_version = optional(bool, false), ami_release_version = optional(string) }`. No `replica_count` field — the voter count is derived from `keeper_availability_zones`. `storage_size`/`storage_class` configure the Keeper PVC (via chart values), not the node root disk. AMI pinned by default. |
| `enforce_clickhouse_volume_az_match` | `bool` | `true` | Whether a plan-time precondition requires `clickhouse_availability_zones[0]` to match the AZ of the existing single-instance ClickHouse volume (the AZ `clickhouse_node_group.availability_zone` resolves to) — a mismatch would strand the AZ-locked volume during the in-place migration. Set to `false` only when there is no existing volume to preserve (fresh HA stand-up, or a deliberate re-ingest migration). No effect when `clickhouse_availability_zones` is empty or on existing clusters. |
| `manage_legacy_clickhouse_node_group` | `bool` | `true` | Whether the module manages the legacy single-instance ClickHouse node group. Defaults to `true` (unchanged behavior). Flip to `false` in a post-migration apply to retire the legacy node group via config once the ClickHouse pod has relocated onto a per-AZ node group. Only has an effect when the dedicated CH node group would otherwise be created. A plan-time precondition rejects `false` while `clickhouse_availability_zones` is empty (the ClickHouse pod would be left with no schedulable node). |
| `networking.create_vpc` | `bool` | `true` | Create a new VPC or use an existing one |
| `networking.vpc_cidr` | `string` | `"10.18.0.0/16"` | CIDR block for the created VPC. The default is a placeholder meant to be overridden — pick a range that doesn't collide with your existing networks (peering or VPN into a colliding range is painful to retrofit). Only applies when `create_vpc = true` |
| `networking.private_subnet_cidrs` | `list(string)` | `["10.18.1.0/24", "10.18.2.0/24", "10.18.3.0/24"]` | Private subnet CIDRs for the created VPC; must sit inside `vpc_cidr`. Override together with it |
| `networking.public_subnet_cidrs` | `list(string)` | `["10.18.4.0/24", "10.18.5.0/24", "10.18.6.0/24"]` | Public subnet CIDRs for the created VPC; must sit inside `vpc_cidr`. Override together with it |
| `networking.existing_vpc_id` | `string` | `null` | Required when `create_vpc = false` |
| `networking.existing_private_subnet_ids` | `list(string)` | `[]` | Required when `create_vpc = false` (min 2 subnets in different AZs). Drives node-group subnet resolution — and, unless `control_plane_subnet_ids` is set, the cluster's control-plane subnets too. Also rendered into the `aws-load-balancer-subnets` annotation on both LoadBalancer Services, pinning NLB ENI placement; the LB controller accepts at most one subnet per AZ, so keep the list to one subnet per AZ. |
| `networking.control_plane_subnet_ids` | `list(string)` | `[]` | Subnets for the EKS control-plane ENIs (the cluster's `vpc_config`), passed through to the underlying EKS module's input of the same name. Never influences node-group placement. Empty (default): the control plane uses `existing_private_subnet_ids`, unchanged behavior. Set it to the cluster's creation-time subnets when widening `existing_private_subnet_ids` into a new AZ — a cluster's control-plane AZ set is immutable after creation, so node-only subnets must stay out of `vpc_config`. Requires `create_vpc = false`; min 2 subnets when set. See "Adding an AZ on an existing VPC" under "Clustered / HA topology" |
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
| `helm.llm_worker.image_tag` | `string` | `"latest-aws"` | LLM-worker container image tag. Pin to a released tag (e.g. `1.1.0-aws`) for production. |
| `helm.llm_worker.replica_count` | `number` | `null` | Optional override for the llm-worker replica count. `null` (default) lets the chart control it; set to `0` to pause the worker as configuration that survives an apply (used during a maintenance window). |
| `helm.clickhouse.resources` | `object` | `null` | Kubernetes resource requests/limits for the ClickHouse pods. Shape: `{ requests = map(string), limits = map(string) }`. Omit to use chart defaults. |
| `helm.clickhouse.otel.restrict_grants` | `bool` | `false` | Forwards `clickhouse.otel.restrictGrants` to the chart. When `true`, the `otel` ingest user is restricted to `INSERT` on the telemetry source tables only; `false` keeps it broad. **Requires chart version >= 2.0.0** (ignored by older charts). Flip to `true` only after external readers have moved to the `monte_carlo` user. |
| `helm.clickhouse.admin` | `object` | `null` | Optionally provisions the gated break-glass superuser (`admin`). Shape: `{ enabled = bool }`. When `enabled = true`, a Secrets Manager secret + ExternalSecret pipeline is created and the chart's admin user is enabled (loopback-only by default — reachable only via pod-exec); the password comes from `clickhouse_passwords.admin` (or is auto-generated). When disabled (default), no admin secret is created. **Requires chart version >= 2.0.0.** Omit (or `null`) to disable. |
| `helm.clickhouse.readonly_user` | `object` | `null` | Optionally provisions a second SELECT-only ClickHouse user (`readonly_user`, profile `readonly`). Shape: `{ enabled = bool }`. When `enabled = true`, a Secrets Manager secret + ExternalSecret pipeline mirroring the otel user is created and the toggle is forwarded to the chart; the password comes from `clickhouse_passwords.readonly_user` (or is auto-generated). **Requires chart version >= 1.2.0.** Omit (or `null`) to disable. |
| `clickhouse_passwords` | `object` (sensitive) | `{}` (all auto-generated) | Passwords for the ClickHouse SQL users. Shape: `{ admin = optional(string), otel = optional(string), monte_carlo = optional(string), schema_owner = optional(string), llm_worker = optional(string), readonly_user = optional(string) }`. Any field left null is auto-generated. Marked `sensitive`, so caller-supplied values are redacted in plan/apply output and CI logs — supply via a `.tfvars` file or `TF_VAR_clickhouse_passwords`. Stored in Secrets Manager and synced into the cluster by ESO; never passed through Helm values. Marked `ephemeral`, so values are omitted from state and plan files entirely; ephemeral variables still accept ordinary values, so existing callers need no change. The provider does still read the secret during plan/refresh (aws #42383), so plan-time IAM is unchanged. |
| `clickhouse_password_versions` | `object` | `{}` (all `1`) | Version counter per ClickHouse user driving each secret's `secret_string_wo_version`. Shape: `{ admin = optional(number, 1), otel = optional(number, 1), monte_carlo = optional(number, 1), schema_owner = optional(number, 1), llm_worker = optional(number, 1), readonly_user = optional(number, 1) }`. Because the password is a write-only argument Terraform cannot detect drift on it — the secret is rewritten **only** when the matching version changes. This is the rotation lever: bump one field to rotate one user, all six to rotate the deployment. Bumping a field without supplying the matching `clickhouse_passwords` value writes a freshly generated password. |
| `helm.opentelemetry_collector.resources` | `object` | `null` | Kubernetes resource requests/limits for the OTel Collector pods. Same shape as `helm.clickhouse.resources`. Omit to use chart defaults. |
| `helm.opentelemetry_collector.replica_count` | `number` | `null` | Optional override for the OTel Collector replica count. `null` (default) lets the chart control it. **`0` is not honored by the chart** — its collector template treats `0` as unset and deploys the default count; to stop ingest for a maintenance window, act upstream (deny consumption on the SQS queues feeding the awss3 receivers, or pause OTLP senders). Non-zero overrides work as expected. |
| `helm.opentelemetry_collector.awss3_receivers` | `map(object)` | `{}` | awss3 receivers for the OTel Collector, one entry per SQS-queue/S3-bucket pair. Each enabled entry renders a receiver with component ID `awss3/<key>` appended to the trace pipeline, and the otel-collector IRSA role gets SQS + S3 read permissions covering every enabled receiver. Entry shape: `{ enabled = optional(bool, true), sqs_queue_arn = string, sqs_queue_url = string, sqs_region = optional(string), s3_bucket = string, s3_region = optional(string), s3_prefix = optional(string, "") }`. Keys are restricted to `[a-zA-Z0-9_-]`, and the key `trace-export-ingest` is reserved for enabled entries while `trace_export_ingest` is set (a disabled entry under that key is dropped from the merge and is fine to keep); every receiver needs its own dedicated queue (duplicate `sqs_queue_arn` values are rejected — see [AWS S3 receivers](#aws-s3-receivers-for-the-otel-collector)). |
| `helm.opentelemetry_collector.awss3_receiver` | `object` | `null` | **Deprecated** — use `awss3_receivers`. Single-receiver form; keeps working throughout v2.x and renders identically to before (bare `awss3` component ID), may be combined with `awss3_receivers` entries, and will only be removed in a future major version. Shape: as an `awss3_receivers` entry, but `enabled` is required. Omit (or leave `null`) to disable. |
| `helm.llm_worker.resources` | `object` | `null` | Kubernetes resource requests/limits for the LLM-worker pods. Same shape as `helm.clickhouse.resources`. Omit to use chart defaults. |
| `trace_export_ingest` | `object` | `null` | Optional trace-export ingest leg — see [Trace-export ingest leg](#trace-export-ingest-leg). Shape: `{ producer_execution_role_arn = string, agent_role_arn = optional(string), bucket_name = optional(string), prefix = optional(string, "traces/"), lifecycle_days = optional(number, 3), kms_key_arn = optional(string) }`. `producer_execution_role_arn` is the external role trusted to assume the writer role (exact ARN or role-name wildcard; literal account ID enforced); the trust condition's `sts:ExternalId` value comes from the separate `trace_export_external_id` variable, which is required when this block is set. `agent_role_arn` optionally grants one additional role `s3:PutObject` on the prefix via the bucket policy. `prefix` accepts multi-segment values (`"traces/tenant-a/"`) and is normalized to one trailing `/`. `kms_key_arn` switches the bucket to SSE-KMS (Bucket Keys on) and widens writer/collector policies accordingly. Unset (default), no resources are created and the plan is unchanged from previous releases. |
| `trace_export_external_id` | `string` (sensitive) | `null` | The `sts:ExternalId` value the external producer supplies when assuming the trace-export writer role (min 8 chars). Required when `trace_export_ingest` is set. Marked `sensitive`, so caller-supplied values are redacted in plan/apply output and CI logs — supply via a `.tfvars` file or `TF_VAR_trace_export_external_id`. Values remain readable in Terraform state — protect state accordingly. |

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
| `clickhouse_node_group` | Identity of the dedicated ClickHouse node group when active: `{ availability_zone, instance_type, size, label = { key, value }, taint = { key, value, effect } }`. Null when not active (`helm.deploy_charts = false`, `cluster.create = false`, or `manage_legacy_clickhouse_node_group = false`). Useful for verifying the resolved AZ during plan/apply review. |
| `trace_export_ingest_bucket` | Name of the trace-export ingest bucket. Null when `trace_export_ingest` is unset. |
| `trace_export_ingest_prefix` | Normalized key prefix the producer must write beneath. Null when `trace_export_ingest` is unset. |
| `trace_export_writer_role_arn` | ARN of the writer IAM role the external producer assumes to upload trace files. Null when `trace_export_ingest` is unset. |
| `trace_export_external_id` | Sensitive echo of the `trace_export_external_id` variable for registration alongside the other outputs. Null when `trace_export_ingest` is unset. |
| `trace_export_ingest_queue_arn` | ARN of the ingest notification SQS queue — hook for queue-depth/oldest-message-age monitoring. Null when `trace_export_ingest` is unset. |
| `trace_export_ingest_queue_name` | Name of the ingest notification SQS queue. Null when `trace_export_ingest` is unset. |

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

## Migrating to v3.0.0

v3.0.0 stops storing ClickHouse passwords in Terraform state. Generation moved to `ephemeral "random_password"` and the Secrets Manager writes moved to `secret_string_wo`. It requires **Terraform >= 1.11**.

> [!WARNING]
> **Applying v3.0.0 without step 2 below silently rotates every ClickHouse password.** Switching to a write-only argument writes on the first apply, and with no supplied value that write is a freshly generated password. ESO will sync it and the running ClickHouse users will change. Neither the plan diff nor a validation block can detect this — a write-only value cannot appear in a plan (that is the point), and detecting "a secret already exists" would require a data source that reads the plaintext straight back into state. **Read the whole procedure before applying.**

The migration is designed to change no password. Supply the current values for one apply; afterwards Terraform rewrites nothing until you bump a version deliberately.

**1. Bump Terraform to >= 1.11** wherever this module is planned and applied. On Terraform Cloud that is the version setting on each workspace.

**2. Read the current passwords and supply them for the migration apply.**

```bash
CLUSTER=<your cluster_name>
for u in admin otel monte-carlo schema-owner llm-worker readonly-user; do
  printf '%s=%s\n' "$u" "$(aws secretsmanager get-secret-value \
    --secret-id "$CLUSTER/clickhouse/$u-credentials" \
    --query SecretString --output text)"
done
```

Build a `.tfvars` (never `-var` on a command line) containing every user your deployment provisions. Omit `admin` / `readonly_user` if they are disabled:

```hcl
clickhouse_passwords = {
  admin         = "..."
  otel          = "..."
  monte_carlo   = "..."
  schema_owner  = "..."
  llm_worker    = "..."
  readonly_user = "..."
}
```

Leave `clickhouse_password_versions` unset — the default of `1` is correct for a migration.

**3. Plan, and check it before applying.** Expect exactly:

- each `random_password.clickhouse_*` **forgotten** (no destroy actions)
- each `aws_secretsmanager_secret_version.clickhouse_*` **updated in place**, gaining `secret_string_wo_version = 1`
- **nothing else** — no node group, EKS, `helm_release`, or PVC/PV changes

**4. Apply, then verify.**

```bash
terraform show -json > /tmp/state.json
make verify-no-plaintext STATE=/tmp/state.json SENTINELS="<the passwords from step 2>"
rm /tmp/state.json
```

Confirm the Secrets Manager values are unchanged, the ClickHouse pods did not restart, and a query as the `monte_carlo` user still succeeds.

**5. Remove the `.tfvars` from step 2.** Later applies do not need it.

### Why later plans look like they regenerate passwords

They do regenerate an ephemeral password every plan — and never write it. The write is gated on `clickhouse_password_versions`, which you have not changed, so the secret keeps its value. This is expected and is not drift.

### Rotating afterwards

Bump the relevant field in `clickhouse_password_versions` and apply. Without a matching `clickhouse_passwords` entry the new value is freshly generated; with one, your supplied value is written. Rotation propagates as: Secrets Manager → ESO resync → the ClickHouse operator re-renders `users.xml`. It requires no SQL — passwords are declared in the operator's `users:` section via `valueFrom.secretKeyRef`, not with `ALTER USER`.

> [!WARNING]
> **Changing a password without bumping its version does nothing, silently.** The version is the only thing that triggers a write. If you edit `clickhouse_passwords.otel` but leave `clickhouse_password_versions.otel` unchanged, the secret keeps its **old** value and the plan shows no diff — Terraform cannot compare a write-only argument, so there is nothing for it to detect or report.
>
> This is the more dangerous of the two footguns in this design, because it fails in the direction of false confidence: you may believe a credential has been rotated and retire the old one while it is still the live password. **Always bump the version in the same change as the password.**

Both footguns are unguardable for the same reason — a write-only value cannot appear in a plan, and detecting the current secret value would require a data source that reads the plaintext straight back into state, defeating the entire change. Documentation is the only control, which is why these two warnings are load-bearing rather than decorative.

## Upgrading

### Upgrading to v2.0.0

**Breaking — the `admin` ClickHouse user is now opt-in.**

Earlier versions always created an `admin` Secrets Manager secret. As of v2.0.0
it is gated behind `helm.clickhouse.admin = { enabled = true }` and is **disabled
by default**. Upgrading and applying without enabling it will:

- delete the existing `<cluster_name>/clickhouse/admin-credentials` secret, and
- make the `clickhouse_admin_credentials_secret_arn` output `null`.

To keep the admin user and its credential, set
`helm.clickhouse.admin = { enabled = true }` before applying.

When admin stays enabled, the upgrade auto-migrates the existing
`aws_secretsmanager_secret.clickhouse_admin_password` (and its secret
version) to the new `[0]` count-indexed address via built-in `moved`
blocks. The state move shown in `terraform plan` is therefore expected
and requires no manual `terraform state mv`.

The full least-privilege user model (the `schema_owner` / `llm_worker` /
`monte_carlo` users and the `helm.clickhouse.otel.restrict_grants` flag) requires
`ao-data-platform` chart **>= 2.0.0**. The module stays compatible with older
charts, which ignore the new per-user values via a transitional dual-wiring of
the `otel` credential. See [Least-privilege ClickHouse users](#least-privilege-clickhouse-users).

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
   the managed node groups then roll to a matching AMI. The pinned stateful
   node groups (ClickHouse and Keeper) are the exception — their AMIs must be
   bumped in the same apply (see [Pinned node group AMIs](#pinned-node-group-amis)
   below).
3. Upgrade on a regular cadence. AWS provides standard support for each minor
   version for a limited window before it moves to (paid) extended support and
   is eventually force-upgraded, so staying within a minor or two of the latest
   avoids a rushed jump.

### Pinned node group AMIs

Every stateful node group pins its AMI — the dedicated ClickHouse node group,
the per-AZ ClickHouse node groups, and the Keeper node groups — while the main
node group tracks the latest EKS-optimized AMI. This split is deliberate:

- **Stateful node groups — pinned (`use_latest_ami_release_version = false`,
  the default on `clickhouse_node_group`, `clickhouse_ha_node_group`, and
  `keeper_node_group`).** These host AZ-locked StatefulSet pods (ClickHouse
  replicas, Keeper voters), so replacing a node means detaching an EBS volume,
  booting a node, and reattaching — a disruption to schedule, not to discover.
  With the upstream EKS default (`use_latest = true`), Terraform re-resolves
  the node group's AMI to AWS's latest recommended build on *every* apply, so
  any apply — even one for an unrelated change — could replace these nodes the
  moment AWS publishes a new AMI; on the clustered topology that could roll
  every Keeper voter or ClickHouse replica from a single unrelated apply.
  Pinning removes that trigger: the AMI changes only when you change it.
- **Main node group — latest (unpinned).** It hosts only stateless workloads,
  which reschedule without downtime, so it keeps AWS's free security
  auto-patching.

`ami_release_version` on each of those variables is the explicit build to pin
to (e.g. `"1.35.5-20260527"`). Leaving it `null` (the default) still prevents
drift — nodes keep whatever AMI they already run — but records no specific
version. Set an explicit build to make the pin auditable and to perform
deliberate updates.

**Pinning makes AMI patching your responsibility.** AWS will not patch a pinned
node for you, so:

1. **Update on a schedule** — monthly is a good default, quarterly a sensible
   floor — to pick up kernel / OS / container-runtime security fixes, and
   out-of-band for a critical node-level CVE. Each update replaces the affected
   nodes (a ~2 min bounce for a single-replica ClickHouse; rolling and
   availability-preserving on the clustered topology — see below), so run it in
   a maintenance window. The point of pinning is to control *when* that bounce
   happens, not to patch less often.
2. **Don't let the pin go stale.** AWS eventually deprecates and then disables old
   AMI builds; a very old pin can become unlaunchable, which would break node
   replacement and scale-out. A monthly/quarterly cadence keeps you clear of that.
3. **Find the current recommended build** for your cluster's Kubernetes version:
   ```bash
   aws ssm get-parameter \
     --name /aws/service/eks/optimized-ami/<kubernetes_version>/amazon-linux-2023/x86_64/standard/recommended/release_version \
     --query Parameter.Value --output text
   ```

To update an AMI, set the corresponding `ami_release_version` and apply. The
update mechanics differ deliberately between the node-group classes:

- **Dedicated (single-instance) ClickHouse node group**
  (`clickhouse_node_group.ami_release_version`): the node is replaced exactly
  once, and the apply completes even with a single ClickHouse replica — the
  module sets `force_update_version = true` on this node group, so the update
  proceeds past any disruption budget. This is the single-replica downtime
  documented in the "Dedicated ClickHouse node group" section.
- **Keeper and per-AZ ClickHouse node groups**
  (`keeper_node_group.ami_release_version`,
  `clickhouse_ha_node_group.ami_release_version`): these set
  `force_update_version = false` — updates evict pods through the eviction API,
  governed by the operator-created PodDisruptionBudgets (`maxUnavailable: 1`),
  never force-terminating. Each field covers every node group of its class, so
  one bump updates (for example) all three Keeper node groups in a single
  apply; the disruption budget serializes the evictions so at most one voter
  (or one ClickHouse replica) is down at any moment — the other node-group
  updates wait and retry rather than proceeding in parallel. Keeper quorum and
  ClickHouse availability hold throughout.

**Kubernetes minor upgrades with pinned node groups.** A node group's Kubernetes
version and its AMI build must share a minor — EKS rejects, for example, a
`1.35.x` AMI on a `1.36` node group. So when you bump `kubernetes_version`, bump
**every pinned `ami_release_version` in use** — `clickhouse_node_group`, and on
the clustered topology also `clickhouse_ha_node_group` and `keeper_node_group` —
to a matching-minor build **in the same apply**. Leaving any pinned node group
on the old minor fails the apply. The module does not expose a per-node-group
Kubernetes version, so the control plane and all pinned node groups move
together; coupling the values in one apply replaces each node once.

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
make test           # variable-validation tests (requires Terraform >= 1.11)
```

`make test` runs `terraform test` against `tests/*.tftest.hcl`. Tests cover the input safety nets (`cluster.main_node_group_size` range, the existing-cluster guard) using `mock_provider` — see the test file's preamble for the explicit scope and known coverage gaps. The module requires `required_version >= 1.11`, which already exceeds the `mock_provider` floor of 1.7, so no separate dev-tool requirement applies.

To release a new version, create and push a tag: `git tag v0.1.0 && git push origin v0.1.0`

## License

See [LICENSE](LICENSE).

## Security

See [SECURITY.md](SECURITY.md).
