# Troubleshoot — decision tree

Use this after running `collect-state.sh --mode diagnose` (see SKILL.md for how to resolve the
target and invoke the script). Match each `FAIL`/`WARN` line in the summary to a node below, work
top-down (earlier layers cause later ones — a stuck schema job is usually a ClickHouse or secret
problem, not a schema problem), and give the user the root cause + the exact command + the doc
section.

**Contract (same as SKILL.md):** confirm with read-only commands; **emit** any fix as a command
for the user to run — never apply it yourself. Never read or print a secret value.

Source of truth for the prose/fix detail — cite the matching section:
`https://docs.getmontecarlo.com/docs/ao-platform-troubleshooting`

The nodes below are 1:1 with that page; keep them in sync if the doc changes.

---

## ClickHouse pod is `Pending`
**Summary signals:** `nodes` FAIL (no `dedicated=clickhouse` node) or `workloads` FAIL (ClickHouse
not Ready, phase `Pending`).

Almost always scheduling or volume placement on the dedicated ClickHouse node group:
- **AZ mismatch** — EBS volumes are AZ-locked. If the dedicated node group is in a different AZ
  than the existing ClickHouse PV, the pod can't mount its volume.
- **No matching node** — the pod needs a node tolerating `dedicated=clickhouse:NoSchedule`.

Confirm (read-only):
```bash
kubectl get nodes -l dedicated=clickhouse
kubectl describe pod -n <ns> -l clickhouse.altinity.com/chi=otel   # events name the unsatisfied constraint
```
Fix (emit): align `clickhouse_node_group.availability_zone` to the volume's AZ (compare with the
`clickhouse_node_group` output) and re-apply. Doc: *The ClickHouse pod is stuck in `Pending`*.

## A TLS certificate never becomes `Ready`
**Summary signals:** `tls` FAIL on a `Certificate/…`, or `tls-live` FAIL.

Check in order:
- **cert-manager running** — internal Collector↔ClickHouse TLS always depends on it. On an existing
  cluster, confirm you didn't set `helm.install_cert_manager = false` while it was actually absent.
- **CA issuer ready** — the chart creates `ao-data-platform-ca` (`tls.certManager.createCA = true`).
- **DNS-01 validation** (public ACM-fronted endpoints) — confirm `hosted_zone_id` is set and the
  cert-manager IRSA role can manage Route 53.

Confirm (read-only):
```bash
kubectl describe certificate -n <ns> <name>
kubectl describe certificaterequest,order -n <ns>   # shows the validation error
```
Doc: *A TLS certificate never becomes `Ready`*.

## An ExternalSecret is not `SecretSynced`
**Summary signals:** `secrets` FAIL (ClusterSecretStore not Valid, an ExternalSecret not synced, or
the otel credentials Secret missing).

ESO syncs the ClickHouse passwords from AWS Secrets Manager into the cluster. If not `SecretSynced`:
- ClusterSecretStore exists and is `Valid`.
- The ESO service-account IRSA role can read the Secrets Manager secret **and** decrypt with the KMS key.
- The referenced secret exists in Secrets Manager (the `clickhouse_*_credentials_secret_arn` outputs).

Confirm (read-only):
```bash
kubectl get clustersecretstore
kubectl describe externalsecret -n <ns> <name>
```
Doc: *An ExternalSecret is not `SecretSynced`*.

## The schema-migration job doesn't complete
**Summary signals:** `schema` FAIL; often with `workloads` WARN (Collector/LLM worker stuck `Init`).

The `clickhouse-schema-<n>` job creates the `otel_traces` database/tables and TTLs. It waits for
ClickHouse to accept connections as `otel`, so a failure here usually traces back to ClickHouse not
being healthy or the `otel` secret not syncing — **resolve those nodes first.** The Collector and
LLM worker block on this job via an init container.

Confirm (read-only):
```bash
kubectl get jobs -n <ns>
kubectl logs -n <ns> job/clickhouse-schema-<n>
```
Doc: *The schema-migration job doesn't complete*.

## Chart older than 1.3.0
**Summary signals:** ClickHouse never schedules even though the node group looks fine; a
`readonly_user` secret exists but the SQL user doesn't.

The module requires `ao-data-platform` chart **>= 1.3.0** (pre-1.3.0 used an anti-affinity rule that
deadlocks with the dedicated node group). Fix (emit): pin `helm.chart_version` to `>= 1.3.0` and
re-apply. Doc: *I'm on a chart version older than 1.3.0*.

## (Existing cluster) Terraform says the OIDC provider already exists
Not a `collect-state` signal — surfaces during `terraform apply`. Fix (emit): import the existing
provider before applying:
```bash
terraform import 'module.ao_data_platform.aws_iam_openid_connect_provider.cluster[0]' <arn>
```
Doc: *(Existing cluster) Terraform says the OIDC provider already exists*.

## `kubectl` / `aws eks update-kubeconfig` is denied
**Summary signals:** `context` FAIL (cluster unreachable) or `namespace access` WARN.

Needs `eks:DescribeCluster` plus authentication to the cluster. The principal that ran
`terraform apply` gets cluster-admin automatically; a different principal needs an EKS access entry.
Doc: *`kubectl` / `aws eks update-kubeconfig` is denied*.

## Traces aren't arriving in ClickHouse (infra healthy)
Everything passes but no trace data appears:
- **NLB source ranges** — if `otel_collector_nlb_allowed_source_ranges` (or the ClickHouse one) is
  set, confirm the agents' source CIDR is included; an overly narrow list silently drops connections.
  Widen to the correct CIDR (do **not** open to `0.0.0.0/0` in production).
- **Endpoint and ports** — agents must target the Collector over OTLP, gRPC `4317` or HTTP `4318`,
  with TLS.
- **Collector logs:**
  ```bash
  kubectl logs -n <ns> -l app.kubernetes.io/name=opentelemetry-collector
  ```
Doc: *Traces aren't arriving in ClickHouse*.

## The Collector is running but isn't writing to ClickHouse
**Summary signals:** `logs` WARN (ClickHouse exporter errors).

Common causes: the schema job hasn't completed (`otel_traces` doesn't exist yet) or the `otel`
credentials secret isn't synced — verify both via the nodes above. Doc: *The Collector is running
but isn't writing to ClickHouse*.

## The LLM worker can't run evaluations
The LLM worker calls Amazon Bedrock. If evaluations fail:
- **Permissions** — the LLM worker IRSA role allows `bedrock:InvokeModel` for the target model.
- **Region / model availability** — the worker uses your deployment `region` by default; set
  `helm.llm_worker.bedrock_region` if the model isn't available there.
- **Logs:** `kubectl logs -n <ns> -l app.kubernetes.io/component=llm-worker`.
Doc: *The LLM worker can't run evaluations*.

---

## AWS permissions / IRSA (cuts across the symptoms above)

AWS permission failures are the **hidden root cause** under many of the nodes above: the symptom
is downstream (cert not Ready, ExternalSecret not synced, NLB not provisioned, evals failing), but
the real error is an `AccessDenied` buried in the *controller's* pod logs — in its own namespace.
Each in-cluster component assumes a dedicated IRSA role via the cluster's OIDC provider:

| Component (ns) | IRSA role needs | Symptom when denied |
| :--- | :--- | :--- |
| External Secrets (`external-secrets`) | `secretsmanager:GetSecretValue`, `kms:Decrypt` | ExternalSecret not SecretSynced |
| cert-manager (`cert-manager`) | `route53:ChangeResourceRecordSets`, … | TLS cert never Ready (DNS-01) |
| external-dns (`external-dns`) | `route53:ChangeResourceRecordSets`, … | DNS doesn't resolve |
| AWS Load Balancer Controller (`kube-system`) | `elasticloadbalancing:*`, `ec2:Describe*` | NLB not provisioned |
| LLM worker (`<ns>`) | `bedrock:InvokeModel` | evaluations fail |

`collect-state.sh` scans the four controllers' logs for denials and surfaces them under the
**iam** layer. To diagnose (all read-only — the operator runs these; results may themselves need
`iam:Get*`/`iam:SimulatePrincipalPolicy`, so degrade gracefully if those are denied):

1. **Read the literal error** — it names the exact action and often the deny source:
   ```bash
   kubectl logs -n <controller-ns> -l <controller-label> --tail=200 | grep -iE 'AccessDenied|not authorized to perform|AssumeRoleWithWebIdentity'
   ```
2. **Map to the IRSA role and confirm the wiring:**
   ```bash
   SA_ROLE=$(kubectl get sa -n <controller-ns> <sa> -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
   aws iam get-role --role-name "${SA_ROLE##*/}" --query 'Role.AssumeRolePolicyDocument'   # trust: OIDC provider + the SA :sub condition
   ```
   A trust-policy mismatch (wrong OIDC provider URL, or a `:sub` that doesn't match
   `system:serviceaccount:<ns>:<sa>`) shows up as an `AssumeRoleWithWebIdentity` failure rather
   than a per-action `AccessDenied`.
3. **Test the specific action definitively** with the policy simulator — the read-only power tool:
   ```bash
   aws iam simulate-principal-policy --policy-source-arn "$SA_ROLE" \
     --action-names secretsmanager:GetSecretValue --resource-arns <secret-arn>
   ```
4. **Mind simulate's blind spots.** It does not evaluate **KMS key policies** or all resource
   policies, and may not reflect **SCPs / permission boundaries**. So if the role *looks* allowed
   but the call still fails, suspect the KMS key policy (for ESO's `kms:Decrypt`), an Organizations
   SCP, or a permission boundary. The literal error from step 1 is ground truth.

Fix (emit): the module's `iam.tf` defines these roles; if a policy/trust is wrong on a
module-managed deploy it's usually an existing-cluster OIDC/boundary interaction — adjust the
offending policy/SCP/key policy and re-apply. Never have the skill modify IAM itself.

---

## FAQ pointers (route, don't restate)
- **Which user does Monte Carlo connect as?** The `otel` user (creds from
  `clickhouse_otel_credentials_secret_arn`). A read-only user is **not** required for the MC
  connection; the optional `readonly_user` is for the customer's own SQL clients.
- **Change trace retention** → `clickhouse_ttl_days` (default 30); re-applied by the schema job.
- **Restrict who can reach ClickHouse** → `clickhouse_nlb_allowed_source_ranges`; see the
  Configuration reference and the security overview.
