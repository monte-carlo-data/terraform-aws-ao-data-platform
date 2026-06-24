# Verify — is the deployment correct & complete?

Run `collect-state.sh --mode verify` (see SKILL.md for resolving the target and invoking the
script). In `verify` mode every expected value is asserted, so a missing/incorrect one is a `FAIL`.
Interpret the summary and give the user a clear verdict — don't just echo the table.

## Reading the summary

- **All PASS** → state it plainly: the deployment is correct and complete, no remediation needed.
- **Any FAIL/WARN** → hand off to `troubleshoot.md`; report the specific layer and the cause, not
  just "something failed."
- **SKIP is not failure.** `nlb`/AWS checks SKIP without credentials (`--no-aws` or no creds);
  `tls-live`/exec checks SKIP without pod-exec rights (`--no-exec`). Say *what* was skipped and why,
  and that it's a capability gap on the runner, not a problem with the deployment.

Expected-state notes (so you don't misreport healthy state):
- **1 PVC** is normal — ClickHouse runs as a single-replica, AZ-locked StatefulSet (one shard).
- A second ExternalSecret (`ao-clickhouse-readonly-user-credentials`) appears only when the optional
  read-only user is enabled; its absence is fine.
- Targets in `initial` health-check briefly after a deploy/restart are expected, not unhealthy.

## What the read-only sweep deliberately does NOT prove

The sweep confirms the pipeline is *built and healthy*. It does **not** confirm that **trace data
actually flows end-to-end**, because that requires authenticating to ClickHouse (a secret) and/or
writing data — outside the read-only, no-secrets contract. Offer the checks below as an optional
next step; **emit them for the user to run** — do not run them yourself.

## Active-verification appendix (emitted; customer-run)

> These **change state and/or need the `otel` password**: they create a short-lived pod, write a
> synthetic trace, and read a credential. They are safe (the test span is tagged and TTLs out with
> normal retention) but they are the customer's to run. Never print the retrieved password.

**1 — Confirm the schema and query as `otel`** (needs the password):
```bash
# Retrieve the otel password into a shell var (value is never printed by the skill):
CH_PW=$(kubectl get secret -n <ns> ao-clickhouse-otel-credentials -o jsonpath='{.data.password}' | base64 -d)

# Schema present, and current row count:
kubectl exec -n <ns> <clickhouse-pod> -- \
  clickhouse-client --user otel --password "$CH_PW" \
  --query "SHOW TABLES FROM otel_traces; SELECT count() FROM otel_traces.otel_traces"
```

**2 — End-to-end smoke test** (sends a trace through the Collector, confirms it lands):
```bash
TRACE_ID="0000000000000000$(date +%s%N | tail -c 17)"
kubectl run otlp-smoke-$$ -n <ns> --rm -i --restart=Never --image=curlimages/curl -- \
  -sk -X POST https://opentelemetry-collector:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"ao-skill-smoke-test"}}]},"scopeSpans":[{"spans":[{"traceId":"'"$TRACE_ID"'","spanId":"0000000000000001","name":"smoke","kind":1,"startTimeUnixNano":"'"$(date +%s)000000000"'","endTimeUnixNano":"'"$(date +%s)000000000"'","status":{}}]}]}]}'

sleep 8   # let the batch processor flush
kubectl exec -n <ns> <clickhouse-pod> -- \
  clickhouse-client --user otel --password "$CH_PW" \
  --query "SELECT count() FROM otel_traces.otel_traces WHERE TraceId='$TRACE_ID'"
# >0 → the OTLP → Collector → ClickHouse pipeline works end-to-end.
```

Fill `<ns>` and `<clickhouse-pod>` from the sweep output (namespace, and the
`clickhouse.altinity.com/chi=otel` pod). If a check fails, route to `troubleshoot.md`
(*Traces aren't arriving* / *Collector isn't writing to ClickHouse*).

## After a clean verify

Point the user at the hand-off to Monte Carlo — provide the ClickHouse endpoint and the `otel`
credentials to MC (the `otel` user, not a read-only one):
`https://docs.getmontecarlo.com/docs/ao-platform-connect-to-monte-carlo`. Deploying the Monte Carlo
Agent itself is out of scope for this skill — link, don't walk through it.
