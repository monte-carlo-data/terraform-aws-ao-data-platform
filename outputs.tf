output "eks_cluster_name" {
  description = "EKS cluster name. Use with: aws eks update-kubeconfig --name <value> --region <region>"

  # Reference the created resource, not local.effective_cluster_name: the local echoes
  # the name input (no dependency on aws_eks_cluster.this), so consumers wiring this into
  # a cluster_name arg get scheduled before the cluster exists and 404 on greenfield apply.
  # Same value; this just makes the cluster dependency implicit for every consumer.
  value = var.cluster.create ? module.eks[0].cluster_name : data.aws_eks_cluster.existing[0].name
}

output "eks_cluster_endpoint" {
  description = "EKS control plane endpoint."
  value       = local.cluster_endpoint
}

output "eks_cluster_ca_certificate" {
  description = "PEM-encoded cluster CA certificate. Use with the kubernetes and helm provider configurations in your root module."
  value       = local.cluster_ca_certificate
  sensitive   = true
}

output "eks_cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster control plane."
  value       = var.cluster.create ? module.eks[0].cluster_security_group_id : null
}

output "montecarlo_namespace" {
  description = "Kubernetes namespace where all pipeline components (ClickHouse, OTel Collector, MC Agent) are installed."
  value       = kubernetes_namespace_v1.montecarlo.metadata[0].name
}

output "otel_collector_irsa_role_arn" {
  description = <<-EOT
    IAM role ARN for the OTel Collector pods (IRSA).
    Pass as the eks.amazonaws.com/role-arn service account annotation when deploying
    the ao-data-platform chart manually (i.e. when helm.deploy_charts = false).
    The role carries no permissions by default; optional inline policies (e.g. SQS +
    S3 read for the awss3 receiver) are attached when the corresponding helm
    options are enabled.
  EOT
  value       = aws_iam_role.otel_collector.arn
}

output "llm_worker_irsa_role_arn" {
  description = <<-EOT
    IAM role ARN for the LLM Worker pods (IRSA).
    Pass as the eks.amazonaws.com/role-arn service account annotation when deploying
    the ao-data-platform chart manually (i.e. when helm.deploy_charts = false).
  EOT
  value       = aws_iam_role.llm_worker.arn
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider associated with the EKS cluster."
  value       = local.oidc_provider_arn
}

output "clickhouse_admin_credentials_secret_arn" {
  description = "Secrets Manager ARN for the ClickHouse admin password. Null when helm.clickhouse.admin is disabled."
  value       = local.clickhouse_admin_enabled ? aws_secretsmanager_secret.clickhouse_admin_password[0].arn : null
}

output "clickhouse_otel_credentials_secret_arn" {
  description = "Secrets Manager ARN for the ClickHouse otel user password."
  value       = aws_secretsmanager_secret.clickhouse_otel_password.arn
}

output "clickhouse_monte_carlo_credentials_secret_arn" {
  description = "Secrets Manager ARN for the ClickHouse monte_carlo user password."
  value       = aws_secretsmanager_secret.clickhouse_monte_carlo_password.arn
}

output "clickhouse_schema_owner_credentials_secret_arn" {
  description = "Secrets Manager ARN for the ClickHouse schema_owner user password."
  value       = aws_secretsmanager_secret.clickhouse_schema_owner_password.arn
}

output "clickhouse_llm_worker_credentials_secret_arn" {
  description = "Secrets Manager ARN for the ClickHouse llm_worker user password."
  value       = aws_secretsmanager_secret.clickhouse_llm_worker_password.arn
}

output "clickhouse_readonly_user_credentials_secret_arn" {
  description = "Secrets Manager ARN for the password of the ClickHouse SQL user `readonly_user` (profile: readonly, SELECT-only). Null when helm.clickhouse.readonly_user is disabled."
  value       = local.clickhouse_readonly_user_enabled ? aws_secretsmanager_secret.clickhouse_readonly_user_password[0].arn : null
}

output "otel_collector_certificate_arn" {
  description = "ACM certificate ARN for the OTel Collector domain. Pass to the ao-data-platform chart for NLB TLS termination."
  value       = var.otel_collector_domain != null ? aws_acm_certificate.otel_collector[0].arn : null
}

output "clickhouse_certificate_arn" {
  description = "ACM certificate ARN for the ClickHouse domain. Pass to the ao-data-platform chart for NLB TLS termination."
  value       = var.clickhouse_domain != null ? aws_acm_certificate.clickhouse[0].arn : null
}

output "clickhouse_node_group" {
  description = <<-EOT
    Identity of the dedicated ClickHouse node group when active — exposes
    the resolved AZ, instance type, size, and the label/taint applied to
    the node group. Useful for verifying placement configuration without
    reading module source.

    Shape: {
      availability_zone = string
      instance_type     = string
      size              = number
      label             = { key, value }
      taint             = { key, value, effect }
    }

    By construction label.key == taint.key and label.value == taint.value
    (they cannot drift — the module wires both from the same locals). The
    nested shape preserves that linkage rather than implying independent
    fields.

    The node group is auto-created when helm.deploy_charts = true AND
    cluster.create = true, and managed while
    manage_legacy_clickhouse_node_group = true. Output is null when any
    of the three is false.

    The availability_zone field reflects the resolved AZ — either an
    explicit override via var.clickhouse_node_group.availability_zone, or (when null)
    the first AZ from data.aws_availability_zones.available. Always check
    this output during plan/apply review so the implicit default doesn't
    silently land the dedicated NG in a different AZ from the existing
    ClickHouse PV.

    Note: taint.effect is the Kubernetes-format value ("NoSchedule"),
    suitable for use in pod tolerations. The EKS managed node group API
    uses the upper-snake-case form ("NO_SCHEDULE") — these are equivalent
    but differ in format between the EKS console/API and Kubernetes pod
    specs.

    Informational: helm values (clickhouse.nodeSelector and
    clickhouse.tolerations) are wired automatically inside this module,
    so consumers driving the helm release through this module do not need
    to plumb these values themselves.
  EOT
  value = (local.clickhouse_node_placement_enabled && var.manage_legacy_clickhouse_node_group) ? {
    availability_zone = local.clickhouse_az_resolved
    instance_type     = var.clickhouse_node_group.instance_type
    size              = 1
    label = {
      key   = local.clickhouse_node_label_key
      value = local.clickhouse_node_label_value
    }
    taint = {
      key    = local.clickhouse_node_label_key
      value  = local.clickhouse_node_label_value
      effect = "NoSchedule" # Kubernetes pod-toleration format; EKS API uses "NO_SCHEDULE"
    }
  } : null
}

