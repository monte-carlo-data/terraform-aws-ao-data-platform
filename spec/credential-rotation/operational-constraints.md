# Operational constraints

The model in this directory pins the rotation *arithmetic*. It cannot express the two
things that make a rotation safe in practice: that the server has loaded a new password
before clients are pointed at it, and that moving clients onto it does not drop data.

This file records what was measured about both, so the guard work is designed against
observed behaviour rather than assumption. Every claim below was verified; where a claim
is scoped to the conditions tested, that is stated.

## Applying a new password

Verified against `clickhouse-server:26.4.3` (build `26.4.3.37`) — the version this chart
pins — in a throwaway container running that exact image.

ClickHouse watches its own users-config directory. A changed users file is picked up with
no explicit reload: **measured ~1.3 s** from file write to the change being visible in
`system.users`. An explicit `SYSTEM RELOAD CONFIG` applies the same change in **~0.2 s**,
most of which is client round-trip.

Two consequences:

- **The reload is not a capability we otherwise lack.** The change lands either way.
- **It is a latency and verifiability guarantee, and that is why the scheme needs it.**
  In the deployed path the users file arrives as a mounted Secret, so the propagation
  delay is the kubelet sync interval (tens of seconds) *plus* the watcher, and neither is
  observable from the apply. A gate that must confirm a password is live *before* clients
  are switched cannot be built on "the watcher probably fired by now". It needs a reload
  it can issue and a probe it can read.

## A reload-only user is sufficient and safe

`SYSTEM RELOAD CONFIG` is a real grantable privilege at `GLOBAL` scope (alias
`RELOAD CONFIG`, parent group `SYSTEM RELOAD`). Granted on its own, it confers nothing
else. Measured capability matrix for a user holding only that grant:

| Operation | Result |
|---|---|
| `SYSTEM RELOAD CONFIG` | allowed |
| `SELECT` from a data table | denied |
| `SHOW DATABASES`, `SHOW TABLES`, `system.tables` | allowed, but returns **0 rows** — grant-filtered |
| `system.query_log` | denied |
| `system.users`, `SHOW CREATE USER` | denied |
| `CREATE USER`, `CREATE TABLE` | denied |
| `GRANT` further privileges to itself | denied |
| other `SYSTEM` operations (e.g. `DROP MARK CACHE`) | denied |

No data, no schema metadata, no credential metadata, no escalation path.

Three details worth not rediscovering:

- **`SYSTEM RELOAD CONFIG` and `SYSTEM RELOAD USERS` are independent grants.** A user
  holding one is denied the other. Both apply a users-config change, so the single
  `SYSTEM RELOAD CONFIG` grant is enough; there is no need to grant both.
- **A `readonly` profile defeats the grant.** A user with `readonly=1` is denied
  `SYSTEM RELOAD CONFIG` with `Code: 164` *even while holding it*. A reload user must be
  a dedicated user with no readonly profile — in particular, the grant cannot simply be
  bolted onto the existing `readonly_user`, which is the obvious shortcut.
  (Tested at `readonly=1`. This chart uses `readonly=2` elsewhere; that case was not
  tested, and does not change the guidance, since the reload user carries no readonly
  profile either way.)
- **This is an established pattern in this chart, not a new one.** `schema_owner`
  already holds granular `SYSTEM` sub-privileges, and `readonly_user` is already a
  narrow, grant-scoped, non-admin user with its own profile and auth methods. A
  reload-only user is the same shape with a different grant.

## Moving clients does not cost an ingest gap

The collector runs as a Deployment at `replicaCount: 1`. The subchart ships
`rollout.strategy: RollingUpdate` with `rollingUpdate: {}` — the surge and unavailability
keys are commented out — and this chart overrides neither. Kubernetes defaults therefore
apply: `maxSurge` 25% rounds **up** to 1, `maxUnavailable` 25% rounds **down** to 0.

So a credential change rolls the collector surge-first: the replacement pod starts and
becomes Ready before the old pod is terminated. There is no window with zero collectors.

This also fails safe. A pod that cannot authenticate never passes its readiness probe, so
the old pod is never retired — ingest continues on the working credential and the rollout
stalls visibly instead of silently cutting ingest.

**What "no gap" does not cover.** The collector has no `preStop` hook, its `sending_queue`
is in-memory (`queue_size: 1000`, `extensions: [health_check]` only — no `file_storage`),
and there is no PodDisruptionBudget. Items buffered in a terminating pod are lost. Rotation
does not make this worse — a surge-first roll is the gentlest case — but "rotation causes no
ingest gap" is a claim about *ingest continuity*, not about zero in-flight loss. Durable
queueing is a separate concern from credential rotation and is not addressed by this scheme.
