# A separate monitor checks scheduled Jobs every five minutes. CloudWatch runs
# outside Kubernetes and also alerts when the monitor stops reporting.
locals {
  clickhouse_backup_monitoring_enabled = var.clickhouse_backup_monitoring != null
  clickhouse_backup_metric_namespace   = "AO/ClickHouseBackup"
  clickhouse_backup_monitor_alarms = {
    failed = {
      metric              = "BackupJobFailed"
      description         = "The scheduled ClickHouse backup or its cleanup failed. Check the otel-backup Job logs in the montecarlo namespace."
      comparison_operator = "GreaterThanOrEqualToThreshold"
      statistic           = "Maximum"
      evaluation_periods  = 1
      treat_missing_data  = "notBreaching"
    }
    overdue = {
      metric              = "BackupOverdue"
      description         = "No scheduled ClickHouse backup completed within the configured maximum age. Manual backups do not count. Check the otel-backup CronJob and its Jobs in montecarlo."
      comparison_operator = "GreaterThanOrEqualToThreshold"
      statistic           = "Maximum"
      evaluation_periods  = 1
      treat_missing_data  = "notBreaching"
    }
    monitor = {
      metric              = "MonitorHealthy"
      description         = "The ClickHouse backup monitor failed or stopped reporting. Check the backup monitor CronJob, Kubernetes access, and its permission to publish CloudWatch metrics."
      comparison_operator = "LessThanThreshold"
      statistic           = "Minimum"
      evaluation_periods  = 3
      treat_missing_data  = "breaching"
    }
  }
  clickhouse_backup_alarm_names = {
    for key in keys(local.clickhouse_backup_monitor_alarms) : key => "${local.region_qualified_name}-clickhouse-backup-${key}"
  }
}

data "aws_caller_identity" "clickhouse_backup_monitor" {
  count = local.clickhouse_backup_monitoring_enabled ? 1 : 0
}

resource "aws_iam_role" "clickhouse_backup_monitor" {
  count = local.clickhouse_backup_monitoring_enabled ? 1 : 0

  name_prefix = "${substr(local.region_qualified_name, 0, 22)}-backup-monitor-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:${kubernetes_namespace_v1.montecarlo.metadata[0].name}:clickhouse-backup-monitor"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.clickhouse_backup_install_enabled
      error_message = "clickhouse_backup_monitoring requires clickhouse_backup storage and helm.clickhouse.backup.enabled = true with chart deployment enabled."
    }
    precondition {
      condition = (
        local.chart_version_parts[0] > 5 ||
        (local.chart_version_parts[0] == 5 && local.chart_version_parts[1] >= 3)
      )
      error_message = "Backup monitoring requires helm.chart_version based on 5.3.0 or later. Use a published release or development build containing monitoring support."
    }
  }
}

resource "aws_iam_role_policy" "clickhouse_backup_monitor" {
  count = local.clickhouse_backup_monitoring_enabled ? 1 : 0

  name = "clickhouse-backup-metrics"
  role = aws_iam_role.clickhouse_backup_monitor[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "cloudwatch:PutMetricData"
      Resource = "*" # PutMetricData has no resource-level permission.
      Condition = {
        StringEquals = { "cloudwatch:namespace" = local.clickhouse_backup_metric_namespace }
      }
    }]
  })
}

resource "aws_sns_topic" "clickhouse_backup" {
  count = local.clickhouse_backup_monitoring_enabled ? 1 : 0

  name = "${local.region_qualified_name}-clickhouse-backup-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "clickhouse_backup_email" {
  count = local.clickhouse_backup_monitoring_enabled ? 1 : 0

  topic_arn = aws_sns_topic.clickhouse_backup[0].arn
  protocol  = "email"
  endpoint  = var.clickhouse_backup_monitoring.alert_email
}

resource "aws_sns_topic_policy" "clickhouse_backup" {
  count = local.clickhouse_backup_monitoring_enabled ? 1 : 0

  arn = aws_sns_topic.clickhouse_backup[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowBackupAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.clickhouse_backup[0].arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.clickhouse_backup_monitor[0].account_id }
        ArnEquals = {
          "aws:SourceArn" = [for name in values(local.clickhouse_backup_alarm_names) : "arn:${data.aws_partition.current.partition}:cloudwatch:${var.region}:${data.aws_caller_identity.clickhouse_backup_monitor[0].account_id}:alarm:${name}"]
        }
      }
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "clickhouse_backup" {
  for_each = local.clickhouse_backup_monitoring_enabled ? local.clickhouse_backup_monitor_alarms : {}

  alarm_name          = local.clickhouse_backup_alarm_names[each.key]
  alarm_description   = each.value.description
  namespace           = local.clickhouse_backup_metric_namespace
  metric_name         = each.value.metric
  comparison_operator = each.value.comparison_operator
  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.evaluation_periods
  threshold           = 1
  treat_missing_data  = each.value.treat_missing_data
  dimensions = {
    Cluster   = local.effective_cluster_name
    Namespace = kubernetes_namespace_v1.montecarlo.metadata[0].name
    CronJob   = "otel-backup"
  }
  alarm_actions = [aws_sns_topic.clickhouse_backup[0].arn]
  ok_actions    = [aws_sns_topic.clickhouse_backup[0].arn]
  tags          = var.tags

  depends_on = [aws_sns_topic_policy.clickhouse_backup]
}
