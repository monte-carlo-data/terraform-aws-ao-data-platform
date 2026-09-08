# ClickHouse Passwords — generated when not caller-supplied; stored in Secrets
# Manager and synced into the cluster by ESO (never passed through Helm values).
#
# TWO PATHS, selected per deployment by var.clickhouse_write_only: legacy (flag
# false, the default) uses managed `random_password` generators and
# `secret_string` — passwords are in Terraform state; write-only (flag true)
# uses ephemeral generators and `secret_string_wo` + `secret_string_wo_version`
# — no password reaches state or plan files (YET-2514). The flag's fleet
# rationale and the re-mint/no-op behavior: variables.tf and README "Upgrading
# to v3.0.0".
#
# Every sink declares BOTH secret_string and secret_string_wo, with exactly one
# non-null (the provider's mutual exclusion accepts an explicit null, so this
# validates). Declaring both is what makes the opt-in an in-place update of the
# existing secret version (- secret_string -> null, + secret_string_wo_version
# = 1) rather than a destroy/create, which would leave a window where ESO cannot
# fetch the secret.
#
# The *_wo locals are ephemeral: legal in write-only arguments, provider config,
# other ephemeral resources, ephemeral outputs and provisioners — never anywhere
# that would persist them. That invariant is enforced by the language.

locals {
  # Two locals per user — one per path — each already null on the path it does
  # not serve, so every sink can wire both unconditionally. Caller-supplied
  # password wins; otherwise the generated one. Three load-bearing details:
  #
  #   - The paths deliberately disagree on what "" means: legacy tests `!= null`
  #     (byte-for-byte v2.4.2), so a supplied "" writes an empty secret;
  #     write-only uses coalesce, so "" generates instead. See the gate comment
  #     below and legacy_empty_string_password_writes_empty_secret.
  #   - Every local reads its generator through `one(<generator>[*].result)`,
  #     never `[0]`, because the inactive path leaves its generator at count 0
  #     and a bare [0] index on an empty list is an error. For the legacy locals
  #     this makes them safe outright: `one()` of an empty list is null, and the
  #     ternary then yields null rather than failing.
  #   - Each coalesce is wrapped in the path conditional rather than the other
  #     way round, because coalesce errors when every argument is null.
  #
  # The write-only locals are the one place that still depends on evaluation
  # order: with the flag false, `coalesce(null, one(<empty>))` would error, so
  # what keeps it alive is the path conditional short-circuiting — `one()` would
  # only change the error message, not prevent it. Terraform short-circuits a
  # conditional whose predicate is KNOWN, which var.clickhouse_write_only is
  # because it is a literal bool in a deployment's config.
  #
  # Keep it that way: if the flag is ever wired to something unknown at plan
  # time (a data source, a resource attribute), both branches get evaluated and
  # the write-only locals fail — `one()` is not protection against that. The
  # same known-ness requirement covers the two *_enabled locals (main.tf) that
  # the gated write-only locals also predicate on.
  #
  # On the write-only path the outer `var.clickhouse_write_only ? 0 :` count
  # gate is the ONLY defence keeping a managed generator's plaintext `result`
  # out of state — the validation forces every var.clickhouse_passwords field
  # null there, so the inner `== null` check would evaluate TRUE and CREATE a
  # generator. It is not a second line of defence.
  clickhouse_otel_password_legacy = var.clickhouse_write_only ? null : (
    var.clickhouse_passwords.otel != null ? var.clickhouse_passwords.otel : one(random_password.clickhouse_otel[*].result)
  )
  clickhouse_otel_password_wo = var.clickhouse_write_only ? coalesce(
    var.clickhouse_passwords_wo.otel, one(ephemeral.random_password.clickhouse_otel[*].result)
  ) : null

  clickhouse_monte_carlo_password_legacy = var.clickhouse_write_only ? null : (
    var.clickhouse_passwords.monte_carlo != null ? var.clickhouse_passwords.monte_carlo : one(random_password.clickhouse_monte_carlo[*].result)
  )
  clickhouse_monte_carlo_password_wo = var.clickhouse_write_only ? coalesce(
    var.clickhouse_passwords_wo.monte_carlo, one(ephemeral.random_password.clickhouse_monte_carlo[*].result)
  ) : null

  clickhouse_schema_owner_password_legacy = var.clickhouse_write_only ? null : (
    var.clickhouse_passwords.schema_owner != null ? var.clickhouse_passwords.schema_owner : one(random_password.clickhouse_schema_owner[*].result)
  )
  clickhouse_schema_owner_password_wo = var.clickhouse_write_only ? coalesce(
    var.clickhouse_passwords_wo.schema_owner, one(ephemeral.random_password.clickhouse_schema_owner[*].result)
  ) : null

  clickhouse_llm_worker_password_legacy = var.clickhouse_write_only ? null : (
    var.clickhouse_passwords.llm_worker != null ? var.clickhouse_passwords.llm_worker : one(random_password.clickhouse_llm_worker[*].result)
  )
  clickhouse_llm_worker_password_wo = var.clickhouse_write_only ? coalesce(
    var.clickhouse_passwords_wo.llm_worker, one(ephemeral.random_password.clickhouse_llm_worker[*].result)
  ) : null

  # admin and readonly_user carry their enabled flag in both locals, so both
  # stay null when the user is disabled (its sink does not exist at all).
  clickhouse_admin_password_legacy = !var.clickhouse_write_only && local.clickhouse_admin_enabled ? (
    var.clickhouse_passwords.admin != null ? var.clickhouse_passwords.admin : one(random_password.clickhouse_admin[*].result)
  ) : null
  clickhouse_admin_password_wo = var.clickhouse_write_only && local.clickhouse_admin_enabled ? coalesce(
    var.clickhouse_passwords_wo.admin, one(ephemeral.random_password.clickhouse_admin[*].result)
  ) : null

  clickhouse_readonly_user_password_legacy = !var.clickhouse_write_only && local.clickhouse_readonly_user_enabled ? (
    var.clickhouse_passwords.readonly_user != null ? var.clickhouse_passwords.readonly_user : one(random_password.clickhouse_readonly_user[*].result)
  ) : null
  clickhouse_readonly_user_password_wo = var.clickhouse_write_only && local.clickhouse_readonly_user_enabled ? coalesce(
    var.clickhouse_passwords_wo.readonly_user, one(ephemeral.random_password.clickhouse_readonly_user[*].result)
  ) : null

  # Previous-password locals — the overlap value. Unlike the current-password
  # locals there is no generator to fall back on: an unsupplied previous password
  # means "no overlap", which is the steady state, so the fallback is the sentinel
  # "-" rather than a generated value. Secrets Manager rejects empty strings
  # (Spike Finding 10), and the ESO template's guard (ne .<user>_previous "-")
  # treats the sentinel as absent, rendering single-method auth. The sentinel can
  # never collide with a real password: generated passwords are 32 chars,
  # alphanumeric only.
  #
  # The explicit ternary (rather than coalesce) mirrors the current-password
  # locals' shape so the pairs read identically.
  clickhouse_otel_previous_password_legacy = var.clickhouse_write_only ? null : (
    var.clickhouse_previous_passwords.otel != null ? var.clickhouse_previous_passwords.otel : "-"
  )
  clickhouse_otel_previous_password_wo = var.clickhouse_write_only ? (
    var.clickhouse_previous_passwords_wo.otel != null ? var.clickhouse_previous_passwords_wo.otel : "-"
  ) : null

  clickhouse_monte_carlo_previous_password_legacy = var.clickhouse_write_only ? null : (
    var.clickhouse_previous_passwords.monte_carlo != null ? var.clickhouse_previous_passwords.monte_carlo : "-"
  )
  clickhouse_monte_carlo_previous_password_wo = var.clickhouse_write_only ? (
    var.clickhouse_previous_passwords_wo.monte_carlo != null ? var.clickhouse_previous_passwords_wo.monte_carlo : "-"
  ) : null

  clickhouse_schema_owner_previous_password_legacy = var.clickhouse_write_only ? null : (
    var.clickhouse_previous_passwords.schema_owner != null ? var.clickhouse_previous_passwords.schema_owner : "-"
  )
  clickhouse_schema_owner_previous_password_wo = var.clickhouse_write_only ? (
    var.clickhouse_previous_passwords_wo.schema_owner != null ? var.clickhouse_previous_passwords_wo.schema_owner : "-"
  ) : null

  clickhouse_llm_worker_previous_password_legacy = var.clickhouse_write_only ? null : (
    var.clickhouse_previous_passwords.llm_worker != null ? var.clickhouse_previous_passwords.llm_worker : "-"
  )
  clickhouse_llm_worker_previous_password_wo = var.clickhouse_write_only ? (
    var.clickhouse_previous_passwords_wo.llm_worker != null ? var.clickhouse_previous_passwords_wo.llm_worker : "-"
  ) : null

  # admin and readonly_user carry their enabled flag in both locals, so both
  # stay null when the user is disabled (its sink does not exist at all) —
  # same shape as the current-password locals above.
  clickhouse_admin_previous_password_legacy = !var.clickhouse_write_only && local.clickhouse_admin_enabled ? (
    var.clickhouse_previous_passwords.admin != null ? var.clickhouse_previous_passwords.admin : "-"
  ) : null
  clickhouse_admin_previous_password_wo = var.clickhouse_write_only && local.clickhouse_admin_enabled ? (
    var.clickhouse_previous_passwords_wo.admin != null ? var.clickhouse_previous_passwords_wo.admin : "-"
  ) : null

  clickhouse_readonly_user_previous_password_legacy = !var.clickhouse_write_only && local.clickhouse_readonly_user_enabled ? (
    var.clickhouse_previous_passwords.readonly_user != null ? var.clickhouse_previous_passwords.readonly_user : "-"
  ) : null
  clickhouse_readonly_user_previous_password_wo = var.clickhouse_write_only && local.clickhouse_readonly_user_enabled ? (
    var.clickhouse_previous_passwords_wo.readonly_user != null ? var.clickhouse_previous_passwords_wo.readonly_user : "-"
  ) : null
}

# Generators, legacy path — managed resources whose `result` is in state. count
# cannot derive from a sensitive value, so the checks are unwrapped with
# nonsensitive(); this declassifies only whether a password was supplied, never
# the password itself. Legal because var.clickhouse_passwords is not ephemeral.
#
# The gate keys off `== null` alone, matching v2.4.2 exactly and matching the
# `!= null` ternary in the legacy locals above: an empty string counts as
# supplied, so no generator is created and "" is written through as the secret
# value — same as before v3.0.0. The gate and the local must agree on what ""
# means, and either mutation alone breaks differently: widening the gate alone
# to `|| == ""` creates a stray generator whose plaintext `result` sits in
# state for nothing; switching the local to `coalesce` alone makes
# `coalesce("", null)` a hard plan error. See
# legacy_empty_string_password_writes_empty_secret.
#
# A deployment that opts in drops these to count = 0, which destroys its own
# generator instances naturally (random_password is a logical resource, so
# there is nothing to destroy in AWS). No `removed` block: that would
# force-forget the generators of every deployment still legitimately on the
# legacy path.

resource "random_password" "clickhouse_admin" {
  count = var.clickhouse_write_only ? 0 : (
    local.clickhouse_admin_enabled && nonsensitive(var.clickhouse_passwords.admin == null) ? 1 : 0
  )
  length  = 32
  special = false
}

resource "random_password" "clickhouse_otel" {
  count = var.clickhouse_write_only ? 0 : (
    nonsensitive(var.clickhouse_passwords.otel == null) ? 1 : 0
  )
  length  = 32
  special = false
}

resource "random_password" "clickhouse_monte_carlo" {
  count = var.clickhouse_write_only ? 0 : (
    nonsensitive(var.clickhouse_passwords.monte_carlo == null) ? 1 : 0
  )
  length  = 32
  special = false
}

resource "random_password" "clickhouse_schema_owner" {
  count = var.clickhouse_write_only ? 0 : (
    nonsensitive(var.clickhouse_passwords.schema_owner == null) ? 1 : 0
  )
  length  = 32
  special = false
}

resource "random_password" "clickhouse_llm_worker" {
  count = var.clickhouse_write_only ? 0 : (
    nonsensitive(var.clickhouse_passwords.llm_worker == null) ? 1 : 0
  )
  length  = 32
  special = false
}

resource "random_password" "clickhouse_readonly_user" {
  count = var.clickhouse_write_only ? 0 : (
    local.clickhouse_readonly_user_enabled && nonsensitive(var.clickhouse_passwords.readonly_user == null) ? 1 : 0
  )
  length  = 32
  special = false
}

# Generators, write-only path — `ephemeral`, so the generated value has no
# state and no plan representation. Gated on the opt-in flag (and, for the two
# gated users, on their enabled flag) so the intent of each instance is
# explicit; there is no caller-supplied-password gate because an ephemeral
# value may not drive count, and an unused ephemeral resource costs nothing.

ephemeral "random_password" "clickhouse_otel" {
  count   = var.clickhouse_write_only ? 1 : 0
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_monte_carlo" {
  count   = var.clickhouse_write_only ? 1 : 0
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_schema_owner" {
  count   = var.clickhouse_write_only ? 1 : 0
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_llm_worker" {
  count   = var.clickhouse_write_only ? 1 : 0
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_admin" {
  count   = var.clickhouse_write_only && local.clickhouse_admin_enabled ? 1 : 0
  length  = 32
  special = false
}

ephemeral "random_password" "clickhouse_readonly_user" {
  count   = var.clickhouse_write_only && local.clickhouse_readonly_user_enabled ? 1 : 0
  length  = 32
  special = false
}

# KMS — customer-managed key for all Secrets Manager secrets.

resource "aws_kms_key" "pipeline_secrets" {
  description             = "${local.effective_cluster_name} pipeline secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "pipeline_secrets" {
  name          = "alias/${local.effective_cluster_name}-pipeline-secrets"
  target_key_id = aws_kms_key.pipeline_secrets.key_id
}

# Secrets Manager — ClickHouse passwords (otel, monte_carlo, schema_owner,
# llm_worker users always provisioned; admin and readonly_user conditional on
# their respective enabled flags).
#
# Each version resource wires both password arguments plus the write-only
# version companion. secret_string_wo_version is null on the legacy path: it is
# only meaningful alongside a write-only write, and leaving it unset there is
# what keeps v3.0.0 inert for a deployment that has not opted in.

# admin and admin_password versions were unconditional before the gated
# break-glass admin user existed. The moved blocks let enabling admin adopt the
# existing secret in place rather than destroy/recreate it.
moved {
  from = aws_secretsmanager_secret.clickhouse_admin_password
  to   = aws_secretsmanager_secret.clickhouse_admin_password[0]
}

moved {
  from = aws_secretsmanager_secret_version.clickhouse_admin_password
  to   = aws_secretsmanager_secret_version.clickhouse_admin_password[0]
}

resource "aws_secretsmanager_secret" "clickhouse_admin_password" {
  count                   = local.clickhouse_admin_enabled ? 1 : 0
  name                    = "${local.effective_cluster_name}/clickhouse/admin-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # Allow immediate deletion so destroy + re-apply with the same cluster name doesn't fail during the default 30-day recovery window.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_admin_password" {
  count                    = local.clickhouse_admin_enabled ? 1 : 0
  secret_id                = aws_secretsmanager_secret.clickhouse_admin_password[0].id
  secret_string            = local.clickhouse_admin_password_legacy
  secret_string_wo         = local.clickhouse_admin_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.admin : null

  # The overlap password must land before the current one moves — see the
  # ordering note above the previous-password secrets.
  depends_on = [aws_secretsmanager_secret_version.clickhouse_admin_previous_password]
}

resource "aws_secretsmanager_secret" "clickhouse_otel_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/otel-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_otel_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_otel_password.id
  secret_string            = local.clickhouse_otel_password_legacy
  secret_string_wo         = local.clickhouse_otel_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.otel : null

  # The overlap password must land before the current one moves — see the
  # ordering note above the previous-password secrets.
  depends_on = [aws_secretsmanager_secret_version.clickhouse_otel_previous_password]
}

resource "aws_secretsmanager_secret" "clickhouse_monte_carlo_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/monte-carlo-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_monte_carlo_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_monte_carlo_password.id
  secret_string            = local.clickhouse_monte_carlo_password_legacy
  secret_string_wo         = local.clickhouse_monte_carlo_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.monte_carlo : null

  # The overlap password must land before the current one moves — see the
  # ordering note above the previous-password secrets.
  depends_on = [aws_secretsmanager_secret_version.clickhouse_monte_carlo_previous_password]
}

resource "aws_secretsmanager_secret" "clickhouse_schema_owner_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/schema-owner-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_schema_owner_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_schema_owner_password.id
  secret_string            = local.clickhouse_schema_owner_password_legacy
  secret_string_wo         = local.clickhouse_schema_owner_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.schema_owner : null

  # The overlap password must land before the current one moves — see the
  # ordering note above the previous-password secrets.
  depends_on = [aws_secretsmanager_secret_version.clickhouse_schema_owner_previous_password]
}

resource "aws_secretsmanager_secret" "clickhouse_llm_worker_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/llm-worker-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_llm_worker_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_llm_worker_password.id
  secret_string            = local.clickhouse_llm_worker_password_legacy
  secret_string_wo         = local.clickhouse_llm_worker_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.llm_worker : null

  # The overlap password must land before the current one moves — see the
  # ordering note above the previous-password secrets.
  depends_on = [aws_secretsmanager_secret_version.clickhouse_llm_worker_previous_password]
}

resource "aws_secretsmanager_secret" "clickhouse_readonly_user_password" {
  count                   = local.clickhouse_readonly_user_enabled ? 1 : 0
  name                    = "${local.effective_cluster_name}/clickhouse/readonly-user-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_readonly_user_password" {
  count                    = local.clickhouse_readonly_user_enabled ? 1 : 0
  secret_id                = aws_secretsmanager_secret.clickhouse_readonly_user_password[0].id
  secret_string            = local.clickhouse_readonly_user_password_legacy
  secret_string_wo         = local.clickhouse_readonly_user_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.readonly_user : null

  # The overlap password must land before the current one moves — see the
  # ordering note above the previous-password secrets.
  depends_on = [aws_secretsmanager_secret_version.clickhouse_readonly_user_previous_password]
}

# Secrets Manager — the PREVIOUS ClickHouse password per user (YET-2680).
#
# Holds the sentinel "-" in steady state (ESO renders it as absent —
# single-method auth); holds the outgoing password for the duration of a
# rotation so the server accepts both. Created for every enabled user so a
# rotation never creates a secret mid-flight — ESO tolerates a value change, not
# a missing secret. Gating mirrors the current-password secrets exactly.
#
# Ordering is the one correctness property here: each CURRENT sink depends_on its
# PREVIOUS sink, so the old password is in Secrets Manager before the current one
# moves. The bad interleave — current rotated, previous not yet written — is the
# one that locks out every existing client, and this dependency is what excludes
# it. ESO renders both into one file on its next sync, so the server sees a
# single transition straight from one method to two.

resource "aws_secretsmanager_secret" "clickhouse_admin_previous_password" {
  count                   = local.clickhouse_admin_enabled ? 1 : 0
  name                    = "${local.effective_cluster_name}/clickhouse/admin-previous-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_admin_previous_password" {
  count                    = local.clickhouse_admin_enabled ? 1 : 0
  secret_id                = aws_secretsmanager_secret.clickhouse_admin_previous_password[0].id
  secret_string            = local.clickhouse_admin_previous_password_legacy
  secret_string_wo         = local.clickhouse_admin_previous_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.admin : null
}

resource "aws_secretsmanager_secret" "clickhouse_otel_previous_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/otel-previous-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_otel_previous_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_otel_previous_password.id
  secret_string            = local.clickhouse_otel_previous_password_legacy
  secret_string_wo         = local.clickhouse_otel_previous_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.otel : null
}

resource "aws_secretsmanager_secret" "clickhouse_monte_carlo_previous_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/monte-carlo-previous-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_monte_carlo_previous_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_monte_carlo_previous_password.id
  secret_string            = local.clickhouse_monte_carlo_previous_password_legacy
  secret_string_wo         = local.clickhouse_monte_carlo_previous_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.monte_carlo : null
}

resource "aws_secretsmanager_secret" "clickhouse_schema_owner_previous_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/schema-owner-previous-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_schema_owner_previous_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_schema_owner_previous_password.id
  secret_string            = local.clickhouse_schema_owner_previous_password_legacy
  secret_string_wo         = local.clickhouse_schema_owner_previous_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.schema_owner : null
}

resource "aws_secretsmanager_secret" "clickhouse_llm_worker_previous_password" {
  name                    = "${local.effective_cluster_name}/clickhouse/llm-worker-previous-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_llm_worker_previous_password" {
  secret_id                = aws_secretsmanager_secret.clickhouse_llm_worker_previous_password.id
  secret_string            = local.clickhouse_llm_worker_previous_password_legacy
  secret_string_wo         = local.clickhouse_llm_worker_previous_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.llm_worker : null
}

resource "aws_secretsmanager_secret" "clickhouse_readonly_user_previous_password" {
  count                   = local.clickhouse_readonly_user_enabled ? 1 : 0
  name                    = "${local.effective_cluster_name}/clickhouse/readonly-user-previous-credentials"
  kms_key_id              = aws_kms_key.pipeline_secrets.arn
  recovery_window_in_days = 0 # See clickhouse_admin_password above.
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_readonly_user_previous_password" {
  count                    = local.clickhouse_readonly_user_enabled ? 1 : 0
  secret_id                = aws_secretsmanager_secret.clickhouse_readonly_user_previous_password[0].id
  secret_string            = local.clickhouse_readonly_user_previous_password_legacy
  secret_string_wo         = local.clickhouse_readonly_user_previous_password_wo
  secret_string_wo_version = var.clickhouse_write_only ? var.clickhouse_password_versions.readonly_user : null
}
