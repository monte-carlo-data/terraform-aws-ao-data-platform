# AO Data Platform - New Cluster Example

This example creates a new VPC, EKS cluster, and deploys ClickHouse and the OTel Collector.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.11
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials

## Usage

Create a `terraform.tfvars` file with your values:

```hcl
region                = "us-east-1"
otel_collector_domain = "otel.acme.com"
clickhouse_domain     = "clickhouse.acme.com"
hosted_zone_id        = "Z1234567890ABC"  # optional
```

Then apply:

```bash
terraform init
terraform apply
```

After apply, configure kubectl:

```bash
aws eks update-kubeconfig --name <eks_cluster_name output> --region <region>
```
