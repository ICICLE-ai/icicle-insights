# Reading the numbers

Why the dashboard's figures behave the way they do, for anyone who reads them or quotes them.

## A reading, not a live counter

Insights does not watch platforms continuously. It visits each resource on a schedule, usually once
every 7 days, and records what the platform reports at that moment. Each visit is a *reading*.

So a figure is only as fresh as its last reading. A resource page shows **Tracked since**, **Next
collection** and, in the tables, **Last reading**. A star added yesterday appears at the next visit,
not before.

This is also why charts look like steps. The line holds its value between readings and moves when a
new one lands.

## Three kinds of figure

Every metric falls into one of three kinds, and each answers a different question.

**Totals the platform reports in full.** Stars, forks, watchers, likes and deployments. Each reading
is the whole count, so the newest reading is the answer. These can fall: people unstar repositories.

**Windows.** Views and clones cover the last 14 days. Downloads and pulls cover the last 30. The
platform reports only that window, so the number describes recent activity, not accumulation. The
dashboard always names the window in the label, as in **Views · 14 days**. A window going down means
activity slowed, not that anything was lost.

**Lifetime totals.** The **Lifetime** row shows views, clones, downloads and pulls since the
beginning. They come from two places:

- Hugging Face and GHCR report their own lifetime totals. Insights copies them as they are.
- GitHub keeps traffic for only 14 days. Insights adds each completed day to its own running total,
  once. GitHub lifetime views and clones therefore count from when Insights started tracking the
  repository, not from the repository's creation.

## How a tile adds up

A tile adds the newest reading of every resource in view. With **All platforms** selected, the
Stars tile is the sum of every repository's latest star count.

Two consequences follow:

- Resources are read on different days, so a tile mixes readings of different ages. Over a 7-day
  cadence the spread is at most a week.
- Windowed tiles add windows together. *Views · 14 days* is the sum of each repository's latest
  14-day count. It is not the views of one specific fortnight.

The change figure compares the total now with the total at the start of the range. A resource added
during the range counts toward the change from the day it was added.

## Resources, not artifacts

Totals count resources. One trained model can be a Patra card, a Hugging Face model and a GitHub
repository at the same time. Each is its own resource, measured by its own platform.

The metrics rarely overlap, because each platform reports different things. Patra reports
deployments and Hugging Face reports downloads. The **Provenance** page and the **Also on** links on
model cards show which resources are the same artifact.

## When a figure is missing

A dash means the resource has no reading for that metric. A container has no stars, so it shows a
dash in the Stars column rather than zero.

A platform can be listed with no tiles at all. Its resources are catalogued, but nothing is
collected for them. npm and PyPI packages stay that way on purpose. Their download counts include
every CI runner and mirror that fetches a package, so they cannot say how many people use it.

## Dates

Days are UTC. A range such as *last 90 days* ends today and includes today. Ranges longer than about
four months plot one point per week, the value on the last day of that week.

#icicle-insights# #Explanation# #Reader#
