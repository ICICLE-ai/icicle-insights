# ADR 001: Valkey-backed queues

**Status:** Accepted

Use Vapor Queues with a Redis-compatible Valkey service instead of polling a PostgreSQL jobs
table. This provides blocking claims, durable payloads, named queues, and horizontal workers.
PostgreSQL remains the domain store; Valkey remains disposable queue infrastructure with AOF
enabled locally.

#icicle-insights# #architecture-decision# #valkey# #queues#
