# AO Data Platform - Existing Cluster Example

This example deploys the Monte Carlo agent observability data platform on an existing EKS cluster.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.3
- An existing EKS cluster with kubectl access
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials

## Usage

Update `main.tf` with your existing cluster name and region, then:

```bash
terraform init
terraform apply
```
