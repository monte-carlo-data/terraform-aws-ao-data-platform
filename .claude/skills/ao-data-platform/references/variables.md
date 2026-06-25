# Variables cheat-sheet

The required inputs per deployment path, plus the optional knobs worth knowing. This is a routing
aid — the README "Inputs" table is the complete, authoritative list; load it for anything not here,
and don't restate the whole table.

## Required per path

**Always required:** `region`.

**New VPC + new cluster** (`examples/new_cluster/`):
| Input | Notes |
| :--- | :--- |
| `otel_collector_domain`, `clickhouse_domain` | required when `helm.deploy_charts = true` (the chart creates the NLB endpoints) |
| `helm.chart_registry`, `helm.chart_version` | required when `deploy_charts = true`. Public Docker Hub OCI value + current version: see the Prerequisites doc |
| `hosted_zone_id` | optional but recommended — enables automatic DNS + cert-manager/external-dns IRSA. Omit only if managing DNS records manually |

**Existing cluster** (`examples/existing_cluster/`) — all of the above, plus:
| Input | Notes |
| :--- | :--- |
| `cluster.create = false`, `cluster.existing_cluster_name` | target the existing cluster |
| `networking.create_vpc = false`, `networking.existing_vpc_id`, `networking.existing_private_subnet_ids` | ≥ 2 private subnets in different AZs |
| `helm.install_aws_load_balancer_controller` / `install_cert_manager` / `install_external_secrets_operator` / `install_external_dns` | set to `false` for any controller already in the cluster |

**Infrastructure only:** `helm.deploy_charts = false`. Then `chart_registry`/`chart_version` and the
domains are not required — Terraform provisions AWS infra + controllers, and the customer installs
the `ao-data-platform` chart themselves.

## Optional knobs worth surfacing

- `clickhouse_nlb_allowed_source_ranges` / `otel_collector_nlb_allowed_source_ranges` — restrict NLB
  reach. `null` = no restriction; `[]` = VPC CIDR only; `[…]` = VPC + listed ranges. Internal-scheme
  NLBs, so a listed range still needs a private path into the VPC.
- `clickhouse_ttl_days` (default 30) — trace retention.
- `helm.<workload>.resources` (`clickhouse` / `opentelemetry_collector` / `llm_worker`) — K8s
  requests/limits; omit for chart defaults.
- `helm.clickhouse.readonly_user = { enabled = true }` — optional SELECT-only user for the customer's
  own SQL clients (not needed for the MC connection). Requires chart ≥ 1.2.0.
- `clickhouse_node_group.ami_release_version` — pin the ClickHouse node AMI (see the README
  "ClickHouse node group AMI" section for the matching-minor rule and bump cadence).
- `helm.llm_worker.bedrock_region` — if the evaluation model isn't available in `region`.

## Do NOT surface

- **`helm.opentelemetry_collector.awss3_receiver`** (the S3/SQS receiver) — out of scope for this
  guided path, even though it exists in the module. Don't suggest or configure it.

## Secrets

`clickhouse_passwords` (admin / otel / monte_carlo / readonly_user) auto-generate when omitted —
leave them unset unless the customer must supply specific passwords, in which case they go in a
`.tfvars` file or `TF_VAR_clickhouse_passwords` (the variable is `sensitive`). Never echo these.
