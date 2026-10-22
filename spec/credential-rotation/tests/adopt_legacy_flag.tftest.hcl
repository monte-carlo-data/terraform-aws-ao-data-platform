mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:x" }
  }
}

# A cell whose slot A is already write-only adopts the two-slot model inertly.
run "wo13_state" {
  command = apply
  variables {
    shape         = "wo13"
    slot_a_legacy = false
    rotation_step = { otel = 0, admin = 0 }
  }
}
run "wo13_adopt" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 0, admin = 0 }
  }
  assert {
    condition     = output.versions.otel.a == run.wo13_state.versions.otel.a && output.versions.admin.a == run.wo13_state.versions.admin.a && length(output.legacy_digest) == 0
    error_message = "A version must stay at 1 (no replace), no managed generator"
  }
  assert {
    condition     = output.versions.otel.b == 1 && output.external_secret.otel.remoteRef.key == run.wo13_state.external_secret.otel.remoteRef.key
    error_message = "B created v1, client key unchanged"
  }
}
# HAZARD: the same cell with the wrong flag re-mints the live slot A as a secret_string.
run "wo13_wrong_flag" {
  command = plan
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 0, admin = 0 }
  }
  assert {
    condition     = output.versions.otel.a == null && contains(keys(output.legacy_digest), "otel") && output.client.otel == "a"
    error_message = "expected: live A flips wo -> secret_string with a NEW managed password"
  }
}
# Once A has been retired (s >= 3), the flag is inert in both directions.
run "wo13_at3" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 3, admin = 0 }
  }
}
run "flag_inert_after_migration" {
  command = plan
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 3, admin = 0 }
  }
  assert {
    condition     = output.versions.otel.a == run.wo13_at3.versions.otel.a && !contains(keys(output.legacy_digest), "otel")
    error_message = "flag must be inert for a user whose A has been rewritten"
  }
  assert {
    condition     = output.versions.admin.a == null
    error_message = "expected: ...but NOT for a user still at s<3 (admin here): the flag still re-mints its live A"
  }
}
