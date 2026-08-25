# Queues and scheduling

One scheduler, many workers, and how to tell which you need. For developers.

## Three roles

| Role | Command | How many |
|---|---|---|
| HTTP server | `serve` | One or more |
| Scheduler | `queues --scheduled` | **Exactly one** |
| Named worker | `queues --queue <name>` | At least one per queue in use |

Adding a scheduled job does **not** need another scheduler. Register its cadence and the existing
scheduler runs it alongside the others.

Adding a queued job usually does **not** need another worker. If it is dispatched onto `metrics`,
the existing worker executes it. Workers are selected by queue name, not by job type — one worker
handles every registered type placed on its queue.

Add a worker only when a job is deliberately dispatched to a **new queue name**.

## Why the scheduler is single

Vapor's scheduler has no distributed leader lock. Two replicas evaluate the same clocks and enqueue
the same work twice.

Workers have the opposite property. Valkey moves each available payload to exactly one consumer
atomically, so two workers draining the same queue cannot claim the same job. No application-level
coordination is needed; both processes simply consume the same list.

That asymmetry is the entire scaling rule: **drainers scale horizontally, the scheduler stays at
one**.

## At-least-once, not exactly-once

Atomic claiming is not exactly-once execution. A worker can fail after an external side effect but
before acknowledging its payload, and the job runs again.

Jobs must therefore be safe to retry. For counting, that safety comes from watermarks — see
[Watermarks](watermarks.md). For anything new that reads, modifies, and writes, it has to come from
somewhere equivalent.

Horizontal workers also introduce real concurrency. The metric fold takes a PostgreSQL advisory
transaction lock keyed by resource and metric type, so two folds cannot corrupt the same all-time
value while unrelated resources proceed in parallel. A new read-modify-write job needs its own
equivalent protection.

## When a separate queue is worth it

A new job type can share an existing queue. Introduce a named queue when a workload needs its own:

- concurrency or scaling,
- resource limits,
- failure isolation,
- priority, so it does not sit behind a large backlog.

Slow exports that should not delay metric collection are the clearest case. Job type alone is not a
reason.

## The limits of adding workers

Two things bound how far scaling the worker helps.

**Provider allowances are shared.** More workers consume a platform's rate limit faster, not
slower. A 403 from GitHub or an exhausted remaining-requests header calls for throttling or delayed
retries, not more concurrency.

**One queue still has head-of-line pressure.** A backlog of slow jobs delays fast ones behind them.
That is when splitting by workload starts to pay.

## Keeping the scheduler cheap

Scheduled jobs query for work and enqueue typed payloads. They do not call platform APIs.

If a sweep made the remote calls itself, a slow platform would delay the next tick and the clock
would drift. Keeping the work on the queue means the scheduler's job is always short.

The one exception is the daily expiry warning, which sends alerts inline. It writes nothing and
makes no platform calls, so there is nothing to move onto a queue.

## Adding to the stack

Both `docker-compose.yml` and `justfiles/apple-container.just` describe the same processes, service
for service. A new worker needs an entry in each, and adding it to the `stack` recipe's dependency
list and the `stop` loop.

See [Add a queue or worker](../how-to/add-a-queue-or-worker.md).

#icicle-insights# #Explanation# #Developer# #queues#
