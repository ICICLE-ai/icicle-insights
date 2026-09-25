# Collect now

How to collect one resource, or run a collection sweep, without waiting for the schedule. For
administrators, and developers on a local stack.

Every option below only queues work. A `queues` worker must be running to do it.

## Collect one resource from the console

1. Sign in at `/admin` and open **Resources**.
2. Open the **⋯** menu on the resource's row and choose **Collect now**.
3. Check for *Collection queued for …*. The row's **Next collection** moves one cadence ahead.

That date is the lease a sweep books, so the next sweep does not queue it twice. See
[How collection works](../explanation/how-collection-works.md). The item is blocked with *npm is not
collected*, *PyPI is not collected* or *Its account has been deleted*.

## Sweep resources that are due

Queues every resource whose next collection has passed. Use it after fixing a token.

| Where | Command |
|---|---|
| Inside a running container | `./Insights collect-resources` |
| Docker Compose | `docker compose run --rm collect-now` |
| Apple Container stack | `just collect-now` |
| Native, from the repository | `just collect` |

## Sweep every resource

Add `--force` to mark every active resource due first.

```bash
./Insights collect-resources --force
```

Every resource then books its next collection from now, so the whole schedule shifts. Compose calls
this `collect-all-now`, and so does the Apple Container stack.

## Resources that are not scheduled

npm and PyPI resources are never collected, on purpose, whatever **Next collection** says for them.

Any other resource whose **Next collection** is *Not scheduled* is skipped by every sweep, except
`collect-resources --force`. Choose **Collect now** on its row. That queues it and books its next
date, so later sweeps pick it up.

## Other sweeps

| Command | What it queues | Normally runs |
|---|---|---|
| `collect-accounts` | Follower counts for every GitHub account | Monthly |
| `collect-patra-catalog` | Discovery of new Patra model cards and datasheets | Daily at 04:00 |

## Check it worked

- In the admin console, **Operations → Waiting on "metrics"** rises, then falls back to 0.
- **Metrics** lists new readings stamped *just now*.

#icicle-insights# #How-To# #Administrator# #Developer#
