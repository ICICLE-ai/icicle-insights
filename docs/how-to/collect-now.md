# Collect now

How to run a collection sweep immediately instead of waiting for the schedule. For administrators
with access to the deployment, and developers on a local stack.

Each command below only queues work. A `queues` worker must be running to do it.

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
`collect-resources --force`. To book just that one, set its date in the database. Its id is the
last part of its dashboard address, `/resources/{id}`.

```sql
UPDATE resources
SET next_collection_at = now()
WHERE id = 'the-resource-id';
```

Then run `collect-resources`, or wait for the next hourly sweep.

## Other sweeps

| Command | What it queues | Normally runs |
|---|---|---|
| `collect-accounts` | Follower counts for every GitHub account | Monthly |
| `collect-patra-catalog` | Discovery of new Patra model cards and datasheets | Daily at 04:00 |

## Check it worked

- In the admin console, **Operations → Waiting on "metrics"** rises, then falls back to 0.
- **Metrics** lists new readings stamped *just now*.

#icicle-insights# #How-To# #Administrator# #Developer#
