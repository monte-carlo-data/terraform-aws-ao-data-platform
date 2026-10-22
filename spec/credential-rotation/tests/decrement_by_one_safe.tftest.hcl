mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:x" }
  }
}

run "at1" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 1, admin = 0 }
  }
}

run "dec_1_to_0" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 0, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at1.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at1.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at1.versions.otel.a == null)) || (output.versions.otel.b != run.at1.versions.otel.b)))
    error_message = "1->0: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at1.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at1.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at1.versions.otel.b) ? "b" : "none")) != run.at1.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at1.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at1.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at1.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "1->0: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at1.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at1.versions.otel.a == null)) && (output.versions.otel.b != run.at1.versions.otel.b))
    error_message = "1->0: at most one slot written"
  }
}

run "at2" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 2, admin = 0 }
  }
}

run "dec_2_to_1" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 1, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at2.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at2.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at2.versions.otel.a == null)) || (output.versions.otel.b != run.at2.versions.otel.b)))
    error_message = "2->1: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at2.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at2.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at2.versions.otel.b) ? "b" : "none")) != run.at2.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at2.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at2.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at2.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "2->1: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at2.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at2.versions.otel.a == null)) && (output.versions.otel.b != run.at2.versions.otel.b))
    error_message = "2->1: at most one slot written"
  }
}

run "at3" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 3, admin = 0 }
  }
}

run "dec_3_to_2" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 2, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at3.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at3.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at3.versions.otel.a == null)) || (output.versions.otel.b != run.at3.versions.otel.b)))
    error_message = "3->2: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at3.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at3.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at3.versions.otel.b) ? "b" : "none")) != run.at3.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at3.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at3.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at3.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "3->2: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at3.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at3.versions.otel.a == null)) && (output.versions.otel.b != run.at3.versions.otel.b))
    error_message = "3->2: at most one slot written"
  }
}

run "at4" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 4, admin = 0 }
  }
}

run "dec_4_to_3" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 3, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at4.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at4.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at4.versions.otel.a == null)) || (output.versions.otel.b != run.at4.versions.otel.b)))
    error_message = "4->3: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at4.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at4.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at4.versions.otel.b) ? "b" : "none")) != run.at4.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at4.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at4.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at4.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "4->3: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at4.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at4.versions.otel.a == null)) && (output.versions.otel.b != run.at4.versions.otel.b))
    error_message = "4->3: at most one slot written"
  }
}

run "at5" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 5, admin = 0 }
  }
}

run "dec_5_to_4" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 4, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at5.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at5.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at5.versions.otel.a == null)) || (output.versions.otel.b != run.at5.versions.otel.b)))
    error_message = "5->4: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at5.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at5.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at5.versions.otel.b) ? "b" : "none")) != run.at5.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at5.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at5.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at5.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "5->4: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at5.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at5.versions.otel.a == null)) && (output.versions.otel.b != run.at5.versions.otel.b))
    error_message = "5->4: at most one slot written"
  }
}

run "at6" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 6, admin = 0 }
  }
}

run "dec_6_to_5" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 5, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at6.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at6.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at6.versions.otel.a == null)) || (output.versions.otel.b != run.at6.versions.otel.b)))
    error_message = "6->5: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at6.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at6.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at6.versions.otel.b) ? "b" : "none")) != run.at6.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at6.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at6.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at6.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "6->5: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at6.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at6.versions.otel.a == null)) && (output.versions.otel.b != run.at6.versions.otel.b))
    error_message = "6->5: at most one slot written"
  }
}

run "at7" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 7, admin = 0 }
  }
}

run "dec_7_to_6" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 6, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at7.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at7.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at7.versions.otel.a == null)) || (output.versions.otel.b != run.at7.versions.otel.b)))
    error_message = "7->6: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at7.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at7.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at7.versions.otel.b) ? "b" : "none")) != run.at7.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at7.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at7.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at7.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "7->6: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at7.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at7.versions.otel.a == null)) && (output.versions.otel.b != run.at7.versions.otel.b))
    error_message = "7->6: at most one slot written"
  }
}

run "at8" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 8, admin = 0 }
  }
}

run "dec_8_to_7" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 7, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at8.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at8.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at8.versions.otel.a == null)) || (output.versions.otel.b != run.at8.versions.otel.b)))
    error_message = "8->7: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at8.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at8.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at8.versions.otel.b) ? "b" : "none")) != run.at8.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at8.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at8.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at8.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "8->7: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at8.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at8.versions.otel.a == null)) && (output.versions.otel.b != run.at8.versions.otel.b))
    error_message = "8->7: at most one slot written"
  }
}

run "at9" {
  command = apply
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 9, admin = 0 }
  }
}

run "dec_9_to_8" {
  command = plan
  variables {
    slot_a_legacy = false
    rotation_step = { otel = 8, admin = 0 }
  }
  assert {
    condition     = !((jsonencode(output.external_secret.otel) != jsonencode(run.at9.external_secret.otel)) && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at9.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at9.versions.otel.a == null)) || (output.versions.otel.b != run.at9.versions.otel.b)))
    error_message = "9->8: never writes and switches together"
  }
  assert {
    condition     = ((coalesce(output.versions.otel.a, 0) != coalesce(run.at9.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at9.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at9.versions.otel.b) ? "b" : "none")) != run.at9.client.otel && ((coalesce(output.versions.otel.a, 0) != coalesce(run.at9.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at9.versions.otel.a == null)) ? "a" : ((output.versions.otel.b != run.at9.versions.otel.b) ? "b" : "none")) != output.client.otel
    error_message = "9->8: never writes a slot clients use (before or after)"
  }
  assert {
    condition     = !((coalesce(output.versions.otel.a, 0) != coalesce(run.at9.versions.otel.a, 0) || (output.versions.otel.a == null) != (run.at9.versions.otel.a == null)) && (output.versions.otel.b != run.at9.versions.otel.b))
    error_message = "9->8: at most one slot written"
  }
}
