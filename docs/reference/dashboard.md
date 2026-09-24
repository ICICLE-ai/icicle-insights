# Dashboard reference

Every public screen, control and URL parameter of the dashboard, for readers and for anyone linking
to a specific view. The admin console is in [Admin console reference](admin-console.md).

## Header

Present on every public screen.

| Control | What it does |
|---|---|
| **ICICLE Insights** | Returns to the overview |
| Platform picker (**All platforms**) | Limits every screen to one platform. The search box also finds resources by name; choosing one opens its page |
| **30d · 90d · 6m · 1y** | Sets the date range: 30, 90, 182 or 365 days ending today. Default **90d** |
| Moon or sun button | Switches between light and dark themes |
| **Admin**, or your username | Opens the admin console. Shows your username once you are signed in |

The navigation under the header links **Overview**, **Models**, **Resources**, **Releases** and
**Provenance**.

## URL parameters

Every filter lives in the address, so a view can be bookmarked or shared.

| Parameter | Screens | Values | Default |
|---|---|---|---|
| `range` | All | `30d`, `90d`, `6m`, `1y` | `90d` (omitted from the URL) |
| `platform` | Every screen except a resource page | `github`, `huggingface`, `patra`, `ghcr`, `npm`, `pypi` | All platforms |
| `metric` | Overview | A metric id, such as `stars` or `views` | `stars` |
| `kind` | Resources | `container`, `dataset`, `model`, `package`, `repository` | All |
| `kind` | Models | `dataset` | Models |
| `sort` | Resources | A metric id | `stars` |
| `sort` | Models | `downloaded`, `name`, `updated` | Most deployed |
| `category` | Models | A Patra category, lowercased | All |

Metric ids are listed in [Metrics](metrics.md).

## Overview (`/`)

| Part | Contents |
|---|---|
| Title line | Platform in view, resource count, range and its dates |
| Tiles | One per metric with data in view: the sum of each resource's newest reading, with a sparkline. Click a tile to chart that metric |
| **Lifetime** | Running totals for views, clones, downloads and pulls |
| Chart | The selected metric over the range, split by platform. Hover for values. **Show data table** lists them |
| **Catalog** | Resources in view counted by kind and by platform |
| **Resources** | Resources reporting the selected metric, largest first, 10 per page. **See every resource** opens the Resources screen |
| Footer | *About these figures* and the NSF acknowledgment |

## Models (`/models`)

| Part | Contents |
|---|---|
| Title line | Count of models or datasets, total deployments, total lifetime downloads |
| **Models · Datasets** | Switches between model cards and dataset cards |
| Search | Matches names, descriptions and authors |
| Category | Appears when Patra cards carry categories |
| Sort | **Most deployed**, **Most downloaded**, **Name**, **Recently updated** |
| Card | Name, platform, author, year, version, description, details, usage figures. **Also on** links to the same artifact on another registry |

A card with no Patra description says *No description in Patra.* A Hugging Face card with no Patra
record says *A model on Hugging Face.*

## Resources (`/resources`)

| Part | Contents |
|---|---|
| Kind filter | **All**, **Containers**, **Datasets**, **Models**, **Packages**, **Repositories** |
| **Change and trend in** | The metric used for the Δ and Trend columns. Choosing one also sorts by it |
| Filter box | Matches name, platform or kind. Not kept in the URL |
| Table | Name and owner, platform, kind, metric columns, Δ, trend, **Last reading**. Click a header to sort. 20 rows per page |

## Resource page (`/resources/{id}`)

| Part | Contents |
|---|---|
| Heading | Name, platform, kind, owner, **Open on platform** |
| Schedule | **Collected every**, **Next collection**, **Tracked since** |
| Tiles and **Lifetime** | This resource's figures |
| Charts | One per metric, each with **Show data table** |
| **Releases** | Versions and their month |
| **Also registered as** | The same artifact on other registries, as recorded by Patra |

## Releases (`/releases`)

| Part | Contents |
|---|---|
| **Releases per month** | The last 12 months, whatever the range |
| **Recent releases** | Releases inside the range, newest first. Filter by resource or version |

Release dates are recorded to the month.

## Provenance (`/provenance`)

| Part | Contents |
|---|---|
| Cards | One per artifact on more than one registry. The Patra record first, then **Also registered as** |
| **Show every link as a table** | Each recorded link: **Recorded by** and **Names** |

#icicle-insights# #Reference# #Reader#
