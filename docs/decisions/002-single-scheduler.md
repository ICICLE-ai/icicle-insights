# ADR 002: One scheduler, scalable workers

**Status:** Accepted

Run exactly one `queues --scheduled` process because schedules lack a distributed leader lock.
Scale `queues --queue <name>` workers horizontally because Valkey claims available payloads
atomically. Delivery remains at-least-once, so this does not remove idempotency requirements.

#icicle-insights# #architecture-decision# #scheduling# #queues#
