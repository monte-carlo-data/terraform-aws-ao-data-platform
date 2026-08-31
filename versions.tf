terraform {
  # >= 1.11 for write-only arguments (secret_string_wo / secret_string_wo_version),
  # which keep the ClickHouse passwords out of state and plan files (YET-2514).
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.50 for the fix to aws_secretsmanager_secret_version destroy+recreate
      # when switching secret_string -> secret_string_wo (provider issue #41635).
      version = "~> 6.50"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source = "hashicorp/random"
      # >= 3.7 for `ephemeral "random_password"`.
      version = "~> 3.7"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
