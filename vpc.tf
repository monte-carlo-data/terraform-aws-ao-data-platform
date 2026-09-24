# AZs needing a matching private subnet: the legacy CH NG's AZ (only while it's
# still managed — eks.tf gates that node group on manage_legacy_clickhouse_node_group
# too, so a retired legacy group shouldn't still demand a subnet in its AZ) plus
# the HA topology's per-AZ NGs.
locals {
  legacy_clickhouse_node_group_enabled = local.clickhouse_node_placement_enabled && var.manage_legacy_clickhouse_node_group

  dedicated_node_group_azs = local.clickhouse_node_placement_enabled ? distinct(concat(
    local.legacy_clickhouse_node_group_enabled ? [local.clickhouse_az_resolved] : [],
    local.ha_node_group_azs,
  )) : []
}

# One lookup per AZ a dedicated node group needs. Keep the singular data.aws_subnet
# (scalar `id`): node-group subnet_ids is immutable, so any change to this value
# replaces the node group. Errors on a zero- or multi-subnet match for the AZ —
# the latter is a real, if unusual, misconfiguration (two private subnets in one
# AZ); failing loudly here is intentional, since the NLB aws-load-balancer-subnets
# annotation already requires exactly one subnet per AZ (see README).
#
# No depends_on: the subnet-id filter already orders this after module.vpc's
# subnets; depends_on would defer the read on any unrelated VPC change.
data "aws_subnet" "dedicated_node_group_az_subnet" {
  for_each = toset(local.dedicated_node_group_azs)

  vpc_id            = local.effective_vpc_id
  availability_zone = each.value

  filter {
    name   = "subnet-id"
    values = local.effective_private_subnet_ids
  }
}

# VPC lookup — used only when an NLB source-range restriction is configured, to
# fold the VPC's own CIDR block(s) into the allow-list so in-VPC clients always
# retain access. Keyed off local.effective_vpc_id (created or existing VPC); the
# implicit edge via the id argument covers module.vpc, so no explicit depends_on
# is needed (unlike data.aws_subnet.dedicated_node_group_az_subnet above, whose
# subnet-id filter needs the actual subnets to exist).
data "aws_vpc" "selected" {
  count = local.nlb_source_ranges_enabled ? 1 : 0
  id    = local.effective_vpc_id
}

# -----------------------------------------------------------------------------
# VPC (conditional)
# -----------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"
  count   = var.networking.create_vpc ? 1 : 0

  name = "${var.cluster.name}-vpc"
  cidr = var.networking.vpc_cidr
  azs  = data.aws_availability_zones.available.names

  private_subnets = var.networking.private_subnet_cidrs
  public_subnets  = var.networking.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = var.tags
}
