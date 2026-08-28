# Glossary

Project vocabulary. For administrators and developers.

| Term | Means here |
|---|---|
| **Account** | An identity on a hosting platform that owns resources |
| **Resource** | An agent, repository, model, dataset, package, container, or service being measured |
| **Registry** | The platform an account lives on: GitHub, GHCR, Hugging Face, npm, PyPI, Patra |
| **Kind** | What a resource is. Does not decide which API reports on it |
| **Patra** | ICICLE's own model and dataset registry. Collected without a stored credential |
| **Card** | One (name, version) record in Patra — a model card or a datasheet |
| **Datasheet** | Patra's name for a dataset's card |
| **Deployment count** | `deployments`. How many completed runs Patra recorded, summed across a resource's cards |
| **Provenance link** | A Patra card's record that its artifact also exists in another registry |
| **Cadence** | `collectionIntervalDays`. Spacing booked after a successful collection |
| **Due date** | `nextCollectionAt`. When a resource may next be dispatched |
| **Sweep** | One pass of collection over the resources that are due |
| **Dispatcher** | A scheduled job that finds eligible records and enqueues work |
| **Worker** | A process running `queues --queue <name>`, executing claimed payloads |
| **Scheduler** | The single process running `queues --scheduled`, evaluating the clocks |
| **Named queue** | An independent Valkey list, such as `metrics`, with its own workers |
| **Gauge** | A current value, such as stars or followers. Can fall as well as rise |
| **Rolling window** | A provider total covering overlapping recent days, not a new delta |
| **Watermark** | `countedThrough`. The newest completed day already folded into an all-time total |
| **Fold** | Adding new completed days to an all-time total, guarded by a watermark |
| **Retention window** | How long a provider keeps daily history available |
| **Secret reference** | A database row naming a credential stored outside PostgreSQL |
| **Secret provider** | The replaceable backend that resolves named credentials |
| **Vault** | Tapis Vault, the current secret provider, and the console screen listing its metadata |
| **Webhook token** | A token letting one deployed service post metrics for one resource |
| **Service token** | The same thing. The console calls it this |
| **Root administrator** | `ROOT_ADMIN_USERNAME`. Always an administrator, cannot be removed through the API |
| **Composition root** | `configure.swift`, where concrete infrastructure is chosen once |
| **At-least-once** | A job can run again after a failure, so work must be safe to retry |
| **Tenant** | A Tapis deployment. Each has its own host and its own vault |

#icicle-insights# #Reference# #Administrator# #Developer# #glossary#
