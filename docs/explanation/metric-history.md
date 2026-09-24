# Metric history

How Insights answers "what was this figure on a given day". For developers.

## Why the browser stopped adding things up

The dashboard used to fetch raw readings from `/api/metrics`, one request per metric type, and
total them itself. That route returns at most 1000 rows, newest first.

The cap was invisible. Once a type passed 1000 readings across all resources, the oldest simply
stopped arriving, and the chart's early history quietly flattened. Stars reached the cap first.

The `/api/insights` routes move the arithmetic into PostgreSQL. They read every row in scope and
return one number per day, so a response grows with the range asked for, not with how much has
been collected.

## Carrying a reading forward

A resource is swept every few days, so most days have no reading at all. A resource's value on a
day is therefore its latest reading by the end of that day. A total is the sum of those values
across the resources in scope.

A resource contributes nothing before its first reading. A series starts on the first day anything
in scope has a value, rather than reporting zeros before it. Zeros there would draw growth out of
nothing.

The starting figure, `atStart`, is `null` rather than zero when nothing had a value by `from`. The
two mean different things: zero stars is a fact, no reading is an absence of one.

## Why a running sum

The obvious query asks, for every day, what every resource's latest reading was. That repeats the
same lookup once per day of the range.

Instead each resource contributes its first value, then only the difference each time it changes.
Summing those changes day by day gives the same totals while reading each row once. Everything
before `from` folds into one point on `from`, which is also where `atStart` comes from.

Soft-deleted resources, and resources whose account was deleted, are left out of every figure.
Their readings still exist, and counting them would put a retired account back into the totals.

## Lifetime totals had no past

Rolling windows and gauges keep one row per sweep, so their history is already in `metrics`.

All-time totals do not. Each is a single row, updated in place by the fold, and
`Metric.recordedAt` is stamped only when that row was created. The row knows today's figure and
nothing about last month's.

`metric_daily_totals` fills that gap. Every write of an all-time total also upserts one row for
that resource, type, and UTC day. A second write the same day overwrites it, so each row ends the
day holding that day's closing total.

## Same transaction, on purpose

The snapshot is written on the same connection as the total, inside the same transaction.

A snapshot therefore never records a total that rolled back. That matters because a sweep's writes
all commit or roll back together, and a retried sweep must not leave a day's history claiming a
figure that never landed.

## Why history starts at deploy

There is no backfill, and there cannot be one.

The old totals were overwritten and never stored anywhere else. Summing past `clones` readings
would count overlapping windows many times over, which is the problem the watermark exists to
solve. The Hub's lifetime downloads were only ever kept as the latest figure.

Any reconstruction would be a guess that looks exactly like data. So lifetime history begins the
day `MetricDailyTotals` was deployed. Before then the API returns an empty series and a `null`
starting value, which is the honest answer.

## Related

- [Watermarks](watermarks.md) explains how the totals themselves avoid double counting.
- [Metric collection](metric-collection.md) explains gauges, rolling windows, and sweeps.
- [HTTP API](../reference/http-api.md) lists the routes, parameters, and response fields.
- [Data model](../reference/data-model.md) describes `metric_daily_totals`.

#icicle-insights# #Explanation# #Developer# #collection#
