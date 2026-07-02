# Subnet AZ lookup — used only when the dedicated ClickHouse node group is
# enabled, to find subnets in the requested AZ. EKS managed node groups
# derive their AZ from the subnet list, so pinning the group to a single AZ
# requires supplying only the matching subnet ID(s). Using the plural
# data.aws_subnets (filter by VPC + AZ) avoids a for_each over
# local.effective_private_subnet_ids, whose values are unknown at plan time
# when var.networking.create_vpc = true. The result is then intersected with
# local.effective_private_subnet_ids to exclude any public subnets that
# happen to be in the same AZ.
data "aws_subnets" "ch_node_group_az_subnets" {
  count = local.clickhouse_node_placement_enabled ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.effective_vpc_id]
  }

  filter {
    name   = "availability-zone"
    values = [local.clickhouse_az_resolved]
  }

  # Explicit dependency on module.vpc when create_vpc = true: the
  # implicit edge via local.effective_vpc_id covers the VPC ID, but
  # NOT the private subnets being created inside the VPC module. Without
  # this, a fresh apply can read the subnet list before the subnets
  # exist, returning an empty result and tripping the postcondition
  # below ("AZ does not match any private subnet") on a valid config.
  depends_on = [module.vpc]

  # Validation: the resolved CH NG AZ must match at least one of the
  # cluster's private subnets. Catches typos in
  # var.clickhouse_node_group.availability_zone or region/subnet mismatches before the
  # EKS module fails with an obscure message on an empty subnet_ids list.
  # Postcondition (vs a separate null_resource + precondition) keeps the
  # check on the natural anchor — the data source whose result it
  # validates — and re-evaluates during refresh, not just on resource
  # creation.
  lifecycle {
    postcondition {
      condition     = length(setintersection(toset(self.ids), toset(local.effective_private_subnet_ids))) > 0
      error_message = "Resolved ClickHouse node-group AZ (\"${local.clickhouse_az_resolved}\") does not match any private subnet provided to the cluster. ${var.clickhouse_node_group.availability_zone == null ? "The AZ was defaulted from data.aws_availability_zones.available.names[0]; set var.clickhouse_node_group.availability_zone explicitly to an AZ that has a private subnet." : "Verify the AZ name and confirm the cluster's private subnets include one in that AZ."}"
    }
  }
}

# Per-AZ subnet lookup for the HA topology node groups (ClickHouse replicas +
# Keeper voters). Same shape as ch_node_group_az_subnets above, but fanned out
# with for_each over the union of the explicit CH + keeper AZ lists — one query
# per AZ — so each single-AZ node group can be pinned to the matching subnet.
# Only read when the dedicated node groups are enabled and at least one AZ is
# listed; empty (legacy single-instance) deployments create no queries.
data "aws_subnets" "ha_node_group_az_subnets" {
  for_each = local.clickhouse_node_placement_enabled ? toset(local.ha_node_group_azs) : toset([])

  filter {
    name   = "vpc-id"
    values = [local.effective_vpc_id]
  }

  filter {
    name   = "availability-zone"
    values = [each.value]
  }

  # Same rationale as ch_node_group_az_subnets: the vpc-id edge doesn't cover
  # the private subnets created inside the VPC module, so a fresh apply could
  # read an empty list and trip the postcondition on a valid config.
  depends_on = [module.vpc]

  lifecycle {
    postcondition {
      condition     = length(setintersection(toset(self.ids), toset(local.effective_private_subnet_ids))) > 0
      error_message = "HA node-group AZ \"${each.key}\" (from clickhouse_availability_zones / keeper_availability_zones) matches no private subnet provided to the cluster. When create_vpc = true, list only AZs among the first ${length(var.networking.private_subnet_cidrs)} of the region's available AZs (that's where the module places private subnets); otherwise confirm existing_private_subnet_ids includes a subnet in this AZ."
    }
  }
}

# VPC lookup — used only when an NLB source-range restriction is configured, to
# fold the VPC's own CIDR block(s) into the allow-list so in-VPC clients always
# retain access. Keyed off local.effective_vpc_id (created or existing VPC); the
# implicit edge via the id argument covers module.vpc, so no explicit depends_on
# is needed (unlike data.aws_subnets above, whose subnets aren't covered by the
# vpc-id edge).
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
