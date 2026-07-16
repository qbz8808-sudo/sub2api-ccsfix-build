# Quota race fixture

This command reproduces an eventually consistent quota window entirely on
loopback. Each replica accepts requests from its local quota view, while a
background synchronizer periodically merges pending usage and publishes the
new total to every replica.

Run from `backend`:

```powershell
go run ./cmd/quota-race-fixture -quota 1 -replicas 4 -attempts 4 -rounds 2 -sync-interval 500ms -round-gap 650ms
```

With the default parameters, the first fan-out round can receive four `200`
responses against a shared quota of one. After aggregation, the second round
receives `429` from every replica. The JSON report exposes the per-attempt
replica view and the final `accepted_over_quota` count.
