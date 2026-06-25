# Deploy — install the platform

Guide the customer through a deployment. You **advise and emit commands**; the customer runs every
`terraform`/`aws` command themselves. Always tell them to review `terraform plan` before applying.
Cite the published docs for prose; this file is the orchestration.

Docs: Prerequisites → Installation → Connect, in order:
- `https://docs.getmontecarlo.com/docs/ao-platform-prerequisites`
- `https://docs.getmontecarlo.com/docs/ao-platform-installation`
- `https://docs.getmontecarlo.com/docs/ao-platform-connect-to-monte-carlo`

## 1. Preflight

Run the bundled read-only check (by its path in this skill's `scripts/` dir):
```bash
<this-skill-dir>/scripts/preflight.sh -r <region> [--hosted-zone-id <ZID>]
```
It checks tooling (terraform ≥ 1.3, aws, kubectl, helm), AWS identity, and — if given — that the
Route 53 hosted zone exists. Resolve anything it flags against the Prerequisites doc before continuing.

The chart and image are **public on Docker Hub — no registry login required.** Get the exact
`chart_registry` value and current `chart_version` from the Prerequisites doc ("get the platform
artifacts"); do not assume an ECR address (the README example uses ECR only as a generic OCI placeholder).

## 2. Choose the path

| Path | When | Starting point |
| :--- | :--- | :--- |
| New VPC + new cluster | greenfield | `examples/new_cluster/` |
| Existing cluster | deploy into the customer's EKS | `examples/existing_cluster/` |
| Infrastructure only | they manage the Helm release themselves | set `helm.deploy_charts = false` |

Have them copy the matching `examples/` directory as the starting point and fill a `terraform.tfvars`.
See `variables.md` for the required inputs per path.

## 3. Provider wiring (don't skip)

The `kubernetes` and `helm` providers must be configured in the root module from this module's
outputs (`eks_cluster_endpoint`, `eks_cluster_ca_certificate`, `eks_cluster_name`) so a single-pass
apply works. **Pin the `helm` provider to `~> 2.0`** — the examples use its v2 nested `kubernetes { }`
block; provider v3 is not yet supported. The `examples/` already show this exactly.

## 4. Provision (customer runs)

```bash
terraform init
terraform plan      # review carefully before applying
terraform apply
```
Heads-up to relay: `apply` runs `local-exec` provisioners that call `aws eks update-kubeconfig`, so
it modifies the runner's `~/.kube/config` (adds/refreshes the cluster context as current).

**Existing-cluster only:**
- If the cluster's OIDC provider already exists, the apply errors — import it first:
  `terraform import 'module.ao_data_platform.aws_iam_openid_connect_provider.cluster[0]' <arn>`
- If a controller (LBC, cert-manager, ESO, external-dns) is already installed, set the matching
  `helm.install_* = false` to skip reinstalling it.

## 5. Post-apply

```bash
aws eks update-kubeconfig --name <eks_cluster_name output> --region <region>
```
Then **verify** — run `collect-state.sh --mode verify` and interpret per `verify.md`.

Retrieve the credentials for Monte Carlo onboarding (the command is the customer's to run; **never
print the value**):
```bash
aws secretsmanager get-secret-value \
  --secret-id <clickhouse_monte_carlo_credentials_secret_arn output> \
  --query SecretString --output text
```

## 6. Connect to Monte Carlo

Hand off the ClickHouse endpoint + the `monte_carlo` credentials to Monte Carlo, following
`https://docs.getmontecarlo.com/docs/ao-platform-connect-to-monte-carlo`. Deploying the Monte Carlo
Agent (Lambda) is **out of scope for this skill** — link to that doc, don't walk through it.

## Teardown & re-runs

- **Idempotent re-run:** re-running `terraform apply` with the same config is safe and converges; no
  special handling needed.
- **Teardown:** `terraform destroy` removes everything the module created. If the cluster/VPC were
  pre-existing (`cluster.create = false` / `create_vpc = false`), destroy removes only the module's
  own resources, not the cluster or VPC.
