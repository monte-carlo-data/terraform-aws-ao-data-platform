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
# objects (tolerable — the producer's export watermark re-covers the window)
# rather than dropping notifications silently. No DLQ: the receiver deletes
# what it processes or filters, transient failures retry via the visibility
# timeout, and gap recovery is the producer's job.

resource "aws_sqs_queue" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  name                       = local.trace_export_ingest_queue_name
  message_retention_seconds  = 1209600 # 14 days (maximum)
  visibility_timeout_seconds = 300
  tags                       = var.tags
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
