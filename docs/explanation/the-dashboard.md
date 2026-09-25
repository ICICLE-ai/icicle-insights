# The dashboard

How the dashboard in `web/` is built and why. For developers changing it.

## A static app served by the API

The dashboard is a SvelteKit application compiled to static files. There is no Node or Deno server
in production. The Swift API serves the files from `Public/` and answers every unknown non-API path
with `index.html`, so deep links work.

Everything on screen comes from the API at request time, so there is nothing to prerender. Serving
from the same origin also means no CORS setup, and one image to deploy.

Deno runs the toolchain: installing packages, the Vite dev server, type checks, tests and the build.
Packages are pinned by `deno.lock` and installed with `--frozen` in CI and in the Docker build.

## Figures are totalled on the server

Screens ask for summaries, not raw readings:

| Endpoint | Gives |
|---|---|
| `/api/insights/summary` | One tile per metric: the total now, the total at the start of the range, and a daily series |
| `/api/insights/series` | One metric over time, whole or split by platform, by day or by week |
| `/api/insights/resources` | Resources ranked by a metric, with their figures and a sparkline |

PostgreSQL does the adding up over the whole history. The response size depends on the range, not
on how much has been collected.

The dashboard once fell back to fetching raw readings from `/api/metrics` and adding them up in the
browser, for servers older than these endpoints. That path was capped at 1,000 readings per metric,
so long histories were cut short. It was removed once every deployment served the summaries.

## State lives in the URL

The range, platform, selected metric, sort and filters are query parameters. A view is therefore a
link. The back button undoes a filter, and a reload keeps the view. Free-text filters are the
exception; they are not worth sharing.

## Charts are drawn by hand

Charts are SVG drawn with d3 scales and Svelte, not a charting library. Each platform keeps one
colour on every chart, so filtering never repaints a line. Every full-size chart can show its data
as a table, and hover shows exact values.

Components come from shadcn-svelte, which copies source into `src/lib/components/ui/` instead of
adding a dependency. Tables use TanStack Table.

## Embedded in TapisUI

The same build runs standalone and inside a TapisUI frame. Two settings make embedding work. The
API's `FRAME_ANCESTORS` lets TapisUI frame it. The build's `VITE_TRUSTED_PARENT_ORIGINS` tells the
dashboard which parent may hand it a token. See
[Embed the dashboard in TapisUI](../how-to/embed-in-tapisui.md).

## Types come from the API

`web/src/lib/api/schema.d.ts` is generated from the running API's OpenAPI document. Screens import
friendlier names from `$lib/api/types`. A change to a server response shows up as a type error in
the dashboard once the types are regenerated.

#icicle-insights# #Explanation# #Developer#
