# terraform-aws-ao-data-platform

Terraform module that deploys the Monte Carlo Agent Observability data platform on AWS. Provisions a full pipeline from OTel Collector through to ClickHouse on EKS, ready for the MC Agent to connect to.

**What gets deployed:**
- EKS cluster + VPC (or targets an existing cluster)
- ClickHouse (via `ao-data-platform` Helm chart)
- OTel Collector (via `ao-data-platform` Helm chart)
- Cluster controllers: AWS Load Balancer Controller, cert-manager, External Secrets Operator, external-dns
- ACM certificates, Route 53 records, IAM/IRSA roles, Secrets Manager secrets

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.11 — required for the write-only arguments the ClickHouse secret sinks declare (used when `clickhouse_write_only = true`; the floor binds either way)
- Providers: `hashicorp/aws` >= 6.50, `hashicorp/random` >= 3.7, `hashicorp/helm` ~> 2.0, `hashicorp/kubernetes` ~> 2.0
  - The `aws` and `random` floors also rose in v3.0.0. An existing consumer's `.terraform.lock.hcl` will be pinned below them, so run `terraform init -upgrade` once before planning — see [Upgrading to v3.0.0](#upgrading-to-v300).
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for cluster access
- [jq](https://jqlang.github.io/jq/) — for `hack/verify-no-plaintext.sh` (the state verification step in the v3.0.0 upgrade) and `hack/rotation-check.sh` (see [Rotating a ClickHouse password](#rotating-a-clickhouse-password))

> **Note:** `terraform apply` runs `local-exec` provisioners that invoke `aws eks update-kubeconfig` (needed to `kubectl wait` for ESO CRDs and apply the ClusterSecretStore). This modifies the `~/.kube/config` of the machine running Terraform: the cluster's context is added (or refreshed) and becomes the current context.

## Usage

The `kubernetes` and `helm` providers must be configured in your root module using this module's outputs. This enables a single-pass `terraform apply` — Terraform automatically defers Kubernetes/Helm resources until after the EKS cluster is provisioned.

> **Note:** Pin the `helm` provider to `~> 2.0`. The examples below use its v2 configuration syntax (the nested `kubernetes { ... }` block); helm provider v3 changed this to a top-level `kubernetes` argument and is not yet supported.

### Full deployment (new VPC + new cluster)

```hcl
terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.50" }
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
  version = "~> 3.0"

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
  version = "~> 3.0"

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
  version = "~> 3.0"

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
  version = "~> 3.0"

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
  version = "~> 3.0"

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
  version = "~> 3.0"

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

For each provisioned user the module generates a 32-character password (or uses the matching `clickhouse_passwords.*` override), stores it in Secrets Manager KMS-encrypted with the pipeline key, grants the External Secrets Operator read access, and forwards the per-user `externalSecret` config into the chart so ESO syncs the password into Kubernetes. Each user's secret ARN is exposed as a `clickhouse_*_credentials_secret_arn` output. As of v3.0.0, setting `clickhouse_write_only = true` makes generation ephemeral and the write use write-only arguments, so no password is stored in Terraform state or plan files; the override variable is `clickhouse_passwords_wo` on that path. See [Upgrading to v3.0.0](#upgrading-to-v300).

Each user additionally gets a `<slug>-previous-credentials` secret, which holds the outgoing password for the duration of a rotation and the sentinel `-` the rest of the time — that overlap is what makes a rotation lock nobody out. See [Rotating a ClickHouse password](#rotating-a-clickhouse-password).

- Set `helm.clickhouse.otel.restrict_grants = true` to tighten the `otel` ingest user to `INSERT`-only on the telemetry source tables. Flip this only after any external readers have moved to the `monte_carlo` user — see [Upgrading to v2.0.0](#upgrading-to-v200).
- Enable the gated break-glass `admin` superuser with `helm.clickhouse.admin = { enabled = true }`. It is reachable only over loopback by default (i.e. via `kubectl exec` into the ClickHouse pod). Disabled by default; when disabled no admin secret is created and `clickhouse_admin_credentials_secret_arn` is `null`.

**Requires `ao-data-platform` chart >= 2.0.0.** Older charts silently ignore the per-user values; the module stays compatible with them via a transitional dual-wiring of the `otel` credential.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 3.0"

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

- Generates a 32-character random password (or uses a caller-supplied `clickhouse_passwords.readonly_user` / `clickhouse_passwords_wo.readonly_user` instead) and stores it in Secrets Manager at `<cluster_name>/clickhouse/readonly-user-credentials`, KMS-encrypted with the existing pipeline key.
- Extends the External Secrets Operator IRSA policy so ESO can read the new secret.
- Forwards `clickhouse.readonlyUser.{enabled, externalSecret.*}` into the `ao-data-platform` chart values; the chart provisions the SQL user and a second ExternalSecret that syncs the password from Secrets Manager into K8s.

The provisioned secret ARN is exposed as `clickhouse_readonly_user_credentials_secret_arn`.

**Requires `ao-data-platform` chart >= 1.2.0.** Older chart versions silently ignore the `clickhouse.readonlyUser` values key — the Secrets Manager secret is created by terraform, but no SQL user is provisioned by the chart. Pin `helm.chart_version` accordingly when enabling.

Leave `helm.clickhouse.readonly_user` unset (or `null`) to disable; existing consumers are unaffected.

```hcl
module "ao_data_platform" {
  source  = "monte-carlo-data/ao-data-platform/aws"
  version = "~> 3.0"

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

  # Optional; omit to auto-generate the password. On a deployment that has set
  # clickhouse_write_only = true, use clickhouse_passwords_wo instead — the two
  # are mutually exclusive and the wrong one for the active path is rejected at
  # plan time. See "Upgrading to v3.0.0".
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
  version = "~> 3.0"

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
  version = "~> 3.0"

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
| `helm.clickhouse.admin` | `object` | `null` | Optionally provisions the gated break-glass superuser (`admin`). Shape: `{ enabled = bool }`. When `enabled = true`, a Secrets Manager secret + ExternalSecret pipeline is created and the chart's admin user is enabled (loopback-only by default — reachable only via pod-exec); the password comes from `clickhouse_passwords.admin` — or `clickhouse_passwords_wo.admin` when `clickhouse_write_only = true` — or is auto-generated. When disabled (default), no admin secret is created. **Requires chart version >= 2.0.0.** Omit (or `null`) to disable. |
| `helm.clickhouse.readonly_user` | `object` | `null` | Optionally provisions a second SELECT-only ClickHouse user (`readonly_user`, profile `readonly`). Shape: `{ enabled = bool }`. When `enabled = true`, a Secrets Manager secret + ExternalSecret pipeline mirroring the otel user is created and the toggle is forwarded to the chart; the password comes from `clickhouse_passwords.readonly_user` — or `clickhouse_passwords_wo.readonly_user` when `clickhouse_write_only = true` — or is auto-generated. **Requires chart version >= 1.2.0.** Omit (or `null`) to disable. |
| `clickhouse_write_only` | `bool` | `false` | Opts **this deployment** into the write-only ClickHouse password path: passwords are generated by `ephemeral "random_password"` and written through `secret_string_wo`, so none reaches Terraform state or plan files. At the default of `false` the module keeps the legacy path (managed `random_password` + `secret_string`, passwords in state) — so **adopting v3.0.0 changes nothing until you set this**. The flag lives in the module so a fleet sharing one module pin can migrate one deployment at a time. Setting it rewrites every ClickHouse secret on that apply: supply the deployment's current passwords via `clickhouse_passwords_wo` in the **same** apply, or each is silently replaced by a generated value. Once set, leave it set — it is the deployment's steady state. Selects which password variable is used: `false` → `clickhouse_passwords`, `true` → `clickhouse_passwords_wo`. **Transitional**: to be retired once every consumer has opted in. Must stay a statically known value (a literal or another variable) — the path-selecting locals rely on the conditional short-circuiting, which Terraform only does for a known predicate. See [Upgrading to v3.0.0](#upgrading-to-v300). |
| `clickhouse_passwords` | `object` (sensitive) | `{}` (all auto-generated) | Passwords for the ClickHouse SQL users on the **legacy path only** (`clickhouse_write_only = false`, the default). Setting any field while the flag is `true` is **rejected at plan time** by a cross-variable `validation` — not ignored — because on that path the variable is never read and silently ignoring it would regenerate every password; move the values to `clickhouse_passwords_wo`. Shape: `{ admin = optional(string), otel = optional(string), monte_carlo = optional(string), schema_owner = optional(string), llm_worker = optional(string), readonly_user = optional(string) }`. Any field left null is auto-generated; an empty string is treated as supplied and written through as an empty secret, exactly as in v2.4.2 (the write-only variable differs — there `""` means "generate one"). Marked `sensitive`, so caller-supplied values are redacted in plan/apply output and CI logs — supply via a `.tfvars` file you do not commit, or `TF_VAR_clickhouse_passwords` / a sensitive workspace variable for VCS-driven runs. Stored in Secrets Manager and synced into the cluster by ESO; never passed through Helm values. **Not** `ephemeral`, and cannot be: an ephemeral value may not feed `secret_string`, which is an ordinary argument. Terraform state therefore still contains these values — protect state accordingly, or opt into the write-only path. |
| `clickhouse_passwords_wo` | `object` (sensitive, ephemeral) | `{}` (all auto-generated) | Passwords for the ClickHouse SQL users on the **write-only path only** (`clickhouse_write_only = true`). Setting any field while the flag is unset is **rejected at plan time** — not ignored — by the mirror of the guard on `clickhouse_passwords`. Same shape as `clickhouse_passwords`. Any field left null **or set to the empty string** is auto-generated (an empty ClickHouse password is never a legitimate input). This is the variable you hand a deployment's current passwords to on the apply that opts in. Marked `sensitive` **and** `ephemeral`, so values are omitted from state and plan files entirely — which matters concretely if your CI archives a saved plan (`-out=`), since a non-ephemeral variable would put live passwords in that artifact. Ephemeral variables accept ordinary values, so supply it exactly like the legacy variable (`.tfvars` you do not commit, or `TF_VAR_clickhouse_passwords_wo`); Terraform requires it to be re-supplied on `apply <saved-plan>`, so a plan/apply split cannot lose it. The provider does still read the secret during plan/refresh (aws #42383), so plan-time IAM is unchanged. |
| `clickhouse_password_versions` | `object` | `{}` (all `1`) | Version counter per ClickHouse user driving each secret's `secret_string_wo_version`. **Write-only path only** — the version companion is rendered solely when `clickhouse_write_only = true`, and this variable has no effect on the legacy path (where Terraform tracks `secret_string` and detects changes to it normally). Shape: `{ admin = optional(number, 1), otel = optional(number, 1), monte_carlo = optional(number, 1), schema_owner = optional(number, 1), llm_worker = optional(number, 1), readonly_user = optional(number, 1) }`. Because a write-only password is invisible to Terraform it cannot detect drift on it — the secret is rewritten **only** when the matching version changes. This is the rotation lever: bump one field to rotate one user, all six to rotate the deployment. Bumping a field without supplying the matching `clickhouse_passwords_wo` value writes a freshly generated password. |
| `clickhouse_previous_passwords` | `object` (sensitive) | `{}` (all sentinel) | The **previous** password per ClickHouse user, kept valid alongside the current one for the duration of a rotation — **legacy path only** (`clickhouse_write_only = false`). Setting any field while the flag is `true` is **rejected at plan time**, mirroring the guard on `clickhouse_passwords`. Same object shape as `clickhouse_passwords`. A field left null (the default) writes the sentinel `-` into the user's previous-password secret, which renders single-method auth — the behavior before this variable existed. Set a field only for the rotation window: supply the user's **current live** password here on the apply that mints a new one, then clear it on the cleanup apply. Both applies bump the matching `clickhouse_password_versions` field, which drives both of the user's sinks. Sensitive but not `ephemeral` (an ephemeral value cannot feed `secret_string`), so on this path the value is in state. **Requires chart >= 5.0.0 to have any server-side effect**; older charts ignore it. See [Rotating a ClickHouse password](#rotating-a-clickhouse-password). |
| `clickhouse_previous_passwords_wo` | `object` (sensitive, ephemeral) | `{}` (all sentinel) | The **previous** password per ClickHouse user on the **write-only path only** (`clickhouse_write_only = true`). Setting any field while the flag is unset is **rejected at plan time**, mirroring `clickhouse_passwords_wo`. Semantics match `clickhouse_previous_passwords`; `ephemeral` as well as `sensitive`, so the value reaches neither state nor a saved plan file. Supply via a `.tfvars` file you do not commit or `TF_VAR_clickhouse_previous_passwords_wo` — never `-var` on a command line. See [Rotating a ClickHouse password](#rotating-a-clickhouse-password). |
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
| `clickhouse_<user>_previous_credentials_secret_arn` | One per user (`admin`, `otel`, `monte_carlo`, `schema_owner`, `llm_worker`, `readonly_user`): Secrets Manager ARN of that user's **previous**-password secret, which holds the outgoing password during a rotation and the sentinel `-` otherwise. The `admin` and `readonly_user` ones are null when the matching user is disabled. See [Rotating a ClickHouse password](#rotating-a-clickhouse-password). |
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

## Rotating a ClickHouse password

A rotation keeps the **outgoing** password valid alongside the new one for as long as the cutover takes, so no client is ever locked out by the moment of the rotation itself. Each user has two Secrets Manager secrets — `<cluster>/clickhouse/<slug>-credentials` (the current password, "A") and `<cluster>/clickhouse/<slug>-previous-credentials` (the overlap password, "B") — which the chart assembles into ClickHouse's `<auth_methods>` list. Outside a rotation B holds the sentinel `-` and the server has exactly one method, as it always did.

**Requires `ao-data-platform` chart >= 5.0.0.** Older charts ignore the previous-password values entirely: the B secrets are written and never read, which is what makes adopting this module version inert. Supply `clickhouse_previous_passwords_wo` on the write-only path (`clickhouse_write_only = true`) or `clickhouse_previous_passwords` on the legacy path — the same mutually-exclusive pairing as the current-password variables.

> [!IMPORTANT]
> Three invariants hold for the whole rotation window — from the rotate apply until cleanup has been verified:
>
> - **Retain both passwords.** Every failure below recovers with one re-apply *as long as you still have both values*. Do not discard the old one when the new one goes live.
> - **Never roll the chart back between rotation start and cleanup.** A pre-5.0.0 chart renders single-method auth, which kills the old password instantly for everyone still holding it.
> - **Never edit a users.d fragment's `include_from` on a running cluster.** A missing `include_from` target is fatal at container start — the pod crash-loops rather than starting with a degraded config.

### The sequence

Rotating one user (`otel` here) is five steps. Rotating all six is the same steps with six fields set instead of one.

**1. Capture a baseline.** Records each secret's `AWSCURRENT` version ID and a sha256 digest, so the post-apply check can prove a write actually happened. The file holds no passwords and lands mode `600`.

```bash
make rotation-check CLUSTER=ao-dev-us1 SLUG=otel
# → baseline written to ao-dev-us1-otel-rotation-baseline.txt
```

**2. The rotate apply.** Read the live password out of Secrets Manager, supply it as the *previous* password, choose the new one, and bump the version — all in one change:

```bash
aws secretsmanager get-secret-value \
  --secret-id ao-dev-us1/clickhouse/otel-credentials \
  --query SecretString --output text          # this is P1; keep it out of shell history
```

```hcl
clickhouse_password_versions     = { otel = 2 }      # was 1 — the only thing that triggers a write
clickhouse_previous_passwords_wo = { otel = "<P1>" } # the outgoing password, kept valid
clickhouse_passwords_wo          = { otel = "<P2>" } # the new one; omit to have one generated
```

Supply these through a `.tfvars` file you do not commit, or `TF_VAR_clickhouse_previous_passwords_wo` / `TF_VAR_clickhouse_passwords_wo` — never `-var` on a command line. Then `terraform apply`. The module writes B before A, so the overlap password is in place before the current one moves.

> [!WARNING]
> **Choose `<P2>` explicitly rather than letting it be generated, or read it back out of Secrets Manager before step 5.** The cleanup apply bumps the same version field, which rewrites *both* sinks — so it needs the live current password re-supplied. Terraform cannot read a write-only value back, and with `clickhouse_passwords_wo.otel` left null the cleanup would mint a *third* password with no overlap left, locking out every client that had just moved to `P2`.

**3. Make it live and verify it.** A secret change alone does **not** reload ClickHouse's users config — Kubernetes swaps a symlink under the mount, which defeats the server's substitution-source watcher. The check below force-syncs the ExternalSecret, waits for the kubelet mount refresh, issues `SYSTEM RELOAD CONFIG` on every ClickHouse pod (instant, restartless, no dropped connections), and then authenticates as the rotated user with *both* passwords:

```bash
make rotation-check CLUSTER=ao-dev-us1 SLUG=otel \
  BASELINE=ao-dev-us1-otel-rotation-baseline.txt
```

Exit `0` means the write landed and both methods are live on every pod. Exit `1` means either the write never happened (the version bump was forgotten — the apply succeeds silently in that case) or the expected auth state is not live after the reload. **Do not proceed to step 4 until this passes**; rolling clients against a server that never learned `P2` is what turns a no-op into an outage. Needs `kubectl` pointed at the cell and AWS credentials that can read the ClickHouse secrets, plus the `admin` user enabled — it is the reload and probe user.

**4. Roll the clients, unhurried.** Any mix of `P1` and `P2` holders is valid for as long as this takes. In-cluster consumers pick up `P2` on their next pod start (roll the collector and llm-worker deliberately, or let churn do it); the schema job gets it at its next helm upgrade; external consumers cut over on their own schedule.

**5. The cleanup apply.** Once the checklist says everyone has moved, bump the version again, re-supply the now-current password, and clear the previous one:

```hcl
clickhouse_password_versions     = { otel = 3 }      # was 2
clickhouse_previous_passwords_wo = {}                # back to the sentinel "-"
clickhouse_passwords_wo          = { otel = "<P2>" } # unchanged value, re-supplied
```

Apply, then re-run the check — capture a fresh baseline first, since the version IDs moved in step 3:

```bash
make rotation-check CLUSTER=ao-dev-us1 SLUG=otel     # fresh baseline
# ... apply ...
make rotation-check CLUSTER=ao-dev-us1 SLUG=otel BASELINE=ao-dev-us1-otel-rotation-baseline.txt
```

With B back to the sentinel the check inverts its last assertion: the old password must now be **rejected**. That rejection is the proof that the second auth method is really gone.

### When to run cleanup

There is no technical signal for "everyone has moved off the old password." ClickHouse's session and query logs record the authentication *type*, not which of a user's listed methods matched, so the server cannot tell you whether anything still holds `P1`. Cleanup is therefore gated on an operational checklist plus soak time, not on a query.

Erring late is cheap: the overlap costs nothing while it sits, and the failure mode of erring early is loud and fast to undo — a straggler gets `AUTHENTICATION_FAILED`, and re-supplying the previous password restores it within minutes.

### Rotating on the legacy path

Deployments still on `clickhouse_write_only = false` rotate the same way, with `clickhouse_previous_passwords` and `clickhouse_passwords` in place of the `_wo` variables. Two differences: there is no version lever (Terraform tracks `secret_string` directly, so editing the value is detected and written like any other argument — leave `clickhouse_password_versions` alone), and both passwords land in Terraform state, which is what the write-only path exists to fix. Step 2's "read the live password first" is also unnecessary — it is already in your configuration.

## Upgrading

### Upgrading to v3.0.0

v3.0.0 can keep ClickHouse passwords out of Terraform state: generation moves to `ephemeral "random_password"` and the Secrets Manager writes move to `secret_string_wo`. **That path is opt-in per deployment**, via the new `clickhouse_write_only` flag.

> [!IMPORTANT]
> **v3.0.0 is inert on adoption.** With `clickhouse_write_only` at its default of `false`, the module behaves exactly as v2.4.2 did — managed `random_password` generators, ordinary `secret_string`, and no `secret_string_wo_version` at all. Bumping the module version rewrites no secret and rotates no password.
>
> That is the point of the flag living in the module rather than in your root module: a fleet that shares **one module pin across many deployments** cannot stage the version bump per deployment, so a fleet-wide bump would otherwise migrate every deployment at once. Adopt the version everywhere first, then opt deployments in one at a time.

**Breaking changes on adoption** — i.e. what bumping the version alone requires. There is exactly one, and it is a toolchain constraint rather than a behavior change:

- **Version floors rise**: Terraform **>= 1.11** (write-only arguments), `hashicorp/aws` **>= 6.50** and `hashicorp/random` **>= 3.7**. The module declares `secret_string_wo` on every ClickHouse secret version regardless of the flag, so these floors bind on the legacy path too. Every existing consumer's `.terraform.lock.hcl` is pinned below the provider floors, so the first command fails on a lock/constraint error until you run `terraform init -upgrade`. If your own root module pins the AWS provider below 6.50 — e.g. `version = "= 6.20.0"` — that pin has to be raised first; no `init -upgrade` can satisfy two conflicting constraints.

**The three credential variables, and which path each serves**

| Variable | Path | Ephemeral? | Notes |
| --- | --- | --- | --- |
| `clickhouse_write_only` | — | n/a | `bool`, default `false`. The per-deployment opt-in. **Transitional**: it exists so deployments migrate individually, and should be retired once every consumer has opted in. Must stay a statically known value. |
| `clickhouse_passwords` | **legacy only** (flag `false`) | No — `sensitive` only | Unchanged from v2.4.2, including its treatment of `""` (written through as an empty secret). It cannot be ephemeral: an ephemeral value may not feed `secret_string`, which is an ordinary argument. **Rejected at plan time** if set while the flag is `true`. |
| `clickhouse_passwords_wo` | **write-only only** (flag `true`) | **Yes** — `sensitive` + `ephemeral` | New in v3.0.0, same object shape. Differs from the legacy variable in one respect: `""` means "generate one" rather than "write an empty secret". **Rejected at plan time** if set while the flag is unset. |

Neither password variable is silently ignored on the wrong path — each carries a cross-variable `validation` that rejects it, because ignoring it is what rotates six live credentials while the operator believes they supplied them.

`clickhouse_password_versions` also serves the write-only path only: the version companion is rendered solely when the flag is set, and the variable has no effect on the legacy path.

Only `clickhouse_passwords_wo` is `ephemeral`, and that is load-bearing rather than cosmetic. A CI pipeline that plans with `-out=` and archives the plan file (to S3, or as a build artifact) would otherwise ship live ClickHouse passwords inside it; an ephemeral variable's value is not in the plan file at all. Ephemeral variables accept ordinary values, so supplying one is no different in practice.

#### Adopting v3.0.0 (fleet-wide)

**1. Identify any deployment that has ALREADY applied a write-only build, and opt it in as part of the same change.**

> [!CAUTION]
> **A deployment whose state already went through a write-only apply must set `clickhouse_write_only = true` in the very change that adopts v3.0.0 — never afterwards.** For such a deployment the flag's default is the dangerous setting, not the safe one, so it is the exception to "inert on adoption".
>
> Its state has `secret_string_wo_version = 1`, no managed `random_password` resources, and `secret_string = ""`. Adopting this module with the flag unset puts it back on the legacy path: Terraform would create six generators and write six freshly generated passwords, rotating every live ClickHouse credential — the same incident this release exists to prevent, on the one deployment that had already been migrated.
>
> Check before adopting, per deployment:
>
> ```bash
> terraform state show \
>   'module.ao_data_platform.aws_secretsmanager_secret_version.clickhouse_otel_password' \
>   | grep -E 'secret_string_wo_version|has_secret_string_wo'
> ```
>
> A non-null `secret_string_wo_version` (or `has_secret_string_wo = true`) means that deployment is already on the write-only path. In the same commit that bumps the module version: set `clickhouse_write_only = true` for it, **and remove its `clickhouse_passwords` entries if it has any** — the two are mutually exclusive and a leftover entry fails the plan (see step 4's note). Then skip to step 5. Its passwords are already correct in Secrets Manager and its version counters are already at 1, so it needs no password supplied and expects a no-op plan.
>
> If you have already adopted with the flag unset but have **not applied**, set the flag before applying; if you have applied, treat it as a rotation and recover the credentials from Secrets Manager.

**2. Raise the floors** wherever this module is planned and applied: Terraform to >= 1.11, and any AWS/random provider constraints in your own root module to allow `aws >= 6.50` and `random >= 3.7`. On Terraform Cloud, Terraform's version is the version setting on each workspace.

**3. Re-resolve the provider locks.**

```bash
terraform init -upgrade
```

Without this, the run fails before you ever see a plan: the existing `.terraform.lock.hcl` pins providers that no longer satisfy the module's constraints. Commit the updated lock file. On Terraform Cloud, either run this locally and commit the lock, or let the workspace's next run pick it up — a stale committed lock will keep failing.

Steps 1–3 are the whole of adoption. Everything below is per deployment, and nothing below happens until you set the flag.

#### Opting a deployment into the write-only path

> [!WARNING]
> **Setting `clickhouse_write_only = true` without supplying that deployment's current passwords silently rotates every ClickHouse password.** The flip writes every secret once, and with no supplied value that write is a freshly generated password. ESO will sync it and the running ClickHouse users will change. The plan diff will not warn you: a write-only value cannot appear in a plan (that is the point). The module does reject the adjacent mistake — supplying the passwords through the wrong variable for the active path — but nothing can compare a write-only value against the live secret, so *omitting* the passwords entirely is not caught; see [Why there is no plan-time guard](#why-there-is-no-plan-time-guard). **Read the whole procedure before applying.**

The opt-in is designed to change no password. Set the flag and supply the current values in the same apply; afterwards Terraform rewrites nothing until you bump a version deliberately. Do one deployment at a time and verify each before moving on.

**4. Read the current passwords and supply them, together with the flag, in one apply.**

Do not hand-construct the secret names. Secrets are named from the module's *effective* cluster name, which is `cluster.existing_cluster_name` whenever `cluster.create = false` — building `<cluster_name>/clickhouse/...` by hand returns `ResourceNotFoundException` on every existing-cluster deployment. Drive off the module's own ARN outputs instead. That also skips `admin` and `readonly_user` automatically when they are disabled, because their ARN output is `null`:

```bash
for u in admin otel monte_carlo schema_owner llm_worker readonly_user; do
  arn="$(terraform output -raw "clickhouse_${u}_credentials_secret_arn" 2>/dev/null)" || continue
  [ -n "$arn" ] || continue
  printf '%s=%s\n' "$u" "$(aws secretsmanager get-secret-value \
    --secret-id "$arn" --query SecretString --output text)"
done
```

This prints live credentials to your terminal — run it somewhere that is not shared, recorded, or shipping its scrollback to a log collector. If your root module does not re-export these outputs, add passthrough `output` blocks for the users you provision (see [After Deployment](#after-deployment) for the output names), or read the ARNs with `terraform state show 'module.<name>.aws_secretsmanager_secret.clickhouse_otel_password'`.

Now make three changes **in one commit**: set `clickhouse_write_only = true`, move the values into `clickhouse_passwords_wo`, and **remove this deployment's existing `clickhouse_passwords` entries**.

> [!IMPORTANT]
> **Removing the old `clickhouse_passwords` entries is part of this step, not cleanup afterwards.** The two variables are mutually exclusive: `clickhouse_passwords` serves the legacy path only, and setting it while the flag is `true` is **rejected at plan time**, not ignored. If your deployment supplies its passwords today — the common case — leaving those entries in place makes step 5's plan fail outright:
>
> ```
> clickhouse_passwords serves the legacy path only and is ignored when
> clickhouse_write_only = true, so setting both would silently regenerate every
> password. Move these values to clickhouse_passwords_wo.
> ```
>
> The rejection is deliberate — silently ignoring the entries is how an operator supplies the current passwords, believes the deployment is safe, and rotates all six anyway. It costs you a failed plan rather than an incident, and the failure is loud, before any apply. But it does mean "move these values" is literal: **rename the variable, do not add the new one alongside the old.**

Use whichever channel fits how you run Terraform. Never `-var` on a command line.

- **Local runs:** a `.tfvars` file, containing only the users your deployment provisions:

  ```hcl
  clickhouse_write_only = true

  # Renamed from clickhouse_passwords — the old entries must be gone, not
  # merely superseded.
  clickhouse_passwords_wo = {
    admin         = "..."
    otel          = "..."
    monte_carlo   = "..."
    schema_owner  = "..."
    llm_worker    = "..."
    readonly_user = "..."
  }
  ```

  > [!WARNING]
  > **Do not commit this file.** Add it to `.gitignore` first, write it outside the repository, or use one of the options below. Committing it writes production ClickHouse passwords into git history irreversibly — during the one procedure whose entire purpose is removing plaintext.

- **VCS-driven or Terraform Cloud runs:** do not create a tfvars file for the passwords. There is no safe place to put one in a repository that a run reads from. Use `TF_VAR_clickhouse_passwords_wo` in the run environment, or a **sensitive workspace variable** of category *terraform* named `clickhouse_passwords_wo` holding the same HCL object. Both keep the value out of version control. Delete it after step 7. Delete any existing `TF_VAR_clickhouse_passwords` / `clickhouse_passwords` workspace variable **now** — a leftover one fails the plan, per the note above. `clickhouse_write_only` is not a secret — commit it in the deployment's own configuration, where it stays (step 8).
- **CI other than TFC:** export `TF_VAR_clickhouse_passwords_wo` from your secret store for the single opt-in run.

Leave `clickhouse_password_versions` unset — the default of `1` is correct for the opt-in.

**5. Plan, and check it before applying.** Expect exactly:

- each `aws_secretsmanager_secret_version.clickhouse_*` **updated in place**: `- secret_string -> null` and `+ secret_string_wo_version = 1`. In-place is the whole point — a destroy/create would leave a window in which ESO cannot fetch the secret
- each `random_password.clickhouse_*` **that exists** in this deployment's state **destroyed**. Its `count` goes to 0, which is how the plaintext leaves state. `random_password` is a logical resource, so this destroys nothing in AWS and touches no live credential. A user whose password you had always supplied never had a generator, and a disabled gated user never had one either — so expect between zero and six destroy lines, not always six
- **nothing else** — no node group, EKS, `helm_release`, or PVC/PV changes

> [!NOTE]
> **The plan-then-apply split cannot silently lose the passwords you supplied.** Because `clickhouse_passwords_wo` is an ephemeral variable, applying a saved plan without re-supplying it is refused outright rather than treated as "no value" (verified on Terraform 1.12.2, on the equivalent variable):
>
> ```
> The ephemeral input variable "clickhouse_passwords_wo" was set during the plan phase,
> and so must also be set during the apply phase.
> ```
>
> Terraform therefore guards the worst footgun in this design for free. The practical consequence: if you plan with `-out=saved.tfplan`, you must pass the same `-var-file=` (or export the same `TF_VAR_clickhouse_passwords_wo`) on `terraform apply saved.tfplan` as well, or the apply errors out mid-migration.

**6. Apply, then verify the state has no plaintext.**

Put the passwords in a file, one per line — not on the command line, where they land in shell history and in `ps` argv:

```bash
umask 077
cat > /tmp/sentinels.txt   # one password per line, then Ctrl-D

terraform show -json > /tmp/state.json
.terraform/modules/ao_data_platform/hack/verify-no-plaintext.sh \
  /tmp/state.json --sentinel-file /tmp/sentinels.txt

rm -f /tmp/state.json /tmp/sentinels.txt
```

The script ships with the module, so a Registry consumer runs it from where Terraform unpacked it: `.terraform/modules/<module block name>/hack/verify-no-plaintext.sh` (`ao_data_platform` above — substitute your own `module` label, or check `.terraform/modules/modules.json` for the exact directory). It needs `jq` and nothing else, never echoes a sentinel's value, and reports:

- exit **0** — no plaintext, and every ClickHouse secret version shows `has_secret_string_wo = true`, i.e. the write really did go through the write-only path
- exit **1** — plaintext found: a `secret_string` argument, a surviving managed `random_password`, or one of your sentinels present in the state
- exit **2** — usage or input problem (missing file, empty or malformed JSON) — never a silent pass
- exit **3** — no plaintext, but the write-only path could not be proven. During a migration this means the write did not happen, not that you are safe

On Terraform Cloud, use `terraform state pull > /tmp/state.json` instead of `show -json`. From a checkout of this repository, `make verify-no-plaintext STATE=/tmp/state.json SENTINEL_FILE=/tmp/sentinels.txt` is the same check.

Then confirm the Secrets Manager values are unchanged, the ClickHouse pods did not restart, and a query as the `monte_carlo` user still succeeds.

**7. Remove the `clickhouse_passwords_wo` values you supplied in step 4** — the `.tfvars` entry, the environment variable, or the workspace variable. Later applies do not need them; the secrets are written and the version counters hold at 1.

The old `clickhouse_passwords` entries are already gone — removing them was part of step 4, because the plan would not have succeeded otherwise. Nothing further to clean up here.

**8. Leave `clickhouse_write_only = true` in place, permanently.** Unlike a caller-side staging flag, this one is the deployment's steady state, not a temporary switch. Keep it in the deployment's committed configuration, and repeat steps 4–8 for the next deployment.

> [!WARNING]
> **Unsetting the flag on its own does not roll back — it wedges the deployment.** Clearing `clickhouse_write_only` without supplying passwords moves the deployment onto the legacy path, and that apply **fails partway through**, inside the AWS provider:
>
> ```
> produced an invalid new value for .secret_binary:
> inconsistent values for sensitive attribute. This is a bug in the provider
> ```
>
> The failure lands *after* the password generators are created but *before* any secret is rewritten. So it rotates nothing — the live credentials survive — but it leaves freshly generated plaintext in Terraform state and, because every later apply re-plans the same transition, **every subsequent apply of this root fails too** until the flag is restored. Restoring it recovers cleanly: the plan becomes generator destroys only, and no secret is touched. *(Verified against AWS, provider v6.50.)*
>
> **The supported rollback is to supply the passwords in the same apply.** Treat it exactly like step 4 in reverse, and make all three changes in one commit: read the current values out of Secrets Manager first (the same loop as step 4), **clear `clickhouse_passwords_wo`**, and supply the values via **`clickhouse_passwords`** — the legacy variable — in the *same* apply that unsets the flag. This path is verified to work and it preserves every credential.
>
> Note it takes a different shape than the opt-in did: supplying a known value makes Terraform **replace** the secret version (`1 to add, 1 to destroy`) rather than update it in place, so there is a brief moment with no current version. Harmless for a deliberate rollback, but do it in a maintenance window if a consumer is fetching on a tight loop.
>
> Clearing `clickhouse_passwords_wo` is not optional: the mirror validation rejects it whenever the flag is unset, so a rollback that only renames the flag fails the plan. Same rename-don't-duplicate rule as step 4, in the other direction.
>
> This matters most immediately after a botched opt-in, which is precisely when reaching for a rollback is tempting. Read the values out of Secrets Manager *after* the botched apply rather than from your pre-migration notes — and be aware that if the botched apply was a bare flag flip, it will have failed rather than completed, so the credentials there are still the originals.

#### Why later plans look like they regenerate passwords

On the write-only path they do regenerate an ephemeral password every plan — and never write it. The write is gated on `clickhouse_password_versions`, which you have not changed, so the secret keeps its value. This is expected and is not drift.

#### Rotating afterwards

Rotation via `clickhouse_password_versions` applies to deployments on the write-only path (`clickhouse_write_only = true`). On the legacy path there is no version lever: Terraform tracks `secret_string` directly, so editing `clickhouse_passwords` is detected and written like any other argument.

Bump the relevant field in `clickhouse_password_versions` and apply. Without a matching `clickhouse_passwords_wo` entry the new value is freshly generated; with one, your supplied value is written. Rotation propagates as: Secrets Manager → ESO resync → the mounted users config → ClickHouse. It requires no SQL — passwords are declared in configuration, not with `ALTER USER`.

> [!IMPORTANT]
> **On chart >= 5.0.0 the last hop is not automatic, and rotating without an overlap password locks out every client that still holds the old one.** A secret change alone does not reload ClickHouse's users config, and the new password replaces the old one the instant the reload happens. Follow [Rotating a ClickHouse password](#rotating-a-clickhouse-password) instead of this section: it supplies the outgoing password as a second auth method, issues the reload, and verifies both. The `version_id` check below is step 3 of that procedure, automated as `make rotation-check`.

**After any rotation, confirm the secret's version ID changed. This step is mandatory.** `version_id` on `aws_secretsmanager_secret_version` is computed, persisted in state, and is not a secret, so it is a safe positive signal: AWS issues a new version ID on every `PutSecretValue`, and if no write occurred it does not change. Capture it before the apply and compare after:

```bash
ARN="$(terraform output -raw clickhouse_otel_credentials_secret_arn)"
# The version ID marked AWSCURRENT is the live one — that is the value to compare.
aws secretsmanager describe-secret --secret-id "$ARN" \
  --query 'VersionIdsToStages' --output json
```

or read it from state (add `[0]` for the count-gated `admin` / `readonly_user` resources):

```bash
terraform state show \
  'module.ao_data_platform.aws_secretsmanager_secret_version.clickhouse_otel_password'
```

An unchanged version ID means no write happened — in practice, the footgun below. **Do not retire the old credential until the version ID has changed.**

> [!WARNING]
> **On the write-only path, changing a password without bumping its version does nothing, silently.** The version is the only thing that triggers a write. If you edit `clickhouse_passwords_wo.otel` but leave `clickhouse_password_versions.otel` unchanged, the secret keeps its **old** value and the plan shows no diff — Terraform cannot compare a write-only argument, so there is nothing for it to detect or report.
>
> This is the more dangerous of the two footguns in this design, because it fails in the direction of false confidence: you may believe a credential has been rotated and retire the old one while it is still the live password. **Always bump the version in the same change as the password**, and check the version ID afterwards.

#### Why there is no plan-time guard

Scope first: this is about the guard that would catch **omitting** the passwords on the opt-in apply — one that compares the desired password against the live secret. It is not about supplying them through the wrong variable, which *is* guarded, by the cross-variable `validation` on each password variable (that check compares nothing and reads no secret, so none of the objections below apply to it).

Not because such a guard is impossible. The AWS provider ships `ephemeral "aws_secretsmanager_secret_version"`, which returns `secret_string` and persists nothing — so reading the current value at plan time would *not* put plaintext back into state. That was a deliberate decision against, for three other reasons:

- **It breaks the fresh install.** The read targets an existing secret by ID. On a first apply the secret does not exist yet, so the read errors instead of reporting "nothing to compare against" — trading a documented footgun for a hard failure on every new deployment.
- **A precondition may not be allowed to reference it.** Ephemeral values are only valid in ephemeral contexts, and whether `lifecycle.precondition` counts as one is unresolved. An unverified guard is not a guard.
- **For four of the six users the comparison carries no signal.** `otel`, `monte_carlo`, `schema_owner` and `llm_worker` are auto-generated when not supplied, so the desired value is a freshly minted random on every plan. An equality check against the live secret would therefore differ on *every* plan, forever: permanent noise that operators would learn to ignore, including on the one plan that mattered.

So documentation is the control at plan time, which is why the two warnings above are load-bearing rather than decorative. The verification that does exist is after the fact: the `version_id` check under [Rotating afterwards](#rotating-afterwards) for a rotation, and `hack/verify-no-plaintext.sh` for the state itself. The per-deployment opt-in is the other half of the answer: a deployment that has not set `clickhouse_write_only` has nothing to guard, because nothing is written.

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
make sanity-check                # fmt check + validate (CI pipeline)
make test                        # variable-validation tests (requires Terraform >= 1.11)
make selftest-verify-no-plaintext  # regression test for the plaintext detector (CI pipeline; needs jq)
make verify-no-plaintext STATE=state.json SENTINEL_FILE=sentinels.txt
make selftest-rotation-check     # regression test for the rotation checker (CI pipeline; needs jq)
make rotation-check CLUSTER=ao-dev-us1 SLUG=otel [BASELINE=<file>]
```

`make rotation-check` wraps `hack/rotation-check.sh`, the post-apply verification for a credential rotation — see [Rotating a ClickHouse password](#rotating-a-clickhouse-password). It talks to AWS and the cell's cluster; `make selftest-rotation-check` exercises its version-diff logic against recorded `describe-secret` fixtures and needs neither.

`make verify-no-plaintext` is the repo-local convenience wrapper around `hack/verify-no-plaintext.sh` — the same script a Registry consumer runs out of `.terraform/modules/<name>/hack/`, documented under [Upgrading to v3.0.0](#upgrading-to-v300). `SENTINEL_FILE` takes one password per line; the legacy `SENTINELS="a b"` form still works but puts secrets on a command line and cannot carry a value containing whitespace.

`make test` runs `terraform test` against `tests/*.tftest.hcl`. Tests cover the input safety nets (`cluster.main_node_group_size` range, the existing-cluster guard) using `mock_provider` — see the test file's preamble for the explicit scope and known coverage gaps. The module requires `required_version >= 1.11`, which already exceeds the `mock_provider` floor of 1.7, so no separate dev-tool requirement applies.

To release a new version, create and push a tag: `git tag v0.1.0 && git push origin v0.1.0`

## License

See [LICENSE](LICENSE).

## Security

See [SECURITY.md](SECURITY.md).
