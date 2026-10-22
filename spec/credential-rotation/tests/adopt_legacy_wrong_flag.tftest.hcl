mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:x" }
  }
}
run "v280_state" {
  command = apply
  variables {
    shape         = "v280"
    slot_a_legacy = true
    rotation_step = { otel = 0, admin = 0 }
  }
}
run "legacy_cell_wrong_flag" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 0, admin = 0 }
  }
  assert {
    condition     = output.versions.otel.a == 1 && output.client.otel == "a" && length(output.legacy_digest) == 0
    error_message = "expected: live A goes secret_string -> wo v1 (forced replace, fresh value) while clients use it"
  }
}
# Legacy cell at s=2 (clients just switched to B, not yet restarted): flag flip = early retire of A.
run "v280_at2" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 2, admin = 0 }
  }
}
run "flag_flip_mid_rotation" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 2, admin = 0 }
  }
  assert {
    condition     = output.versions.otel.a == 1 && run.v280_at2.versions.otel.a == null && output.phase.otel == 2
    error_message = "expected: A (just-left, clients may not have restarted) rewritten at a switch step"
  }
}
