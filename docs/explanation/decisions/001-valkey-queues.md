# ADR 001: Valkey holds queued jobs

**Status:** Accepted

## Context

Collection work has to survive a restart and be handed to exactly one worker. The obvious
alternative was a jobs table in PostgreSQL, which the application already runs.

## Decision

Queue payloads live in Valkey, through the Vapor Redis queues driver. Any Redis-protocol server
works.

## Consequences

A worker's poll is a blocking pop rather than a table scan on every tick, and there is no jobs table
to migrate or vacuum.

Valkey becomes a required dependency for anything that dispatches. A dispatch with no reachable
queue service fails immediately rather than degrading.

The same instance also backs rate-limit counters, so limits hold across replicas instead of being
granted afresh by each one.

Delivery is at-least-once. Atomic claiming prevents two workers taking the same payload; it does
not prevent a job running twice after a crash. Every job must be safe to retry.

#icicle-insights# #Explanation# #Developer# #decisions# #queues#
