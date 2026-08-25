# Run collection immediately

Collect now instead of waiting for the schedule. For administrators and developers.

Useful after adding a resource, after fixing a credential, or when verifying a deployment.

## Prerequisite

A `queues --queue metrics` worker must be running. These commands only enqueue; the worker does the
collecting. Without one, jobs pile up in Valkey and nothing is written.

## Pick a command

| Command | Collects | Changes the schedule |
|---|---|---|
| `collect-resources` | Resources already due | Advances each dispatched resource |
| `collect-resources --force` | Every active resource | Advances every one, shifting all cadences forward |
| `collect-accounts` | Every GitHub account's followers | No |

## Locally

```bash
just collect
```

```bash
just collect --force
```

```bash
just collect-accounts
```

## In the container stack

```bash
just collect-now
```

```bash
just collect-all-now
```

```bash
just collect-accounts-now
```

## In a deployment

```bash
docker compose run --rm collect-now
```

Or run `Insights collect-resources` in a one-shot container against the deployment's environment.

## Watch it happen

The command exits as soon as it has enqueued. Follow the worker to see the API calls and writes.

```bash
container logs -f queues
```

```bash
docker compose logs -f queues
```

## Confirm it worked

The **Operations** console shows the collection pipeline count fall back to zero and the scheduler
heartbeat update. New readings appear on the Catalog → Metrics tab.

## Which one to use

Use `collect-resources` by default. It is the closest thing to what the schedule does, and
dispatching zero jobs is a normal outcome when nothing is due.

Use `--force` only when you intend to reset every resource's cadence. It shifts every next-collection
date forward from now, so a weekly resource will not collect again for another week.

## This cannot double count

Forcing a collection changes *when* a platform is asked, not *which days have already been counted*.
Rolling values are still folded through their watermark, so a forced run adds only genuinely new
completed days. See [Watermarks](../explanation/watermarks.md).

## Troubleshooting

**Zero resources dispatched.** Nothing was due. That is normal. Use `--force` if you meant to
collect everything.

**Dispatched, but no readings appeared.** The worker is not running, or it failed. Check its logs.

**A platform was skipped.** GHCR, npm, and PyPI have no collector yet. See
[Collection schedule](../reference/collection-schedule.md).

**The all-time total did not move.** Often correct: no completed day newer than the watermark was
returned.

#icicle-insights# #How-To# #Administrator# #Developer# #collection#
