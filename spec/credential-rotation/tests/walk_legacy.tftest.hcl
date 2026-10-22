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

run "step0" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 0, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "a" && output.phase.otel == 0
    error_message = "step 0: client a phase 0"
  }
  assert {
    condition     = jsonencode(output.legacy_digest) == jsonencode(run.v280_state.legacy_digest) && output.versions.otel.a == null && output.versions.otel.b == 1
    error_message = "adoption must be inert: legacy value kept, B created v1"
  }
  assert {
    condition     = output.external_secret.otel.remoteRef.key == run.v280_state.external_secret.otel.remoteRef.key
    error_message = "adoption keeps client key"
  }
}

run "step1" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 1, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "a" && output.phase.otel == 1
    error_message = "step 1: client a phase 1"
  }
  assert {
    condition     = (((coalesce(output.versions.otel.a, 0) != coalesce(run.step0.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step0.versions.otel.a == null))) ? 1 : 0) + (((output.versions.otel.b != run.step0.versions.otel.b)) ? 1 : 0) == 1
    error_message = "step 1: write/retire must change exactly one slot version"
  }
  assert {
    condition     = !(jsonencode(output.external_secret.otel) != jsonencode(run.step0.external_secret.otel)) && output.client.otel == run.step0.client.otel
    error_message = "step 1: write/retire must not change client keys"
  }
  assert {
    condition     = (output.versions.otel.b != run.step0.versions.otel.b)
    error_message = "step 1: expected slot b written"
  }
  assert {
    condition     = "b" != run.step0.client.otel && "b" != output.client.otel
    error_message = "step 1: wrote a slot clients use"
  }
  assert {
    condition     = "b" != run.step0.client.otel
    error_message = "step 1: write must target the spare"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step0.versions.otel.a, 0) && output.versions.otel.b >= run.step0.versions.otel.b
    error_message = "step 1: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step0.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step0.external_secret.admin)
    error_message = "step 1: held user untouched"
  }
  assert {
    condition     = jsonencode(output.legacy_digest.otel) == jsonencode(run.v280_state.legacy_digest.otel)
    error_message = "step 1: legacy A preserved until retire"
  }
}

run "step2" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 2, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "b" && output.phase.otel == 2
    error_message = "step 2: client b phase 2"
  }
  assert {
    condition     = !(coalesce(output.versions.otel.a, 0) != coalesce(run.step1.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step1.versions.otel.a == null)) && !(output.versions.otel.b != run.step1.versions.otel.b)
    error_message = "step 2: switch must change no slot version"
  }
  assert {
    condition     = (jsonencode(output.external_secret.otel) != jsonencode(run.step1.external_secret.otel)) && output.client.otel != run.step1.client.otel
    error_message = "step 2: switch must change client keys"
  }
  assert {
    condition     = output.client.otel == "b"
    error_message = "step 2: switch must target the slot written by the previous apply"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step1.versions.otel.a, 0) && output.versions.otel.b >= run.step1.versions.otel.b
    error_message = "step 2: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step1.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step1.external_secret.admin)
    error_message = "step 2: held user untouched"
  }
  assert {
    condition     = jsonencode(output.legacy_digest.otel) == jsonencode(run.v280_state.legacy_digest.otel)
    error_message = "step 2: legacy A preserved until retire"
  }
}

run "step3" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 3, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "b" && output.phase.otel == 0
    error_message = "step 3: client b phase 0"
  }
  assert {
    condition     = (((coalesce(output.versions.otel.a, 0) != coalesce(run.step2.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step2.versions.otel.a == null))) ? 1 : 0) + (((output.versions.otel.b != run.step2.versions.otel.b)) ? 1 : 0) == 1
    error_message = "step 3: write/retire must change exactly one slot version"
  }
  assert {
    condition     = !(jsonencode(output.external_secret.otel) != jsonencode(run.step2.external_secret.otel)) && output.client.otel == run.step2.client.otel
    error_message = "step 3: write/retire must not change client keys"
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.step2.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step2.versions.otel.a == null))
    error_message = "step 3: expected slot a written"
  }
  assert {
    condition     = "a" != run.step2.client.otel && "a" != output.client.otel
    error_message = "step 3: wrote a slot clients use"
  }
  assert {
    condition     = "a" == run.step1.client.otel
    error_message = "step 3: retire must rewrite the slot clients left"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step2.versions.otel.a, 0) && output.versions.otel.b >= run.step2.versions.otel.b
    error_message = "step 3: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step2.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step2.external_secret.admin)
    error_message = "step 3: held user untouched"
  }
  assert {
    condition     = !contains(keys(output.legacy_digest), "otel") && output.versions.otel.a == 2 && output.a_legacy.otel == false
    error_message = "step 3 retires legacy A: managed generator destroyed, A write-only v2"
  }
  assert {
    condition     = jsonencode(output.legacy_digest.admin) == jsonencode(run.v280_state.legacy_digest.admin)
    error_message = "held admin keeps its legacy value"
  }
}

run "step4" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 4, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "b" && output.phase.otel == 1
    error_message = "step 4: client b phase 1"
  }
  assert {
    condition     = (((coalesce(output.versions.otel.a, 0) != coalesce(run.step3.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step3.versions.otel.a == null))) ? 1 : 0) + (((output.versions.otel.b != run.step3.versions.otel.b)) ? 1 : 0) == 1
    error_message = "step 4: write/retire must change exactly one slot version"
  }
  assert {
    condition     = !(jsonencode(output.external_secret.otel) != jsonencode(run.step3.external_secret.otel)) && output.client.otel == run.step3.client.otel
    error_message = "step 4: write/retire must not change client keys"
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.step3.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step3.versions.otel.a == null))
    error_message = "step 4: expected slot a written"
  }
  assert {
    condition     = "a" != run.step3.client.otel && "a" != output.client.otel
    error_message = "step 4: wrote a slot clients use"
  }
  assert {
    condition     = "a" != run.step3.client.otel
    error_message = "step 4: write must target the spare"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step3.versions.otel.a, 0) && output.versions.otel.b >= run.step3.versions.otel.b
    error_message = "step 4: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step3.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step3.external_secret.admin)
    error_message = "step 4: held user untouched"
  }
}

run "step5" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 5, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "a" && output.phase.otel == 2
    error_message = "step 5: client a phase 2"
  }
  assert {
    condition     = !(coalesce(output.versions.otel.a, 0) != coalesce(run.step4.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step4.versions.otel.a == null)) && !(output.versions.otel.b != run.step4.versions.otel.b)
    error_message = "step 5: switch must change no slot version"
  }
  assert {
    condition     = (jsonencode(output.external_secret.otel) != jsonencode(run.step4.external_secret.otel)) && output.client.otel != run.step4.client.otel
    error_message = "step 5: switch must change client keys"
  }
  assert {
    condition     = output.client.otel == "a"
    error_message = "step 5: switch must target the slot written by the previous apply"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step4.versions.otel.a, 0) && output.versions.otel.b >= run.step4.versions.otel.b
    error_message = "step 5: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step4.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step4.external_secret.admin)
    error_message = "step 5: held user untouched"
  }
}

run "step6" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 6, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "a" && output.phase.otel == 0
    error_message = "step 6: client a phase 0"
  }
  assert {
    condition     = (((coalesce(output.versions.otel.a, 0) != coalesce(run.step5.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step5.versions.otel.a == null))) ? 1 : 0) + (((output.versions.otel.b != run.step5.versions.otel.b)) ? 1 : 0) == 1
    error_message = "step 6: write/retire must change exactly one slot version"
  }
  assert {
    condition     = !(jsonencode(output.external_secret.otel) != jsonencode(run.step5.external_secret.otel)) && output.client.otel == run.step5.client.otel
    error_message = "step 6: write/retire must not change client keys"
  }
  assert {
    condition     = (output.versions.otel.b != run.step5.versions.otel.b)
    error_message = "step 6: expected slot b written"
  }
  assert {
    condition     = "b" != run.step5.client.otel && "b" != output.client.otel
    error_message = "step 6: wrote a slot clients use"
  }
  assert {
    condition     = "b" == run.step4.client.otel
    error_message = "step 6: retire must rewrite the slot clients left"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step5.versions.otel.a, 0) && output.versions.otel.b >= run.step5.versions.otel.b
    error_message = "step 6: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step5.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step5.external_secret.admin)
    error_message = "step 6: held user untouched"
  }
}

run "step7" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 7, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "a" && output.phase.otel == 1
    error_message = "step 7: client a phase 1"
  }
  assert {
    condition     = (((coalesce(output.versions.otel.a, 0) != coalesce(run.step6.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step6.versions.otel.a == null))) ? 1 : 0) + (((output.versions.otel.b != run.step6.versions.otel.b)) ? 1 : 0) == 1
    error_message = "step 7: write/retire must change exactly one slot version"
  }
  assert {
    condition     = !(jsonencode(output.external_secret.otel) != jsonencode(run.step6.external_secret.otel)) && output.client.otel == run.step6.client.otel
    error_message = "step 7: write/retire must not change client keys"
  }
  assert {
    condition     = (output.versions.otel.b != run.step6.versions.otel.b)
    error_message = "step 7: expected slot b written"
  }
  assert {
    condition     = "b" != run.step6.client.otel && "b" != output.client.otel
    error_message = "step 7: wrote a slot clients use"
  }
  assert {
    condition     = "b" != run.step6.client.otel
    error_message = "step 7: write must target the spare"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step6.versions.otel.a, 0) && output.versions.otel.b >= run.step6.versions.otel.b
    error_message = "step 7: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step6.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step6.external_secret.admin)
    error_message = "step 7: held user untouched"
  }
}

run "step8" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 8, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "b" && output.phase.otel == 2
    error_message = "step 8: client b phase 2"
  }
  assert {
    condition     = !(coalesce(output.versions.otel.a, 0) != coalesce(run.step7.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step7.versions.otel.a == null)) && !(output.versions.otel.b != run.step7.versions.otel.b)
    error_message = "step 8: switch must change no slot version"
  }
  assert {
    condition     = (jsonencode(output.external_secret.otel) != jsonencode(run.step7.external_secret.otel)) && output.client.otel != run.step7.client.otel
    error_message = "step 8: switch must change client keys"
  }
  assert {
    condition     = output.client.otel == "b"
    error_message = "step 8: switch must target the slot written by the previous apply"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step7.versions.otel.a, 0) && output.versions.otel.b >= run.step7.versions.otel.b
    error_message = "step 8: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step7.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step7.external_secret.admin)
    error_message = "step 8: held user untouched"
  }
}

run "step9" {
  command = apply
  variables {
    slot_a_legacy = true
    rotation_step = { otel = 9, admin = 0 }
  }
  assert {
    condition     = output.client.otel == "b" && output.phase.otel == 0
    error_message = "step 9: client b phase 0"
  }
  assert {
    condition     = (((coalesce(output.versions.otel.a, 0) != coalesce(run.step8.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step8.versions.otel.a == null))) ? 1 : 0) + (((output.versions.otel.b != run.step8.versions.otel.b)) ? 1 : 0) == 1
    error_message = "step 9: write/retire must change exactly one slot version"
  }
  assert {
    condition     = !(jsonencode(output.external_secret.otel) != jsonencode(run.step8.external_secret.otel)) && output.client.otel == run.step8.client.otel
    error_message = "step 9: write/retire must not change client keys"
  }
  assert {
    condition     = (coalesce(output.versions.otel.a, 0) != coalesce(run.step8.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.step8.versions.otel.a == null))
    error_message = "step 9: expected slot a written"
  }
  assert {
    condition     = "a" != run.step8.client.otel && "a" != output.client.otel
    error_message = "step 9: wrote a slot clients use"
  }
  assert {
    condition     = "a" == run.step7.client.otel
    error_message = "step 9: retire must rewrite the slot clients left"
  }
  assert {
    condition     = coalesce(output.versions.otel.a, 0) >= coalesce(run.step8.versions.otel.a, 0) && output.versions.otel.b >= run.step8.versions.otel.b
    error_message = "step 9: versions must be monotonic"
  }
  assert {
    condition     = jsonencode(output.versions.admin) == jsonencode(run.step8.versions.admin) && jsonencode(output.external_secret.admin) == jsonencode(run.step8.external_secret.admin)
    error_message = "step 9: held user untouched"
  }
}
