# Kubernetes Namespaces

resource "kubernetes_namespace_v1" "montecarlo" {
  metadata {
    name = "montecarlo"
  }

  depends_on = [module.eks, data.aws_eks_cluster.existing]
}

# gp3 StorageClass — cluster-wide EBS storage class used by the ao-data-platform chart.
# EKS clusters ship with gp2 by default; gp3 offers better baseline performance at the same cost.

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
  depends_on = [module.eks, data.aws_eks_cluster.existing]
}

# clickhouse-gp3 StorageClass — dedicated EBS class for ClickHouse.
# Mirrors the cluster-wide gp3 class above but hardens it for stateful CH data:
# reclaim_policy = Retain (deleting a PVC leaves the backing EBS volume intact)
# and explicit, tunable IOPS/throughput (gp3 baseline 3000/125 can be saturated
# by CH merges). Always created; ClickHouse requests it by default
# (var.clickhouse_storage_class), and existing gp3 deployments opt out by
# pinning that variable back to "gp3" (a live StatefulSet's storageClassName is
# immutable). Tuned via var.storage_class_clickhouse_gp3.

resource "kubernetes_storage_class_v1" "clickhouse_gp3" {
  metadata {
    name = "clickhouse-gp3"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type       = "gp3"
    encrypted  = "true"
    iops       = tostring(var.storage_class_clickhouse_gp3.iops)
    throughput = tostring(var.storage_class_clickhouse_gp3.throughput)
  }
  depends_on = [module.eks, data.aws_eks_cluster.existing]
}
