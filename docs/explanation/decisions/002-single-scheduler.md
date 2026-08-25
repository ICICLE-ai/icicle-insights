# ADR 002: One scheduler, scalable workers

**Status:** Accepted

## Context

Collection needs a clock and needs throughput. Those two needs have different scaling properties,
and the framework's scheduler has no distributed leader lock.

## Decision

Run exactly one `queues --scheduled` process. Scale `queues --queue <name>` workers freely.

## Consequences

The scheduler is a single point of failure, and a stopped one is silent: collection simply stops
with nothing failing. Scheduler liveness has to be monitored, which is why the console surfaces a
heartbeat.

Workers scale without coordination, because Valkey moves each available payload to exactly one
consumer atomically.

This does not make execution exactly-once. A worker can fail after an external side effect and
before acknowledging its payload, so idempotency remains each job's responsibility.

Running two schedulers is not a degraded mode. It dispatches every due resource twice, and the
duplicate work is invisible until totals look wrong.

#icicle-insights# #Explanation# #Developer# #decisions# #scheduling#
