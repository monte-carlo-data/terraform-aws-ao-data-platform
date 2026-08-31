terraform {
  # >= 1.11 for write-only arguments (secret_string_wo / secret_string_wo_version),
  # which keep the ClickHouse passwords out of state and plan files (YET-2514).
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.50 (#48318) for the fix to unnecessary resource replacement when
      # switching secret_string <-> secret_string_wo without changing the secret
      # value, plus the "inconsistent final plan" fix for secret_string_wo_version
      # referencing a resource created/replaced in the same apply. 6.45.0 (#47815)
      # only partially addressed this (#41635) — do not relax below 6.50.
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
