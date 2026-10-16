#!/usr/bin/env python3
"""Check the current versioning guard without AWS access or a real backend.

Run after installing providers with terraform init -backend=false:
    python3 tests/verify_backup_versioning_guard.py

Terraform test's expect_failures does not handle prevent_destroy errors. This
script instead requires that exact error after a successful mocked apply, then
checks that removing only the guard makes the same plans succeed. The resource
and its count locals come from the module; all fixture files and state are
temporary. Installed providers are reused so these checks run offline.
Older Terraform versions repeat the same guard error during mock cleanup; only
that exact additional error is accepted, and the temporary state is discarded.

The cases cover false, null, and an explicit replacement request. Mock providers
do not reproduce AWS provider replacement decisions on a bucket name change,
and Terraform 1.13 test runs do not support destroy mode.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[1]
ADDRESS = "aws_s3_bucket_versioning.clickhouse_backup[0]"
CASES = {
    "false": (
        '{ bucket_name = "test-backup-versioning-guard", versioning_enabled = false }',
        "length(aws_s3_bucket_versioning.clickhouse_backup) == 0",
        "",
    ),
    "null": ("null", "length(aws_s3_bucket_versioning.clickhouse_backup) == 0", ""),
    "replacement": (
        '{ bucket_name = "test-backup-versioning-guard", versioning_enabled = true }',
        "length(aws_s3_bucket_versioning.clickhouse_backup) == 1",
        "  plan_options {\n    replace = [aws_s3_bucket_versioning.clickhouse_backup[0]]\n  }\n",
    ),
}


def extract(pattern, source, description):
    matches = re.findall(pattern, source, flags=re.MULTILINE | re.DOTALL)
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one {description} in the module")
    return matches[0]


def fixture_configuration():
    # Terraform fmt places the closing brace of each top-level block at column 0.
    resource = extract(
        r'^resource "aws_s3_bucket_versioning" "clickhouse_backup" \{.*?^\}',
        (REPO / "s3.tf").read_text(),
        "backup versioning resource",
    )
    locals_source = (REPO / "main.tf").read_text()
    assignments = []
    for name in ("clickhouse_backup_enabled", "clickhouse_backup_versioning_enabled"):
        if f"local.{name}" in resource or name == "clickhouse_backup_enabled":
            assignments.append(extract(
                rf"^  {name}\s*=[^\n]+$", locals_source, f"{name} assignment"
            ))

    prefix = '''terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "clickhouse_backup" {
  type = object({
    bucket_name = string
    versioning_enabled = optional(bool, false)
  })
  default = null
}

locals {
''' + "\n".join(assignments) + '''
}

resource "aws_s3_bucket" "clickhouse_backup" {
  count = local.clickhouse_backup_enabled ? 1 : 0
  bucket = var.clickhouse_backup.bucket_name
}

'''
    return prefix, resource


def test_configuration(value, condition, options):
    return '''mock_provider "aws" {}

run "enable_versioning" {
  command = apply
  variables {
    clickhouse_backup = {
      bucket_name = "test-backup-versioning-guard"
      versioning_enabled = true
    }
  }
  assert {
    condition = aws_s3_bucket_versioning.clickhouse_backup[0].versioning_configuration[0].status == "Enabled"
    error_message = "The initial mocked apply must enable versioning."
  }
}

run "removal_must_be_rejected" {
  command = plan
''' + options + '''  variables {
    clickhouse_backup = ''' + value + '''
  }
  assert {
    condition = ''' + condition + '''
    error_message = "The control plan must contain the requested input change."
  }
}
'''


def expected_guard_failure(result):
    output = result.stdout
    transition, teardown, cleanup = output.partition("... tearing down")
    errors = re.findall(r"^Error: (.+)$", output, flags=re.MULTILINE)
    exact_error = "Error: Instance cannot be destroyed"
    resource_error = f"Resource {ADDRESS} has\nlifecycle.prevent_destroy set"
    return (
        result.returncode == 1
        and 'run "enable_versioning"... pass' in output
        and 'run "removal_must_be_rejected"... fail' in output
        and transition.count(exact_error) == 1
        and resource_error in transition
        and errors in (["Instance cannot be destroyed"], ["Instance cannot be destroyed"] * 2)
        and output.count(resource_error) == len(errors)
        and (len(errors) == 1 or (
            teardown
            and "Terraform encountered an error destroying resources" in cleanup
            and cleanup.count(exact_error) == 1
        ))
        and "Failure! 1 passed, 1 failed." in output
    )


def main():
    terraform = shutil.which(os.environ.get("TERRAFORM", "terraform"))
    if not terraform:
        raise RuntimeError("Terraform is required; install it or set TERRAFORM to its path")
    providers = REPO / ".terraform/providers"
    if not providers.is_dir():
        raise RuntimeError("Run terraform init -backend=false in the module first to install providers")
    prefix, resource = fixture_configuration()

    with tempfile.TemporaryDirectory(prefix="backup-versioning-guard-") as temporary:
        directory = Path(temporary)
        (directory / "tests").mkdir()
        (directory / "terraform.rc").write_text("")
        # Ignore caller settings that could select another backend, data directory,
        # workspace, remote test execution, or extra CLI arguments.
        env = {key: value for key, value in os.environ.items() if not key.startswith("TF_")}
        env.update(TF_CLI_CONFIG_FILE=str(directory / "terraform.rc"),
                   TF_IN_AUTOMATION="1", TF_INPUT="0", CHECKPOINT_DISABLE="1")
        lock = REPO / ".terraform.lock.hcl"
        if lock.exists():
            shutil.copyfile(lock, directory / lock.name)
        configuration = directory / "main.tf"
        configuration.write_text(prefix + resource + "\n")
        for case, (value, condition, options) in CASES.items():
            (directory / "tests" / f"{case}.tftest.hcl").write_text(
                test_configuration(value, condition, options)
            )

        def run(*arguments):
            return subprocess.run(
                [terraform, *arguments, "-no-color"], cwd=directory, env=env,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=120,
            )

        result = run("init", "-backend=false", "-input=false", f"-plugin-dir={providers}")
        if result.returncode:
            raise RuntimeError("Temporary fixture initialization failed:\n" + result.stdout)

        for case in CASES:
            result = run("test", f"-filter=tests/{case}.tftest.hcl")
            if not expected_guard_failure(result):
                raise RuntimeError(f"{case}: expected only the versioning prevent_destroy error:\n{result.stdout}")
            print(f"PASS {case}: the versioning guard rejects the change", flush=True)

        # Change only the temporary resource. Every previously blocked plan must
        # now succeed, proving an unrelated error did not produce the failures.
        unguarded, replacements = re.subn(
            r"^\s*prevent_destroy\s*=\s*true\s*$", "", resource, flags=re.MULTILINE
        )
        if replacements != 1:
            raise RuntimeError("Expected one prevent_destroy = true assignment for the control")
        configuration.write_text(prefix + unguarded + "\n")
        result = run("test")
        if result.returncode or "Success! 6 passed, 0 failed." not in result.stdout:
            raise RuntimeError("Plans without the guard did not all succeed:\n" + result.stdout)
        print("PASS control: all three changes plan successfully without the guard")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
