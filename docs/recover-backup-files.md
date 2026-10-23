# Recover accidentally overwritten or deleted backup files

With `clickhouse_backup.versioning_enabled = true`, S3 keeps earlier copies when a backup file is overwritten or deleted. An ordinary deletion adds a marker that hides the file; its saved contents remain. An authorized operator can copy a known good version back to the same name. This makes it readable again without permanently deleting any saved version. AWS describes this procedure at https://docs.aws.amazon.com/AmazonS3/latest/userguide/RestoringPreviousVersions.html.

Enabling versioning does not duplicate existing files. Extra copies created by later overwrites, and files hidden by deletions, continue to cost storage. This module does not enable Object Lock. Older versions have no expiry by default; if `noncurrent_version_expiration_days` is configured, repair must finish before those versions expire. The period starts when a file is overwritten or deleted. Enabling versioning is a one-way choice through the module inputs: after it is applied, Terraform blocks setting `versioning_enabled = false`, setting `clickhouse_backup = null`, changing the bucket name, and running `terraform destroy`. See https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html.

The Terraform safeguard only applies while the versioning resource remains in the module code. Removing the module or returning to an older module without that resource can suspend versioning. For a deliberate exit, follow [Retiring versioned backup storage](../README.md#retiring-versioned-backup-storage). That procedure uses `terraform state rm` to stop managing the versioning resource while leaving S3 versioning `Enabled`; it does not delete the bucket, its files, or its encryption key. Keep the protected bucket and its encryption key until its saved files are no longer needed.

This repair uses S3 directly and does not require a new release of the backup software. The optional `noncurrent_version_expiration_days` setting lets S3 remove older versions after the chosen recovery period, including existing versions old enough to qualify. Versions already expired cannot be recovered. Do not grant `s3:DeleteObjectVersion` to the backup role for future cleanup; use a separately reviewed cleanup policy.

## Before repairing files

Pause scheduled backups and cleanup, and wait for active jobs to finish. Record their previous settings so they can be restored afterward. If versioning has just been enabled for the first time, wait 15 minutes before writing or deleting any file, as AWS recommends: https://docs.aws.amazon.com/AmazonS3/latest/userguide/manage-versioning-examples.html.

Identify the affected backup and the exact files that changed. Include both its backup metadata and its data files; an incremental backup may also need its full backup and earlier incremental backups. Choose versions from before the mistake that belong to the same successful backup. Restoring only the listing that describes a backup does not restore missing data files. Do not copy every old version in the bucket indiscriminately.

Use an operator role limited to the affected bucket and files. The commands below need `s3:GetBucketLocation`, `s3:GetBucketVersioning`, `s3:ListBucketVersions`, `s3:GetObjectVersion`, `s3:GetObject`, and `s3:PutObject`, plus `kms:DescribeKey`, `kms:Decrypt`, and `kms:GenerateDataKey` for the backup key. Copying object tags also needs `s3:PutObjectTagging` if the selected file has tags. No `s3:DeleteObjectVersion` permission is needed. AWS's permission reference is https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html.

Keep these repair permissions separate from the read-only role used for an isolated database restore. This module creates an upload role with `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject`; it does not create a read-only restore role. The operator must provide that separate role, limited to reading the backup bucket and decrypting its backup key.

## Repair one selected file

Use AWS CLI v2, Python 3, and `jq`. Run these commands in one Bash session, replacing the example values. Get the expected account, region, bucket, and cluster name from the deployment record. The effective cluster name is `cluster.name` when `cluster.create = true`, or `cluster.existing_cluster_name` otherwise. After checking the account, the commands resolve the backup key ARN from the module's KMS alias, rather than trusting the damaged file. The lookup needs `kms:DescribeKey`: https://docs.aws.amazon.com/cli/latest/reference/kms/describe-key.html.

Set `REPAIR_OBJECT` to the full S3 object key, including its `clickhouse/` prefix; do not include `s3://` or the bucket name.

```bash
set -euo pipefail
umask 077
REPAIR_PROFILE='backup-repair'
REPAIR_ACCOUNT='123456789012'
REPAIR_REGION='us-west-2'
REPAIR_BUCKET='example-backup-bucket'
REPAIR_CLUSTER='replace-with-effective-cluster-name'
REPAIR_OBJECT='clickhouse/replace-with-exact-backup-file-name'
REPAIR_RECORD=$(mktemp -d)
backup_aws() {
  aws --profile "$REPAIR_PROFILE" --region "$REPAIR_REGION" --no-cli-pager "$@"
}

test "$(backup_aws sts get-caller-identity --query Account --output text)" = "$REPAIR_ACCOUNT"
REPAIR_KEY_ARN=$(backup_aws kms describe-key \
  --key-id "alias/${REPAIR_CLUSTER}-clickhouse-backup" \
  --query KeyMetadata.Arn --output text)
REPAIR_BUCKET_REGION=$(backup_aws s3api get-bucket-location \
  --bucket "$REPAIR_BUCKET" --expected-bucket-owner "$REPAIR_ACCOUNT" \
  --query LocationConstraint --output text)
case "$REPAIR_BUCKET_REGION" in
  None) REPAIR_BUCKET_REGION='us-east-1' ;;
  EU) REPAIR_BUCKET_REGION='eu-west-1' ;;
esac
test "$REPAIR_BUCKET_REGION" = "$REPAIR_REGION"
test "$(backup_aws s3api get-bucket-versioning \
  --bucket "$REPAIR_BUCKET" --expected-bucket-owner "$REPAIR_ACCOUNT" \
  --query Status --output text)" = 'Enabled'

backup_aws s3api list-object-versions \
  --bucket "$REPAIR_BUCKET" --prefix "$REPAIR_OBJECT" \
  --expected-bucket-owner "$REPAIR_ACCOUNT" --output json \
  > "$REPAIR_RECORD/versions.json"
jq --arg key "$REPAIR_OBJECT" '{
  Versions: [.Versions[]? | select(.Key == $key)],
  DeleteMarkers: [.DeleteMarkers[]? | select(.Key == $key)]
}' "$REPAIR_RECORD/versions.json"
```

Stop if any check fails. From `Versions`, choose the known good `VersionId`, checking its time, size, and backup records. A delete marker has no file contents and cannot be the source. The literal version ID `null` can be valid for a file written before versioning was enabled.

The following command changes **only the selected file**. `copy-object` supports files up to 5 GB; larger files need a separately reviewed multipart copy. The size check below uses a conservative 5,000,000,000-byte limit. AWS CLI v2 encodes the source bucket and object key itself, so pass those unchanged and encode only the version ID. This command rejects keys containing the literal text `?versionId=` because the CLI would mistake it for the version selector.

```bash
REPAIR_VERSION='replace-with-known-good-version-id'
backup_aws s3api head-object \
  --bucket "$REPAIR_BUCKET" --key "$REPAIR_OBJECT" --version-id "$REPAIR_VERSION" \
  --expected-bucket-owner "$REPAIR_ACCOUNT" --output json \
  > "$REPAIR_RECORD/source.json"
jq -e --arg key "$REPAIR_KEY_ARN" \
  '.ContentLength <= 5000000000 and .ServerSideEncryption == "aws:kms" and .SSEKMSKeyId == $key' \
  "$REPAIR_RECORD/source.json"

REPAIR_SOURCE=$(python3 - "$REPAIR_BUCKET" "$REPAIR_OBJECT" "$REPAIR_VERSION" <<'PY'
import sys
from urllib.parse import quote
bucket, key, version = sys.argv[1:]
if "?versionId=" in key:
    raise SystemExit("This command does not support object keys containing '?versionId='.")
print(bucket + "/" + key + "?versionId=" + quote(version, safe=""))
PY
)
backup_aws s3api copy-object \
  --bucket "$REPAIR_BUCKET" --key "$REPAIR_OBJECT" --copy-source "$REPAIR_SOURCE" \
  --expected-bucket-owner "$REPAIR_ACCOUNT" --expected-source-bucket-owner "$REPAIR_ACCOUNT" \
  --metadata-directive COPY --tagging-directive COPY \
  --server-side-encryption aws:kms --ssekms-key-id "$REPAIR_KEY_ARN" \
  --bucket-key-enabled --output json > "$REPAIR_RECORD/copy.json"
backup_aws s3api head-object \
  --bucket "$REPAIR_BUCKET" --key "$REPAIR_OBJECT" \
  --expected-bucket-owner "$REPAIR_ACCOUNT" --output json \
  > "$REPAIR_RECORD/current.json"
jq -e --arg key "$REPAIR_KEY_ARN" \
  --slurpfile source "$REPAIR_RECORD/source.json" \
  --slurpfile copy "$REPAIR_RECORD/copy.json" \
  '.VersionId == $copy[0].VersionId and .VersionId != $source[0].VersionId and
   .ContentLength == $source[0].ContentLength and
   .ServerSideEncryption == "aws:kms" and .SSEKMSKeyId == $key' \
  "$REPAIR_RECORD/current.json"
```

Keep a record of the object name, chosen version ID, new version ID, and these command results. Repeat only for other files confirmed to need repair. Details of the copy command: https://docs.aws.amazon.com/cli/latest/reference/s3api/copy-object.html.

## Check the repaired backup

This guide repairs S3 files only; a complete tested database restore procedure is not yet documented in this public module. Have the backup software read the repaired backup, then follow your own tested restore procedure in a separate database or cluster using the operator-provided read-only role. For an incremental backup, check that the full backup and every required earlier incremental are readable too. Compare the restored tables, row counts, and recorded data checks with the original test data or the evidence saved when that backup was verified. A matching file size alone does not prove that a database can be restored.

Resume the previous schedule only after the repair and restore checks pass. Keep both `cleanup` and `local_cleanup` paused if they could remove S3 backup files or database-disk backup records still being investigated: set `helm.clickhouse.backup.cleanup.enabled = false` and `helm.clickhouse.backup.local_cleanup.enabled = false`, review the plan, and apply the change before resuming scheduled backups. This procedure does not permanently remove any stored versions.
