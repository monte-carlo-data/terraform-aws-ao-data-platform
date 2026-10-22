terraform {
  required_version = ">= 1.12"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.50" }
    random = { source = "hashicorp/random", version = "~> 3.7" }
  }
}

# Which prior state a run adopts from, so adoption is exercised as a real state
# transition inside one test file rather than asserted about:
#   "v280" = published 2.x: slot A is a legacy secret_string written from a
#            managed random_password, and there is no slot B
#   "wo13" = slot A is already write-only at version 1, and there is no slot B
#   "ps"   = the two-slot model itself
variable "shape" {
  type    = string
  default = "ps"
}

# Whether slot A still holds a legacy secret_string value. This cannot be derived
# from rotation_step alone: step 0 means "legacy secret_string" on a cell that has
# never rotated, but "write-only version 1" on one already converted. Required with
# no default, because the wrong value silently re-mints a live credential.
variable "slot_a_legacy" {
  type = bool
}

variable "admin_enabled" {
  type    = bool
  default = true
}

# Required per user, with no default: a defaulted step would re-mint a live slot.
variable "rotation_step" {
  type = object({
    otel  = number
    admin = number
  })
  validation {
    condition     = alltrue([for u, s in var.rotation_step : s >= 0 && floor(s) == s])
    error_message = "rotation_step must be a non-negative integer."
  }
}

locals {
  users = merge({ otel = "otel-credentials" }, var.admin_enabled ? { admin = "admin-credentials" } : {})
  ps    = var.shape == "ps"

  s = { for u, _ in local.users : u => var.rotation_step[u] }

  # phase = s mod 3 (1 write, 2 switch, 0 retire/steady). Over a 6-step cycle the
  # two slots alternate: B is written at s mod 6 in {1, 0}, A at {3, 4}.
  writes = { for u, s in local.s : u => {
    a = floor((s + 3) / 6) + floor((s + 2) / 6)
    b = floor((s + 5) / 6) + floor(s / 6)
  } }
  phase = { for u, s in local.s : u => s % 3 }

  # Slot A is legacy until its first write, but only on a cell that started legacy.
  a_legacy = { for u, w in local.writes : u => (
    var.shape == "v280" ? true : var.shape == "wo13" ? false : (var.slot_a_legacy && w.a == 0)
  ) }

  version = { for u, w in local.writes : u => {
    a = local.a_legacy[u] ? null : (var.shape == "wo13" ? 1 : 1 + w.a)
    b = 1 + w.b
  } }

  # Client slot: switches at s mod 3 == 2. a for s mod 6 in {5,0,1}, b for {2,3,4}.
  client = { for u, s in local.s : u => (floor((s + 1) / 3) % 2 == 0 ? "a" : "b") }
}

resource "random_password" "legacy_a" {
  for_each = { for u, l in local.a_legacy : u => l if l }
  length   = 32
  special  = false
}

ephemeral "random_password" "slot" {
  for_each = merge(
    { for u, l in local.a_legacy : "${u}/a" => true if !l },
    local.ps ? { for u, _ in local.users : "${u}/b" => true } : {},
  )
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "a" {
  for_each = local.users
  name     = "cell/clickhouse/${each.value}"
}

resource "aws_secretsmanager_secret_version" "a" {
  for_each                 = local.users
  secret_id                = aws_secretsmanager_secret.a[each.key].id
  secret_string            = local.a_legacy[each.key] ? random_password.legacy_a[each.key].result : null
  secret_string_wo         = local.a_legacy[each.key] ? null : ephemeral.random_password.slot["${each.key}/a"].result
  secret_string_wo_version = local.version[each.key].a
}

resource "aws_secretsmanager_secret" "b" {
  for_each = local.ps ? local.users : {}
  name     = "cell/clickhouse/${replace(each.value, "-credentials", "-credentials-b")}"
}

resource "aws_secretsmanager_secret_version" "b" {
  for_each                 = local.ps ? local.users : {}
  secret_id                = aws_secretsmanager_secret.b[each.key].id
  secret_string_wo         = ephemeral.random_password.slot["${each.key}/b"].result
  secret_string_wo_version = local.version[each.key].b
}

locals {
  name = { for u, slug in local.users : u => {
    a = "cell/clickhouse/${slug}"
    b = "cell/clickhouse/${replace(slug, "-credentials", "-credentials-b")}"
  } }
  # Swap mapping onto chart 5.x: the client slot feeds remoteRef.key ("current")
  # and the other slot feeds previousKey. Single-slot shapes have no previousKey.
  external_secret = { for u, c in local.client : u => merge(
    { remoteRef = { key = local.ps ? local.name[u][c] : local.name[u].a } },
    local.ps ? { previousKey = local.name[u][c == "a" ? "b" : "a"] } : {},
  ) }
}

# Stand-in for helm_release.ao_data_platform. There is deliberately no depends_on
# to the slot versions: because no apply both writes a slot and switches clients
# onto it, that ordering edge is unnecessary. Leaving it out means a test that
# needs the ordering fails here rather than passing by accident.
resource "terraform_data" "helm" {
  input = local.external_secret
}

# A non-secret record of the step, so a plan check can read its before and after
# values directly instead of reverse-engineering the prior step from the slot
# versions and the client key.
resource "terraform_data" "rotation_step" {
  input = local.s
}

output "versions" {
  value = local.version
}
output "phase" {
  value = local.phase
}
output "client" {
  value = local.client
}
output "external_secret" {
  value = local.external_secret
}
output "a_legacy" {
  value = local.a_legacy
}
# Non-secret fingerprint of the managed legacy value, to prove adoption kept it.
output "legacy_digest" {
  value = { for u, r in random_password.legacy_a : u => nonsensitive(sha256(r.result)) }
}
# The secret name downstream consumers must follow; it alternates between slots.
output "client_secret_name" {
  value = { for u, c in local.client : u => local.name[u][c] }
}
