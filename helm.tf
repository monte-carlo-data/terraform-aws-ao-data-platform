# Verify cert-manager namespace exists when it is pre-installed (install_cert_manager = false).
data "kubernetes_namespace_v1" "cert_manager" {
  count = var.helm.install_cert_manager ? 0 : 1
  metadata {
    name = "cert-manager"
  }
  depends_on = [module.eks, data.aws_eks_cluster.existing]
}

# Verify external-secrets namespace exists when ESO is pre-installed (install_external_secrets_operator = false).
data "kubernetes_namespace_v1" "external_secrets" {
  count = var.helm.install_external_secrets_operator ? 0 : 1
  metadata {
    name = "external-secrets"
  }
  depends_on = [module.eks, data.aws_eks_cluster.existing]
}

# Helm — AWS Load Balancer Controller (conditional). Set install_aws_load_balancer_controller = false if already installed.
#
# Controller chart versions (here and on cert-manager / external-secrets /
# external-dns below) are pinned to known-good versions so applies can't
# silently upgrade a controller. Bump deliberately: check the chart's release
# notes, then raise the pin.

resource "helm_release" "aws_load_balancer_controller" {
  count = var.helm.install_aws_load_balancer_controller ? 1 : 0

  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "3.3.0"
  namespace        = "kube-system"
  create_namespace = false

  values = [
    yamlencode({
      clusterName = local.effective_cluster_name
      region      = var.region
      vpcId       = local.effective_vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.aws_load_balancer_controller[0].arn
        }
      }
    })
  ]

  depends_on = [module.eks, data.aws_eks_cluster.existing]
}

# Helm — cert-manager (conditional). Set install_cert_manager = false if already installed.

resource "helm_release" "cert_manager" {
  count = var.helm.install_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.20.2"
  namespace        = "cert-manager"
  create_namespace = true

  values = [
    yamlencode({
      crds = { enabled = true }
      serviceAccount = {
        annotations = var.hosted_zone_id != null ? {
          "eks.amazonaws.com/role-arn" = aws_iam_role.cert_manager[0].arn
        } : {}
      }
    })
  ]

  depends_on = [module.eks, data.aws_eks_cluster.existing, helm_release.aws_load_balancer_controller]
}

# -----------------------------------------------------------------------------
# External Secrets Operator — syncs ClickHouse passwords from Secrets Manager
# into Kubernetes Secrets so the ao-data-platform chart can reference them.
# -----------------------------------------------------------------------------

# Helm — External Secrets Operator (conditional). Set install_external_secrets_operator = false if already installed.

resource "helm_release" "external_secrets" {
  count = var.helm.install_external_secrets_operator ? 1 : 0

  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.4.1"
  namespace        = "external-secrets"
  create_namespace = true

  values = [
    yamlencode({
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets[0].arn
        }
      }
    })
  ]

  depends_on = [module.eks, data.aws_eks_cluster.existing, helm_release.aws_load_balancer_controller]
}

# Helm — external-dns (conditional). Watches Services for hostname annotations and creates
# Route 53 records automatically. Only useful when hosted_zone_id is provided.

resource "helm_release" "external_dns" {
  count = var.helm.install_external_dns && var.hosted_zone_id != null ? 1 : 0

  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = "1.21.1"
  namespace        = "external-dns"
  create_namespace = true

  values = [
    yamlencode({
      provider      = { name = "aws" }
      aws           = { region = var.region }
      domainFilters = [data.aws_route53_zone.main[0].name]
      txtOwnerId    = local.effective_cluster_name
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns[0].arn
        }
      }
    })
  ]

  depends_on = [module.eks, data.aws_eks_cluster.existing, helm_release.aws_load_balancer_controller]
}

# Wait for ESO CRDs to be fully established before creating ClusterSecretStore/ExternalSecret
# resources. Helm reports success before the API server has registered the CRDs.
#
# Note: this provisioner (and eso_resources below) runs aws eks update-kubeconfig,
# which rewrites the operator's ~/.kube/config — the cluster's context is added
# (or refreshed) and becomes the current context. The interpolated values are
# constrained by variable validations (cluster.name / cluster.existing_cluster_name
# / region allow only [a-zA-Z0-9_-]), so they cannot break out of the single quotes.
resource "null_resource" "wait_for_eso_crds" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      aws eks update-kubeconfig --name '${local.effective_cluster_name}' --region '${var.region}'
      kubectl wait --for=condition=Established --timeout=120s \
        crd/clustersecretstores.external-secrets.io \
        crd/externalsecrets.external-secrets.io
    EOT
  }
  depends_on = [helm_release.external_secrets, data.kubernetes_namespace_v1.external_secrets]
}

# ClusterSecretStore — routes ExternalSecrets to AWS Secrets Manager via the ESO IRSA role.
# No explicit auth block is needed: ESO uses the IRSA credentials from the annotated service account.

# ClusterSecretStore — cluster-wide ESO store pointing at AWS Secrets Manager.
# Applied via kubectl rather than the kubernetes/kubectl Terraform providers, which cache API
# discovery at init time and fail when CRDs are installed during the same apply run.
# Deletion is handled implicitly: removing the ESO Helm chart removes its CRDs, which
# cascade-deletes ClusterSecretStore resources automatically.
# ExternalSecret resources are intentionally NOT created here — the ao-data-platform chart
# manages its own ExternalSecrets and the resulting K8s Secrets.
resource "null_resource" "eso_resources" {
  triggers = {
    region = var.region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      aws eks update-kubeconfig --name '${local.effective_cluster_name}' --region '${var.region}'
      kubectl apply -f - <<'YAML'
      ---
      apiVersion: external-secrets.io/v1
      kind: ClusterSecretStore
      metadata:
        name: aws-secrets-manager
      spec:
        provider:
          aws:
            service: SecretsManager
            region: ${var.region}
      YAML
    EOT
  }

  depends_on = [null_resource.wait_for_eso_crds]
}

# Helm — ao-data-platform (ClickHouse + OTel Collector as subcharts).

resource "helm_release" "ao_data_platform" {
  count = var.helm.deploy_charts ? 1 : 0

  name             = "ao-data-platform"
  chart            = "${var.helm.chart_registry}/ao-data-platform"
  version          = var.helm.chart_version
  namespace        = kubernetes_namespace_v1.montecarlo.metadata[0].name
  create_namespace = false
  wait_for_jobs    = true

  values = [
    yamlencode({
      clickhouse = merge({
        hostname     = var.clickhouse_domain
        storageSize  = var.helm.clickhouse.storage_size
        storageClass = var.clickhouse_storage_class
        ttlDays      = var.clickhouse_ttl_days
        # otel ESO wiring is dual-pathed across the 2.0.0 chart migration: chart
        # < 2.0.0 reads clickhouse.externalSecret; chart >= 2.0.0 reads
        # clickhouse.otel.externalSecret. Both resolve to the same Secrets Manager
        # key, so the module stays compatible with either chart while the fleet
        # migrates. Remove this legacy clickhouse.externalSecret once every
        # chart-deployed cell is on >= 2.0.0.
        externalSecret = local.clickhouse_user_external_secret.otel
        otel = {
          restrictGrants = var.helm.clickhouse.otel.restrict_grants
          externalSecret = local.clickhouse_user_external_secret.otel
        }
        schemaOwner = {
          externalSecret = local.clickhouse_user_external_secret.schemaOwner
        }
        llmWorker = {
          externalSecret = local.clickhouse_user_external_secret.llmWorker
        }
        monteCarlo = {
          externalSecret = local.clickhouse_user_external_secret.monteCarlo
        }
        service = {
          type = "LoadBalancer"
          annotations = merge({
            "service.beta.kubernetes.io/aws-load-balancer-type"                 = "external"
            "service.beta.kubernetes.io/aws-load-balancer-scheme"               = "internal"
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"      = "ip"
            "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"             = aws_acm_certificate.clickhouse[0].arn
            "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"            = "9440,8443"
            "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"     = "ssl"
            "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"     = "8443"
            "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol" = "HTTPS"
            "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"     = "/ping"
            # Restrict NLB source ranges when configured. Uses the controller
            # annotation rather than spec.loadBalancerSourceRanges (which the
            # chart Service doesn't set, and which would override this if it did).
            }, local.clickhouse_nlb_source_ranges != null ? {
            "service.beta.kubernetes.io/load-balancer-source-ranges" = join(",", local.clickhouse_nlb_source_ranges)
          } : {})
        }
      }, local.helm_clickhouse_resources_block, local.helm_clickhouse_admin_block, local.helm_clickhouse_readonly_user_block, local.helm_clickhouse_node_selector_block, local.helm_clickhouse_tolerations_block)
      "opentelemetry-collector" = merge({
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.otel_collector.arn
          }
        }
        service = {
          type = "LoadBalancer"
          annotations = merge({
            "service.beta.kubernetes.io/aws-load-balancer-type"                 = "external"
            "service.beta.kubernetes.io/aws-load-balancer-scheme"               = "internal"
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"      = "ip"
            "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"             = aws_acm_certificate.otel_collector[0].arn
            "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"            = "4317,4318"
            "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"     = "ssl"
            "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"     = "13133"
            "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol" = "HTTP"
            "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"     = "/"
            "external-dns.alpha.kubernetes.io/hostname"                         = var.otel_collector_domain
            # Restrict NLB source ranges when configured. Uses the controller
            # annotation rather than spec.loadBalancerSourceRanges (which the
            # chart Service doesn't set, and which would override this if it did).
            }, local.otel_collector_nlb_source_ranges != null ? {
            "service.beta.kubernetes.io/load-balancer-source-ranges" = join(",", local.otel_collector_nlb_source_ranges)
          } : {})
        }
      }, local.helm_otel_resources_block, local.helm_otel_awss3_block)
      llmWorker = merge({
        image = {
          repository = local.llm_worker_image_repository
          tag        = var.helm.llm_worker.image_tag
        }
        aws = {
          region = coalesce(var.helm.llm_worker.bedrock_region, var.region)
        }
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.llm_worker.arn
          }
        }
      }, local.helm_llm_worker_resources_block)
    })
  ]

  lifecycle {
    precondition {
      condition     = var.clickhouse_domain != null && var.otel_collector_domain != null
      error_message = "clickhouse_domain and otel_collector_domain are required when helm.deploy_charts = true."
    }
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    helm_release.cert_manager,
    data.kubernetes_namespace_v1.cert_manager,
    null_resource.eso_resources,
  ]
}
