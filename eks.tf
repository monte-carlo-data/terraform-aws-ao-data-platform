data "aws_eks_cluster" "existing" {
  count = var.cluster.create ? 0 : 1
  name  = var.cluster.existing_cluster_name
}

locals {
  # Dedicated per-AZ ClickHouse Keeper node groups (one voter per AZ), merged
  # into the module's eks_managed_node_groups below. Keyed keeper-<az>; the count
  # is length(keeper_availability_zones) — the same list that drives the chart's
  # keeper.replicaCount, so voters and node capacity cannot drift. Each is a
  # single-AZ, tainted (dedicated=keeper) group so only Keeper pods (which carry
  # the matching toleration, wired in helm.tf) schedule here, kept off the
  # ClickHouse nodes so a CH node failure can't also drop a voter.
  keeper_node_groups = local.clickhouse_node_placement_enabled ? {
    for az in var.keeper_availability_zones : "keeper-${az}" => {
      instance_types = [var.keeper_node_group.instance_type]
      min_size       = 1
      max_size       = 1
      desired_size   = 1
      subnet_ids     = local.keeper_subnet_ids_by_az[az]

      # Pin the AMI (no per-apply SSM "latest" lookup), same rationale as the
      # ClickHouse node group: with N single-AZ voters, an uncontrolled AMI
      # drift could try to roll all of them at once and lose quorum. Bump
      # deliberately, one at a time, via keeper_node_group.ami_release_version.
      use_latest_ami_release_version = var.keeper_node_group.use_latest_ami_release_version
      ami_release_version            = var.keeper_node_group.ami_release_version

      # force_update_version stays false (the module default): a keeper voter is
      # part of an HA quorum, so its node drains gracefully behind the chart's
      # PDB. force = true would force-terminate past the drain timeout, ignoring
      # the PDB and risking multiple voters down at once — the opposite of what
      # the legacy single-replica ClickHouse node group needs it for.
      force_update_version = false

      labels = {
        (local.keeper_node_label_key) = local.keeper_node_label_value
      }
      taints = {
        dedicated = {
          key    = local.keeper_node_label_key
          value  = local.keeper_node_label_value
          effect = "NO_SCHEDULE"
        }
      }

      # Hop limit 1: Keeper calls no AWS APIs (no IRSA), and the EKS-managed
      # DaemonSets that land here reach IMDS via hostNetwork. Matches the
      # ClickHouse node group.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  } : {}

  # Dedicated per-AZ ClickHouse node groups for the clustered/HA topology, one
  # per clickhouse_availability_zones entry (keyed clickhouse-<az>), merged into
  # eks_managed_node_groups below. They share the SAME dedicated=clickhouse
  # taint/label as the legacy node group, so at migration a ClickHouse pod
  # evicted off the legacy node schedules straight onto the matching per-AZ node.
  #
  # Created ACTIVE (desired=1), symmetric with the keeper node groups: setting
  # clickhouse_availability_zones brings the nodes up. They come up EMPTY — no CH
  # replica lands until clickhouse_replica_count is raised at migration — and sit
  # idle until then. Set the AZ list shortly before raising the replica count to
  # bound the idle-node cost; standing the nodes up ahead of the cutover moves
  # all provisioning risk (capacity, subnets, AMI, EBS CSI) OUTSIDE the
  # maintenance window. We deliberately do NOT park at desired=0 and scale up on
  # migration day: the EKS managed-node-group submodule sets
  # ignore_changes = [scaling_config[0].desired_size], so a later desired_size
  # bump yields no plan diff and no node — the failure would surface mid-window
  # with ingest already stopped.
  #
  # Instance type comes from clickhouse_ha_node_group (r6i.xlarge) — deliberately
  # NOT clickhouse_node_group.instance_type, so the legacy node group's type is
  # never changed (which would roll the live pod).
  #
  # AMI pinned like the legacy/keeper node groups; force_update_version stays
  # false — at RF>=2 a replica drains gracefully behind the PDB, and force would
  # force-terminate past the drain timeout (ignoring the PDB) and could roll both
  # single-AZ replicas at once.
  clickhouse_ha_node_groups = local.clickhouse_node_placement_enabled ? {
    for az in var.clickhouse_availability_zones : "clickhouse-${az}" => {
      instance_types = [var.clickhouse_ha_node_group.instance_type]
      min_size       = 1
      max_size       = 1
      desired_size   = 1
      subnet_ids     = local.clickhouse_subnet_ids_by_az[az]

      use_latest_ami_release_version = var.clickhouse_ha_node_group.use_latest_ami_release_version
      ami_release_version            = var.clickhouse_ha_node_group.ami_release_version
      force_update_version           = false

      labels = {
        (local.clickhouse_node_label_key) = local.clickhouse_node_label_value
      }
      taints = {
        dedicated = {
          key    = local.clickhouse_node_label_key
          value  = local.clickhouse_node_label_value
          effect = "NO_SCHEDULE"
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  } : {}
}

# -----------------------------------------------------------------------------
# EKS Cluster (conditional)
# Creates a new cluster with a managed node group, standard add-ons, and OIDC.
# -----------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.10.1"
  count   = var.cluster.create ? 1 : 0

  name               = var.cluster.name
  kubernetes_version = "1.35"

  # Private access is always on (in-VPC clients, the module's local-exec
  # provisioners when run from inside the VPC); public exposure is
  # caller-controlled — see the cluster variable for the hardened path.
  endpoint_public_access                   = var.cluster.endpoint_public_access
  endpoint_public_access_cidrs             = var.cluster.endpoint_public_access_cidrs
  endpoint_private_access                  = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  # Secrets envelope encryption is enabled by default in this module version:
  # create_kms_key = true, encryption_config = { resources = ["secrets"] }

  # Addon versions are pinned explicitly (not most_recent) so applies can't
  # silently upgrade them. Bump deliberately: list versions for the target
  # cluster version and pick the default (or a newer compatible build) with
  #   aws eks describe-addon-versions --kubernetes-version <ver> --addon-name <addon>
  # Versions below are known-good builds; bump deliberately from here.
  addons = {
    vpc-cni = {
      addon_version  = "v1.22.1-eksbuild.2"
      before_compute = true

      # Enable the vpc-cni NetworkPolicy enforcement engine. No NetworkPolicy
      # objects are applied yet, so this is a no-op functionally today; it warms
      # the engine so workloads can adopt Kubernetes NetworkPolicies later
      # without an addon reconfigure (and the pod restart that comes with it).
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    coredns = {
      addon_version = "v1.14.3-eksbuild.2"
    }
    kube-proxy = {
      addon_version = "v1.35.3-eksbuild.11"
    }
    aws-ebs-csi-driver = {
      addon_version            = "v1.61.1-eksbuild.1"
      service_account_role_arn = aws_iam_role.ebs_csi_controller[0].arn
    }
  }

  eks_managed_node_groups = merge(
    {
      main = {
        instance_types = [var.cluster.node_instance_type]
        min_size       = local.main_node_group_size_resolved
        max_size       = 10
        desired_size   = local.main_node_group_size_resolved

        # IMDS hop limit 2 (default for EKS managed NGs). Every controller
        # on this NG uses IRSA (load-balancer-controller, cert-manager,
        # external-secrets, external-dns, otel-collector, llm-worker,
        # ebs-csi-controller), so no pod here currently needs pod-level
        # IMDS to assume the node's instance profile. Left at 2 as a
        # defensive default for future addons; the hostNetwork DaemonSets
        # (vpc-cni, kube-proxy, ebs-csi-node) bypass the pod hop limit
        # entirely either way.
        metadata_options = {
          http_endpoint               = "enabled"
          http_tokens                 = "required"
          http_put_response_hop_limit = 2
        }
      }
    },
    (local.clickhouse_node_placement_enabled && var.manage_legacy_clickhouse_node_group) ? {
      # Legacy single-AZ node group for ClickHouse. The taint blocks any
      # pod without a matching toleration from scheduling here; the matching
      # toleration is wired into the ClickHouse pod template automatically
      # via the helm_release values block below.
      #
      # Gated on manage_legacy_clickhouse_node_group (default true) so it can be
      # retired via config once the HA migration has relocated the ClickHouse pod
      # onto a per-AZ clickhouse-<az> node group — no module release needed to
      # remove it. Otherwise left byte-identical (same r5.xlarge instance type):
      # re-typing a managed node group replaces its instances, rolling the live
      # ClickHouse pod, so the go-forward r6i.xlarge lives on the new NGs only.
      clickhouse = {
        instance_types = [var.clickhouse_node_group.instance_type]
        min_size       = 1
        max_size       = 1
        desired_size   = 1
        subnet_ids     = local.clickhouse_node_group_subnet_ids

        # Pin the dedicated CH node group's AMI (asymmetric: the main NG
        # above keeps the eks module default use_latest = true). Defaulting
        # use_latest = false here stops the per-apply SSM "latest AMI"
        # lookup, so an unrelated apply can no longer drift the AMI and
        # bounce ClickHouse — a single-replica, AZ-locked StatefulSet whose
        # roll is a ~2 min outage. ami_release_version (null by default)
        # is the optional explicit pin; setting it performs a deliberate,
        # auditable AMI bump.
        use_latest_ami_release_version = var.clickhouse_node_group.use_latest_ami_release_version
        ami_release_version            = var.clickhouse_node_group.ami_release_version

        # Hardcoded (not a variable): a single-replica, AZ-locked,
        # PDB-protected node group can't drain gracefully, so force is
        # required for ANY roll to complete — both an (opted-in) drift roll
        # and a deliberate ami_release_version bump. Without it a pinned
        # bump fails mid-apply on PodEvictionFailure. Inert when no roll is
        # in flight. Revisit when ClickHouse goes HA (multi-replica +
        # keeper): a roll then becomes a no-downtime rolling update and
        # both this flag and the AMI pin fall away — they share the
        # single-replica root cause.
        force_update_version = true

        labels = {
          (local.clickhouse_node_label_key) = local.clickhouse_node_label_value
        }
        taints = {
          dedicated = {
            key    = local.clickhouse_node_label_key
            value  = local.clickhouse_node_label_value
            effect = "NO_SCHEDULE"
          }
        }

        # Hop limit 1 (vs 2 on the main NG): ClickHouse calls no AWS APIs
        # (the Altinity operator's ClickHouseInstallation sets no
        # ServiceAccount role-arn), so the CH pod has no IMDS dependency.
        # The EKS-managed DaemonSets that land here (aws-node, kube-proxy,
        # ebs-csi-node) reach IMDS via hostNetwork=true, which bypasses
        # the pod-level hop limit entirely. Tightening to 1 blocks
        # pod-level IMDS for any non-hostNetwork container — useful if a
        # future workload (matching the toleration) ends up co-located
        # here; it would need its own IRSA binding rather than borrowing
        # the node's instance profile.
        metadata_options = {
          http_endpoint               = "enabled"
          http_tokens                 = "required"
          http_put_response_hop_limit = 1
        }
      }
    } : {},
    local.keeper_node_groups,
    local.clickhouse_ha_node_groups,
  )

  vpc_id     = local.effective_vpc_id
  subnet_ids = local.effective_private_subnet_ids

  tags = var.tags
}

# -----------------------------------------------------------------------------
# OIDC Provider — existing clusters only
# For new clusters, the EKS module creates the OIDC provider (enable_irsa = true).
# For existing clusters, we register one if not already present.
# If the cluster already has an OIDC provider managed outside Terraform, import it:
#   terraform import 'aws_iam_openid_connect_provider.cluster[0]' <arn>
# -----------------------------------------------------------------------------

data "tls_certificate" "cluster" {
  count = var.cluster.create ? 0 : 1
  url   = data.aws_eks_cluster.existing[0].identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  count           = var.cluster.create ? 0 : 1
  url             = data.aws_eks_cluster.existing[0].identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster[0].certificates[0].sha1_fingerprint]
  tags            = var.tags
}
