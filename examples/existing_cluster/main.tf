# Example: Deploy to an existing EKS cluster
#
# Terraform provisions:
#   - OIDC provider (if not already present; import if needed)
#   - Kubernetes namespace (montecarlo) for all pipeline components
#   - IRSA roles for the OTel Collector, AWS Load Balancer Controller, cert-manager,
#     External Secrets Operator, and external-dns
#   - ClickHouse passwords generated and stored in AWS Secrets Manager
#   - cert-manager, External Secrets Operator, AWS Load Balancer Controller,
#     external-dns, and ao-data-platform Helm charts
#
# No new VPC or EKS cluster is created.
#
# If the cluster's OIDC provider was created outside Terraform, import it first:
#   terraform import 'module.ao_data_platform.aws_iam_openid_connect_provider.cluster[0]' <arn>

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = module.ao_data_platform.eks_cluster_endpoint
  cluster_ca_certificate = module.ao_data_platform.eks_cluster_ca_certificate
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.ao_data_platform.eks_cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.ao_data_platform.eks_cluster_endpoint
    cluster_ca_certificate = module.ao_data_platform.eks_cluster_ca_certificate
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.ao_data_platform.eks_cluster_name, "--region", var.region]
    }
  }
}

module "ao_data_platform" {
  # When using this example outside the repo, replace with the published source:
  #   source = "github.com/monte-carlo-data/terraform-aws-ao-data-platform?ref=v0.0.15"
  source = "../../"

  region = var.region

  cluster = {
    create                = false
    existing_cluster_name = var.existing_cluster_name
  }

  networking = {
    create_vpc                  = false
    existing_vpc_id             = var.existing_vpc_id
    existing_private_subnet_ids = var.existing_private_subnet_ids
  }

  # Domain for the OTel Collector HTTPS endpoint. The chart creates the NLB Service
  # with cert-manager TLS and external-dns annotations.
  otel_collector_domain = var.otel_collector_domain

  # Domain for the ClickHouse TCP+TLS endpoint. Same pattern as OTel Collector.
  clickhouse_domain = var.clickhouse_domain

  # Optional: Route 53 hosted zone ID. When set, Terraform creates IRSA roles for
  # cert-manager (ACME DNS-01) and external-dns (automatic CNAME management).
  hosted_zone_id = var.hosted_zone_id

  helm = {
    chart_registry = var.chart_registry
    chart_version  = var.chart_version

    # If any of these controllers are already installed in the cluster, set the
    # corresponding flag to false to skip reinstalling it.
    # install_aws_load_balancer_controller = false
    # install_cert_manager                 = false
    # install_external_secrets_operator    = false
  }
}

variable "region" {
  description = "AWS region of the existing cluster."
  type        = string
}

variable "existing_cluster_name" {
  description = "Name of the existing EKS cluster to deploy into."
  type        = string
}

variable "existing_vpc_id" {
  description = "ID of the existing VPC to deploy into."
  type        = string
}

variable "existing_private_subnet_ids" {
  description = "IDs of at least two private subnets in different AZs within the existing VPC."
  type        = list(string)
}

variable "otel_collector_domain" {
  description = "Domain name for the OTel Collector HTTPS endpoint (e.g. \"otel.acme.com\")."
  type        = string
  default     = null
}

variable "clickhouse_domain" {
  description = "Domain name for the ClickHouse TCP+TLS endpoint (e.g. \"clickhouse.acme.com\")."
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for clickhouse_domain and otel_collector_domain. Leave null to manage DNS records manually."
  type        = string
  default     = null
}

variable "chart_registry" {
  description = "OCI registry URL for the ao-data-platform chart (e.g. \"oci://123456789012.dkr.ecr.us-east-1.amazonaws.com\")."
  type        = string
}

variable "chart_version" {
  description = "Version of the ao-data-platform chart to deploy."
  type        = string
}

output "eks_cluster_name" {
  value = module.ao_data_platform.eks_cluster_name
}

output "montecarlo_namespace" {
  value = module.ao_data_platform.montecarlo_namespace
}

output "otel_collector_irsa_role_arn" {
  value = module.ao_data_platform.otel_collector_irsa_role_arn
}

output "clickhouse_monte_carlo_credentials_secret_arn" {
  description = "Secrets Manager ARN for the ClickHouse monte_carlo user password. Retrieve and provide to Monte Carlo to configure the MC Agent connection."
  value       = module.ao_data_platform.clickhouse_monte_carlo_credentials_secret_arn
}
