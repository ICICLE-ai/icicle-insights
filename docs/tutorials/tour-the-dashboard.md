# Tour the dashboard

A guided first visit to the public dashboard, for anyone who wants to see how ICICLE's work is being
used. It takes about ten minutes and needs no account.

You will answer three questions along the way:

1. How is the institute's work doing overall?
2. How is one repository doing?
3. Which models and datasets are published, and where?

## Before you start

Open <https://insights.pods.icicleai.tapis.io>. Inside TapisUI the same dashboard is under
*ICICLE Services → Insights*. Everything below works the same in both.

## 1. Read the overview

The first page is **Overview**. Under the title, a line says how many resources are in view and which
dates the page covers, for example *148 resources · last 90 days*.

The grid of tiles shows one figure per metric: Stars, Forks, Watchers, Views, Clones, Downloads, Likes
and Deployments. Each tile adds up the newest reading of every resource in view. The small line under
the number is its history.

Some labels name a window, like **Views · 14 days**. That figure counts only the last 14 days. It
goes up and down, and it is not a running total.

Below the tiles, the **Lifetime** row shows running totals: views, clones, downloads and pulls since
tracking began.

**Checkpoint:** you can say how many stars the institute's repositories have in total.

## 2. Change what the chart shows

1. Click the **Views · 14 days** tile. It gets a border, and the large chart below switches to views.
   The address bar now ends in `?metric=views`.
2. Hover over the chart. A tooltip gives the date and the value.
3. Click **Show data table** under the chart. The same numbers appear as rows, one per day.
4. In the header, click **1y**. The page now covers the last year. The chart plots weekly points for
   ranges longer than about four months.

Everything you choose is kept in the address. Copy it to share exactly this view.

**Checkpoint:** the address contains `metric=views` and `range=1y`.

## 3. Narrow to one platform

1. Click the picker in the header that says **All platforms**.
2. Choose **GitHub**. The tiles, chart and table now count GitHub repositories only.
3. Scroll to **Catalog**. It counts what is tracked by kind and by platform.
4. Scroll to **Resources**. It lists the resources that report the metric you picked, largest first,
   with the change over your range.

## 4. Open one repository

1. Click a row in the table, for example **camera_trap**.
2. The resource page shows its platform, kind and owner, and an **Open on platform** link.
3. On the right, **Collected every**, **Next collection** and **Tracked since** say how fresh the
   figures are. Most resources are read once every 7 days.
4. Below the tiles, each metric has its own chart. **Releases** lists published versions.

You can also jump straight to a resource: open the platform picker and type part of its name.

**Checkpoint:** you know when this repository will next be read.

## 5. Browse models and datasets

1. Click **Models** in the navigation. Each card is one model: its platform, its version and its usage.
2. Use **Most deployed** to sort by downloads, name or last update instead.
3. Switch to **Datasets** at the top right.
4. A card that says **Also on** is published on more than one registry. Click the platform name to
   jump to that copy.

## 6. See where things are published

Click **Provenance**. Each card is one artifact that appears on more than one registry. The top
line is the Patra card. **Also registered as** lists its copies elsewhere, such as Hugging Face.
**Show every link as a table** lists the same links as rows.

## What you learned

- Tiles add up the newest reading of each resource. Windowed metrics describe recent activity.
- The address holds every filter, so any view can be shared as a link.
- Each resource page shows when it was last read and when it will be read next.

Next, [Reading the numbers](../explanation/reading-the-numbers.md) explains why the figures behave
the way they do. [Dashboard reference](../reference/dashboard.md) lists every control.

#icicle-insights# #Tutorial# #Reader#
