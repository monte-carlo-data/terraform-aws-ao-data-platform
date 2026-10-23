# Credential rotation model

An executable model of the two-slot ClickHouse credential rotation scheme. It is a
standalone Terraform root, deliberately **not** part of the module: it exists to pin
the rotation arithmetic and its hazards as runnable tests before, and independently
of, the module implementation.

Run it with:

    make test-rotation-model

Two companion documents cover what the model deliberately leaves out:
[`operational-constraints.md`](operational-constraints.md) for the server- and
client-side behaviour it cannot express, and [`scope.md`](scope.md) for what the scheme
does and does not cover.

## The scheme

Every ClickHouse user has two permanent secrets — slot A (`<user>-credentials`) and
slot B (`<user>-credentials-b`). Both always hold real random passwords and both are
always accepted by the server, via the chart's current + previous auth methods. There
is no placeholder value in either slot at any time.

Rotation is driven by one required integer per user, `rotation_step`, incremented by
exactly one per apply. Everything else is derived from it:

| derived value | formula |
|---|---|
| phase | `s mod 3` — 1 write, 2 switch, 0 retire/steady |
| client slot | `floor((s + 1) / 3) % 2 == 0 ? "a" : "b"` |
| slot A writes | `floor((s + 3) / 6) + floor((s + 2) / 6)` |
| slot B writes | `floor((s + 5) / 6) + floor(s / 6)` |
| slot version | `1 + <that slot's write count>` |

One rotation is three steps; the slots trade places over six:

| s | phase | the apply | clients | A | B |
|---|---|---|---|---|---|
| 0 | steady | — | A | 1 | 1 |
| 1 | write | fresh password into the spare, B | A | 1 | 2 |
| 2 | switch | chart keys swap, clients move to B | B | 1 | 2 |
| 3 | retire | fresh password into A; the old value dies | B | 2 | 2 |
| 4 | write | fresh password into A, now the spare | B | 3 | 2 |
| 5 | switch | clients move back to A | A | 3 | 2 |
| 6 | retire | fresh password into B | A | 3 | 3 |

**The invariant the whole scheme rests on:** an apply either writes a slot no client
uses, or switches clients — never both. That is what keeps clients from ever being
handed a password the server has not loaded yet, and it is why a rotation costs three
applies rather than two.

Adoption is inert. Setting `rotation_step = 0` for every user creates the B secrets as
spares and changes nothing a client reads. A cell that has never rotated keeps its
legacy `secret_string` in slot A until step 3, so **the first rotation is also the
migration** — that is the apply that revokes the value which was previously readable
in state.

## What the tests cover

| File | Runs | What it pins |
|---|---|---|
| `walk_fresh` | 10 | Steps 0–9 from a fresh install: writes and retires change exactly one slot version and no client key; switches change the client key and no version; versions only increase; no apply ever writes the slot clients are using, before or after it |
| `walk_legacy` | 11 | The same walk starting from a published-2.x state, plus the migration: slot A keeps its legacy value through steps 1 and 2, and at step 3 becomes write-only while the managed generator is destroyed |
| `adopt_legacy_flag` | 5 | Inert adoption, and the hazard where the wrong flag re-mints a live slot A |
| `adopt_legacy_wrong_flag` | 4 | A cell adopting with the inverted flag, including a flip mid-rotation |
| `hazards_counter` | 17 | What a mis-set counter actually does: `+2` and `+3` jumps, a reset to 0, and a decrement — several of which rewrite a slot clients are using |
| `decrement_by_one_safe` | 18 | The one counter mistake that is recoverable: stepping back by exactly one never rewrites a slot clients just moved onto |

The hazard suites assert that the bad thing *happens*. They are not aspirational — they
document why the counter needs a plan-time guard that no Terraform validation can
express, because a step delta is only visible by comparing against prior state.

## Deliberate limits

- **Two users** (`otel`, `admin`), not the full set. The arithmetic is per-user and
  identical for each; two is enough to prove that one user's step does not disturb
  another's, and keeps the state walks tractable.
- **`terraform_data` stands in for `helm_release`.** The model pins which keys change
  in which apply, not how the chart renders them.
- **Mocked AWS provider, real `random` provider.** No AWS calls, so this runs anywhere.
- It models the *arithmetic*. It cannot prove the operational half of the scheme — the
  server reload, the client restart, and the checks that clients actually moved before
  an old password is retired. What was measured about that half, rather than assumed, is
  in [`operational-constraints.md`](operational-constraints.md).

## Changing the formulas

The four formulas above are a frozen interface. A cell mid-rotation re-derives every
slot version from its counter on the next apply, so a formula change can silently
rewrite a live slot on an apply that was meant to be inert. Treat a failing walk test
as a compatibility break, not a test to update.
