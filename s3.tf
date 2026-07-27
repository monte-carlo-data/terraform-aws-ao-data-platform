# -----------------------------------------------------------------------------
# Trace-export ingest bucket (var.trace_export_ingest)
# -----------------------------------------------------------------------------
# Transit storage for the trace-export ingest leg: an external producer PUTs
# OTLP trace files under the configured prefix, the collector's awss3 receiver
# consumes them via SQS notifications (sqs.tf), and the lifecycle rule expires
# them days later. All resources are gated on the optional block — unset, none
# of this exists and the plan is identical to previous releases.

resource "aws_s3_bucket" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  bucket = local.trace_export_ingest_bucket
  # Transit data with a days-long lifecycle: disabling the block (or a
  # destroy) must not strand the deployment on a non-empty bucket.
  force_destroy = true
  tags          = var.tags

  lifecycle {
    # The default name inherits the cluster name, which allows characters and
    # lengths S3 bucket names don't. Fail at plan time with a pointer at the
    # override instead of mid-apply with an AWS validation error.
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", local.trace_export_ingest_bucket))
      error_message = "The resolved trace-export ingest bucket name (\"${local.trace_export_ingest_bucket != null ? local.trace_export_ingest_bucket : ""}\") is not a valid S3 bucket name (3-63 chars, lowercase letters, digits, hyphens, dots, alphanumeric first/last). Set trace_export_ingest.bucket_name explicitly."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.trace_export_ingest[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 by default; SSE-KMS with S3 Bucket Keys when the caller brings a CMK.
# Bucket Keys cache the data key at bucket scope, keeping per-object KMS
# request cost sane on a continuous ingest path.
resource "aws_s3_bucket_server_side_encryption_configuration" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  bucket = aws_s3_bucket.trace_export_ingest[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.trace_export_ingest.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.trace_export_ingest.kms_key_arn
    }
    bucket_key_enabled = var.trace_export_ingest.kms_key_arn != null
  }
}

# Expire transit objects under the ingest prefix, and abort abandoned
# multipart uploads at the same age so partial uploads from the external
# writer can't outlive the advertised retention.
resource "aws_s3_bucket_lifecycle_configuration" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  bucket = aws_s3_bucket.trace_export_ingest[0].id

  rule {
    id     = "expire-trace-export-transit"
    status = "Enabled"

    filter {
      prefix = local.trace_export_ingest_prefix
    }

    expiration {
      days = var.trace_export_ingest.lifecycle_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.trace_export_ingest.lifecycle_days
    }
  }
}

# Always attached while the block is set: the deny-non-TLS statement is
# unconditional (the bucket carries trace payloads), and the optional direct
# writer grant merges in as a second statement rather than reshaping the
# resource later.
resource "aws_s3_bucket_policy" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  bucket = aws_s3_bucket.trace_export_ingest[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "DenyInsecureTransport"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:*"
          Resource = [
            local.trace_export_ingest_bucket_arn,
            "${local.trace_export_ingest_bucket_arn}/*",
          ]
          Condition = { Bool = { "aws:SecureTransport" = "false" } }
        },
      ],
      var.trace_export_ingest.agent_role_arn != null ? [
        {
          Sid       = "AgentPutObject"
          Effect    = "Allow"
          Principal = { AWS = var.trace_export_ingest.agent_role_arn }
          Action    = "s3:PutObject"
          Resource  = "${local.trace_export_ingest_bucket_arn}/${local.trace_export_ingest_prefix}*"
        },
      ] : [],
    )
  })

  # aws_s3_bucket_public_access_block.block_public_policy and policy PUTs can
  # race on a fresh bucket; ordering them removes the intermittent
  # AccessDenied on first apply.
  depends_on = [aws_s3_bucket_public_access_block.trace_export_ingest]
}

# Object-created events under the ingest prefix fan into the dedicated queue
# (sqs.tf). This resource owns the bucket's ENTIRE notification configuration
# — which is exactly why the module always creates the ingest bucket rather
# than accepting a caller-managed one, whose existing notifications this
# would silently replace.
resource "aws_s3_bucket_notification" "trace_export_ingest" {
  count = local.trace_export_ingest_enabled ? 1 : 0

  bucket = aws_s3_bucket.trace_export_ingest[0].id

  queue {
    queue_arn     = local.trace_export_ingest_queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = local.trace_export_ingest_prefix
  }

  # S3 validates it can publish to the queue when the notification is
  # created; the queue policy must exist first.
  depends_on = [aws_sqs_queue_policy.trace_export_ingest]
}
