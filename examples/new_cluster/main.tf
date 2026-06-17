# Example: Full deployment — new VPC, new EKS cluster, ClickHouse, OTel Collector
#
# After apply:
#   aws eks update-kubeconfig --name <eks_cluster_name output> --region us-east-1

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

  # Use default cluster name "monte-carlo" and create a new VPC + cluster.
  # All other cluster/networking options use their defaults.

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
  }

  # Optional: pin the dedicated ClickHouse node group to an explicit EKS-optimized
  # AMI build. The node group is already no-drift by default
  # (use_latest_ami_release_version defaults to false); set ami_release_version to
  # record a specific build and to perform deliberate AMI updates. The build's
  # minor must match kubernetes_version. See the module README section
  # "ClickHouse node group AMI" for the bump cadence and how to find the current
  # recommended build.
  # clickhouse_node_group = {
  #   ami_release_version = "1.35.5-20260527"
  # }
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
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

output "otel_collector_irsa_role_arn" {
  value = module.ao_data_platform.otel_collector_irsa_role_arn
}

output "clickhouse_monte_carlo_credentials_secret_arn" {
  description = "Secrets Manager ARN for the ClickHouse monte_carlo user password. Retrieve and provide to Monte Carlo to configure the MC Agent connection."
  value       = module.ao_data_platform.clickhouse_monte_carlo_credentials_secret_arn
}
