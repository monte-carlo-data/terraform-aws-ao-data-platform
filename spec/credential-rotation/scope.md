# Scope: what this scheme covers, and what it does not

The two-slot scheme has a narrow job: rotate ClickHouse user credentials without a client
outage, and make the password that was previously readable in Terraform state actually
revoked rather than merely superseded.

It is worth being explicit about the edges, because the scheme is easy to mistake for a
complete answer to "no ClickHouse secrets in Terraform state". It is not one on its own.

## Closed by the arithmetic

These hold by construction and are pinned by the test suites in `tests/`:

- No slot ever holds a placeholder or sentinel value. Both slots always carry real
  passwords, so there is no apply during which a client could be handed a non-credential.
- Clients are never pointed at a password the server has not loaded. This is the
  single-change invariant: an apply either writes an unused slot or switches clients,
  never both.
- Rotation does not require a client-visible outage.
- Adoption is inert. Existing cells take the new scheme at `rotation_step = 0` without
  rotating anything.
- The legacy state-readable value is genuinely retired, at step 3 of the first rotation.
  The first rotation *is* the migration.
- Rotation is driven by one declared integer per user, not by hand-editing secrets, so the
  intended state is reviewable in a diff.

## Closed only once the operational guards exist

The arithmetic makes these *possible* to enforce; nothing enforces them yet. A release
without them is a scheme that is correct on paper and unguarded in practice:

- **Counter mis-set.** A jump of two or more, a reset to zero, or an unintended decrement
  can rewrite a slot clients are actively using. The `hazards_counter` suite asserts that
  this happens — it documents the exposure rather than fixing it. Terraform validation
  cannot catch it, because a step delta is only visible by comparing against prior state;
  it needs a plan-time check.
- **Confirming the server loaded a new password** before clients are switched to it.
- **Confirming clients actually moved** before the old password is retired.
- **Detecting secret-sync failure**, so a silently stale slot surfaces as an alert rather
  than as a failed authentication later.

These are tracked as our work, not the chart's.

## Not addressed

- **Backup credentials.** They are a separate credential path and this scheme does not
  touch them. This is the significant gap: a release containing only this work would
  *not* remove every ClickHouse secret from Terraform state, so it does not by itself
  satisfy the broader goal it is often described as serving. Whether to bring them into
  the same release is a scoping decision, not a technical constraint — the design
  accommodates either choice.
- **Components outside this repository**, including the chart changes this scheme depends
  on, which are versioned separately.
- **Guidance for saved plan files**, which may contain values that the state no longer
  does.
- **Verification against real AWS.** The model mocks the provider, so it proves the
  arithmetic and nothing about live secret creation, IAM, or sync behaviour. Standing up a
  throwaway cell from `examples/new_cluster` is the intended way to close this before a
  release is tagged; a long-lived cell that has already adopted the scheme cannot exercise
  the legacy-adoption path.

## Why this file exists

Each item above was established by reading the code or measuring behaviour, and would
otherwise have to be rediscovered. The "not addressed" list in particular is the record
that the scheme's headline framing overstates its coverage — keep it accurate as scope
changes.
