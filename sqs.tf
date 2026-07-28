# -----------------------------------------------------------------------------
# Trace-export ingest notification queue (var.trace_export_ingest)
# -----------------------------------------------------------------------------
# Dedicated queue for the ingest bucket's object-created notifications,
# consumed exclusively by the collector's synthesized awss3 receiver — in SQS
# mode a receiver deletes messages whose records it filtered out, so this
# queue must never be shared (see the awss3_receivers docs on var.helm).
#
# Retention is deliberately longer than the object lifecycle: after a long
# collector outage the backlog drains to some GetObject misses on expired
# objects rather than dropping notifications silently. This is tolerable
# because the awss3 receiver treats a GetObject 404 (NoSuchKey) as terminal —
# it deletes the SQS message instead of redelivering, so an expired object
# can't become a poison backlog (verified against awss3receiver v0.150.0;
# re-check on a receiver bump). The producer's export watermark re-covers the
# window regardless. No DLQ: the receiver deletes what it processes or filters,
# other transient failures retry via the visibility timeout, and gap recovery
# is the producer's job.

resource "aws_sqs_queue" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  name                       = local.trace_export_ingest_queue_name
  message_retention_seconds  = 1209600 # 14 days (maximum)
  visibility_timeout_seconds = 300
  tags                       = var.tags

  lifecycle {
    # The synthesized receiver renders under the "awss3/trace-export-ingest"
    # component ID; an *enabled* caller awss3_receivers entry with that key
    # would be silently overwritten in the merged map. Scoped to enabled
    # entries because the merge itself filters on m.enabled — a disabled
    # entry under that key never collides, and the README documents keeping
    # one around (e.g. to stage a future receiver) as supported. Anchored
    # here — not on the helm release — because this queue exists whenever
    # the block is set, so the guard also fires for chartless
    # (deploy_charts = false) deployments.
    precondition {
      condition     = !contains([for name, m in var.helm.opentelemetry_collector.awss3_receivers : name if m.enabled], "trace-export-ingest")
      error_message = "helm.opentelemetry_collector.awss3_receivers must not contain an enabled entry keyed \"trace-export-ingest\" while trace_export_ingest is set — that component ID (\"awss3/trace-export-ingest\") is reserved for the receiver this module synthesizes for the ingest leg. A disabled entry under that key is fine; it is dropped from the merge before rendering."
    }

    # The module-wide "every enabled receiver gets its own queue" check
    # (helm.opentelemetry_collector's duplicate sqs_queue_arn validation)
    # only sees var.helm, not this queue's ARN — it is synthesized in a
    # local, not supplied by the caller. Without this guard a caller
    # receiver could point at the same queue as the synthesized ingest
    # receiver and neither validation would catch it: in SQS mode each
    # receiver deletes messages whose records it filtered out, so the two
    # receivers sharing this queue would silently destroy each other's
    # notifications.
    precondition {
      condition = alltrue([
        for name, m in var.helm.opentelemetry_collector.awss3_receivers : m.sqs_queue_arn != local.trace_export_ingest_queue_arn if m.enabled
        ]) && (
        try(var.helm.opentelemetry_collector.awss3_receiver.enabled, false)
        ? var.helm.opentelemetry_collector.awss3_receiver.sqs_queue_arn != local.trace_export_ingest_queue_arn
        : true
      )
      error_message = "A caller awss3 receiver (helm.opentelemetry_collector.awss3_receiver or an awss3_receivers entry) must not reuse the ingest queue's ARN (local.trace_export_ingest_queue_arn) while trace_export_ingest is set — sharing an SQS-mode queue with the synthesized ingest receiver causes the two receivers to delete each other's notifications, silently dropping traces."
    }
  }
}

resource "aws_sqs_queue_policy" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  queue_url = aws_sqs_queue.trace_export_ingest[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowIngestBucketNotifications"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = local.trace_export_ingest_queue_arn
        # Both conditions on purpose: S3 bucket ARNs carry no account ID, so
        # aws:SourceArn alone would let a foreign account that re-registers
        # this bucket name (after a teardown) inject forged notifications.
        # aws:SourceAccount pins the sender to this account.
        Condition = {
          ArnEquals    = { "aws:SourceArn" = local.trace_export_ingest_bucket_arn }
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.trace_export_ingest[0].account_id }
        }
      },
    ]
  })
}
