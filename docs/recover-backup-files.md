# Recover accidentally overwritten or deleted backup files

With `clickhouse_backup.versioning_enabled = true`, S3 keeps earlier copies when a backup file is overwritten or deleted. An ordinary deletion adds a marker that hides the file; its saved contents remain. An authorized operator can copy a known good version back to the same name. This makes it readable again without permanently deleting any saved version. AWS describes this procedure at https://docs.aws.amazon.com/AmazonS3/latest/userguide/RestoringPreviousVersions.html.

Enabling versioning does not duplicate existing files. Extra copies created by later overwrites, and files hidden by deletions, continue to cost storage. This module adds no automatic expiry or Object Lock. Keep the setting enabled once applied; Terraform blocks removing the versioning resource through the input settings. Deliberately retiring the bucket and its saved versions requires a separate reviewed change. See https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html.

The Terraform safeguard only applies while the versioning resource remains in the module code. Removing the module or returning to an older module without that resource can suspend versioning. Keep the protected bucket and its encryption key until its saved files are no longer needed.

This repair uses S3 directly and does not require a new release of the backup software. Automatic removal of old backups is separate work.

## Before repairing files

Pause scheduled backups and cleanup, and wait for active jobs to finish. Record their previous settings so they can be restored afterward. If versioning has just been enabled for the first time, wait 15 minutes before writing or deleting any file, as AWS recommends: https://docs.aws.amazon.com/AmazonS3/latest/userguide/manage-versioning-examples.html.

Identify the affected backup and the exact files that changed. Include both its backup metadata and its data files; an incremental backup may also need its full backup and earlier incremental backups. Choose versions from before the mistake that belong to the same successful backup. Restoring only the listing that describes a backup does not restore missing data files. Do not copy every old version in the bucket indiscriminately.

Use an operator role limited to the affected bucket and files. The commands below need `s3:GetBucketLocation`, `s3:GetBucketVersioning`, `s3:ListBucketVersions`, `s3:GetObjectVersion`, `s3:GetObject`, and `s3:PutObject`, plus `kms:Decrypt` and `kms:GenerateDataKey` for the backup key. Copying object tags also needs `s3:PutObjectTagging` if the selected file has tags. No `s3:DeleteObjectVersion` permission is needed. Keep these repair permissions separate from the read-only role used to restore a database. AWS's permission reference is https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html.

## Repair one selected file

Use AWS CLI v2, Python 3, and `jq`. Run these commands in one Bash session, replacing the example values. The expected account and key ARN should come from the deployment record, not from the damaged file.

```bash
set -euo pipefail
umask 077
REPAIR_PROFILE='backup-repair'
REPAIR_ACCOUNT='123456789012'
REPAIR_REGION='us-west-2'
REPAIR_BUCKET='example-backup-bucket'
REPAIR_KEY_ARN='arn:aws:kms:us-west-2:123456789012:key/replace-with-backup-key-id'
REPAIR_OBJECT='replace-with-exact-backup-file-name'
REPAIR_RECORD=$(mktemp -d)
backup_aws() {
  aws --profile "$REPAIR_PROFILE" --region "$REPAIR_REGION" --no-cli-pager "$@"
}

test "$(backup_aws sts get-caller-identity --query Account --output text)" = "$REPAIR_ACCOUNT"
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

The following command changes **only the selected file**. `copy-object` supports files up to 5 GB; larger files need a separately reviewed multipart copy. The size check below uses a conservative 5,000,000,000-byte limit. The source name and version ID are encoded so spaces and special characters are handled correctly.

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
print(quote(bucket + "/" + key, safe="/") + "?versionId=" + quote(version, safe=""))
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

Have the backup software read the repaired backup. Then restore it into a separate database or cluster, using the normal read-only recovery permissions. For an incremental backup, check that the full backup and every required earlier incremental are readable too. Compare the restored tables, row counts, and recorded data checks with the original test data or the evidence saved when that backup was verified. A matching file size alone does not prove that a database can be restored.

Resume the previous schedule only after the repair and restore checks pass. Keep cleanup paused if it could remove files still being investigated. This procedure does not permanently remove any stored versions.
