mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:x" }
  }
}

run "at0" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 0, admin = 0 }
  }
}

run "plus2_0_to_2" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 2, admin = 0 }
  }
  assert {
    condition     = (output.versions.otel.b != run.at0.versions.otel.b) && (jsonencode(output.external_secret.otel) != jsonencode(run.at0.external_secret.otel)) && output.client.otel == "b"
    error_message = "expected: write B + switch to B in ONE apply (the single-apply break)"
  }
}

run "plus3_0_to_3" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 3, admin = 0 }
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.at0.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at0.versions.otel.a == null)) && (output.versions.otel.b != run.at0.versions.otel.b) && (jsonencode(output.external_secret.otel) != jsonencode(run.at0.external_secret.otel))
    error_message = "expected: both slots rewritten + keys switched (total lockout)"
  }
}

run "at1" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 1, admin = 0 }
  }
}

run "plus2_1_to_3" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 3, admin = 0 }
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.at1.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at1.versions.otel.a == null)) && (jsonencode(output.external_secret.otel) != jsonencode(run.at1.external_secret.otel)) && run.at1.client.otel == "a"
    error_message = "expected: switch + retire the slot clients were on, in one apply (lockout: no restart window)"
  }
}

run "at2" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 2, admin = 0 }
  }
}

run "plus2_2_to_4_passes_per_user_rule" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 4, admin = 0 }
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.at2.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at2.versions.otel.a == null)) && !(output.versions.otel.b != run.at2.versions.otel.b) && !(jsonencode(output.external_secret.otel) != jsonencode(run.at2.external_secret.otel)) && run.at2.client.otel == "b"
    error_message = "expected: retire+write coalesce into ONE write of the spare A; per-user rule passes; actually safe"
  }
}

run "at3" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 3, admin = 0 }
  }
}

run "plus2_3_to_5" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 5, admin = 0 }
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.at3.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at3.versions.otel.a == null)) && (jsonencode(output.external_secret.otel) != jsonencode(run.at3.external_secret.otel)) && output.client.otel == "a"
    error_message = "expected: write A + switch to A in one apply (the single-apply break, mirrored)"
  }
}

run "at5" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 5, admin = 0 }
  }
}

run "minus2_5_to_3" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 3, admin = 0 }
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.at5.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at5.versions.otel.a == null)) && (jsonencode(output.external_secret.otel) != jsonencode(run.at5.external_secret.otel)) && run.at5.client.otel == "a"
    error_message = "expected: rewrites A, the slot clients are on, and switches to B (lockout)"
  }
}

run "at4" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 4, admin = 0 }
  }
}

run "reset_4_to_0" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 0, admin = 0 }
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.at4.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at4.versions.otel.a == null)) && (output.versions.otel.b != run.at4.versions.otel.b) && output.versions.otel.a < run.at4.versions.otel.a
    error_message = "expected: reset rewrites both slots"
  }
}

run "at4_admin2" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 4, admin = 2 }
  }
}

run "mixed_otel_write_admin_switch_admin_retire" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 5, admin = 3 }
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.at4_admin2.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at4_admin2.versions.otel.a == null)) == false && (jsonencode(output.external_secret.otel) != jsonencode(run.at4_admin2.external_secret.otel))
    error_message = "otel 4->5 is a pure switch"
  }
  assert {
    condition     = output.versions.admin.a != run.at4_admin2.versions.admin.a && jsonencode(output.external_secret.admin) == jsonencode(run.at4_admin2.external_secret.admin)
    error_message = "admin 2->3 is a pure retire (A written, keys unchanged)"
  }
}

run "at1_admin0" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 1, admin = 0 }
  }
}

run "mixed_otel_switch_admin_write" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 2, admin = 1 }
  }
  assert {
    condition     = (jsonencode(output.external_secret.otel) != jsonencode(run.at1_admin0.external_secret.otel)) && !(coalesce(output.versions.otel.a, 0) != coalesce(run.at1_admin0.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at1_admin0.versions.otel.a == null)) && !(output.versions.otel.b != run.at1_admin0.versions.otel.b)
    error_message = "otel switch"
  }
  assert {
    condition     = output.versions.admin.b != run.at1_admin0.versions.admin.b && jsonencode(output.external_secret.admin) == jsonencode(run.at1_admin0.external_secret.admin)
    error_message = "admin write B; helm_release still changes in this apply (otel keys) -> bundle spec changes while admin B is being written, with no ordering edge"
  }
}
