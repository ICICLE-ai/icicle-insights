# Add a queue or worker

Introduce a new named queue and the process that drains it. For developers.

## First: do you need one?

Usually not.

| Situation | Do |
|---|---|
| New job on a clock | Register a schedule. The existing scheduler runs it |
| New job dispatched to `metrics` | Register the job. The existing worker runs it |
| Workload needing its own scaling, limits, or isolation | Add a queue |

One worker executes every registered job type placed on its queue. Workers are selected by queue
name, not by Swift type. Job type alone is not a reason for a new queue.

Good reasons: slow exports that should not delay collection, CPU-heavy work needing its own limits,
priority work that must not sit behind a backlog.

## Add a scheduled job

```swift
struct RemoveExpiredData: AsyncScheduledJob {
  func run(context: QueueContext) async throws {
    // query for work, dispatch onto a named queue
  }
}
```

Register the cadence in `configure.swift`:

```swift
app.queues.schedule(RemoveExpiredData()).daily().at(2, 30)
```

That is the only step. **Do not add a scheduler process.** Two schedulers run the same clocks and
dispatch everything twice.

Keep scheduled jobs small: query and enqueue. Platform calls belong in workers, or a slow API
delays the next tick.

## Add a named queue

### 1. Dispatch to it

```swift
try await context.queues(.exports).dispatch(
  BuildExport.self,
  .init(id: id)
)
```

Add the queue name to the queue-name extension, and register the job with `app.queues.add(...)` as
usual.

### 2. Add a Compose service

`docker-compose.yml` writes every service's environment out in full, with no YAML anchors, so one
block maps onto one pod spec. Copy the `queues` service and change the command:

```yaml
  exports:
    image: insights:latest
    build:
      context: .
    command: ["queues", "--queue", "exports"]
    environment:
      # copy the queues service's environment verbatim
    depends_on:
      db:
        condition: service_healthy
      valkey:
        condition: service_healthy
```

No new Valkey or database is needed. All named queues share the existing instance.

### 3. Add a container recipe

In `justfiles/apple-container.just`, beside `queues`:

```just
# Drain the exports queue.
[group('containers')]
exports: build (rm "exports")
    container run --detach --name exports \
        --network '{{ network }}' \
        {{ app_env }} \
        '{{ image }}' queues --queue exports
```

Then add `exports` to two places:

- the `stack` recipe's dependency list, so it starts with everything else;
- the loop in `stop`, so it is cleaned up.

The two files must stay in step. They describe the same stack, service for service.

### 4. Document it

Add the recipe to [just recipes](../reference/just-recipes.md).

## Scaling an existing worker

Safe, and needs no coordination. Valkey moves each available payload to one consumer atomically.

```bash
docker compose up --scale queues=3
```

For Apple Container, run several containers with distinct names and the same command.

Two limits are worth knowing. More workers consume a provider's rate allowance faster, not slower —
a 403 calls for throttling, not concurrency. And one queue still has head-of-line pressure: slow
jobs delay fast ones behind them.

**Never scale the scheduler.**

## Checklist

- [ ] Is it an `AsyncScheduledJob` or an `AsyncJob`?
- [ ] Is every `AsyncJob` registered with `app.queues.add(...)`?
- [ ] Is every scheduled job registered exactly once?
- [ ] Which named queue receives it?
- [ ] Does that queue already have a worker?
- [ ] If the queue is new, is there a worker in **both** Compose and the justfile?
- [ ] If the queue is new, is it in the `stack` dependencies and the `stop` loop?
- [ ] Still exactly one scheduler?
- [ ] Is the job safe to run twice?

That last one is not optional. Delivery is at-least-once.

#icicle-insights# #How-To# #Developer# #queues#
