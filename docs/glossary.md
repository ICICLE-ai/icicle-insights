# Glossary

| Term | Meaning in Insights |
|---|---|
| Account | Identity on a hosting platform that owns resources |
| Resource | Repository, model, dataset, package, image, or service being measured |
| Dispatcher | Small job that finds eligible records and enqueues executable jobs |
| Worker / drainer | Process running `queues --queue <name>` that executes claimed payloads |
| Scheduler | Single process running `queues --scheduled` that evaluates registered clocks |
| Named queue | Independent Valkey list such as `metrics`, with its own workers |
| Snapshot | Current value at collection time, such as stars or followers |
| Rolling window | Provider total covering overlapping recent days, not a new delta |
| Watermark | Newest completed daily value already folded into an all-time total |
| Due date | `nextCollectionAt`; when a resource may next be dispatched |
| Cadence | `collectionIntervalDays`; spacing booked after successful dispatch |
| Retention window | How long a provider keeps daily history available for collection |
| Secret reference | Database metadata naming a credential stored outside PostgreSQL |
| Secret provider | Replaceable backend that resolves and manages named credentials |
| Composition root | `configure.swift`, where concrete infrastructure is selected |
| At-least-once | A job can execute again after failure or retry, so work must be retry-safe |

#icicle-insights# #glossary# #developer-documentation#
