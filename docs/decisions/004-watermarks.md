# ADR 004: Watermarks for rolling windows

**Status:** Accepted

GitHub traffic totals overlap between sweeps. Store a per-resource, per-metric `countedThrough`
date and fold only newer completed UTC days under a PostgreSQL advisory lock. This prevents
double-counting and concurrent read-modify-write corruption while preserving unrelated worker
parallelism.

#icicle-insights# #architecture-decision# #watermarks# #data-integrity#
