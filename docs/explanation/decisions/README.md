# Architecture decision records

Why the system is shaped the way it is. Read the relevant record before changing a queue,
watermark, lock, or service boundary.

Each record states the situation, the decision, and what the decision costs. A record is history:
amend it only to correct a fact, and supersede it with a new record rather than editing the
decision away.

| # | Decision | Status |
|---|---|---|
| [001](001-valkey-queues.md) | Valkey holds queued jobs | Accepted |
| [002](002-single-scheduler.md) | One scheduler, scalable workers | Accepted |
| [003](003-secret-provider.md) | Credentials behind a provider interface | Accepted |
| [004](004-watermarks.md) | Watermarks guard all-time totals | Accepted |
| [005](005-failure-alerting.md) | Failures are classified, then alerted | Accepted |
| [006](006-api-authentication.md) | Two credential paths, one guard | Accepted |
| [007](007-hardening.md) | Headers, limits, and live key rotation | Accepted |

#icicle-insights# #Explanation# #Developer# #decisions#
