# TODO

Known problems and open work, found by using the live site on 2026-09-24 and reading the code. For
whoever picks up the next change. Remove an item in the change that fixes it.

## State on 2026-09-24

Production at <https://insights.pods.icicleai.tapis.io> tracks 148 resources under six accounts.
They are 59 GitHub repositories, 45 GHCR containers, 30 Patra cards and datasheets, 6 Hugging Face
models and datasets, 7 npm packages and 1 PyPI package. It is embedded in TapisUI, and TapisUI's
sign-in carries over to both the embedded and the standalone dashboard. The scheduler is healthy
and no failures are recorded.

## Production problems

| Problem | Evidence | Fix |
|---|---|---|
| GHCR containers are never collected | All 45 show **Next collection: Not scheduled**, and the sweep only picks up resources with a due date. They came from the July 2026 snapshot, which set no dates | [PR #30](https://github.com/ICICLE-ai/icicle-insights/pull/30) adds a migration that books them. It runs when the API starts after deploy |
| No 30-day GHCR pulls yet | Only the lifetime totals imported on 2026-07-24 exist | Clears after the first sweep once PR #30 is deployed |
| Three GHCR packages cannot be found | `fass-api`, `gnnfoodflowportal` and `isawfrontend` could not be read in an earlier check. They are likely private or deleted | Fix or delete them, or they will fail and retry every 1–12 hours once scheduled |
| Patra cards show *No description in Patra.* | All 30 production cards have every detail field null. The catalog sweep refreshes every card's details on each run, so the new code has not run yet | Check the worker and scheduler run the same image as the API. Then run `collect-patra-catalog`, or wait for 04:00 |

## Dashboard bugs seen on the live site

| Where | Problem |
|---|---|
| Resource page charts | With little data, axis labels repeat: *0 0 0 1 1 1* on the y axis, *Sep 21 Sep 21 Sep 22* on the x axis |
| Model cards | Plurals are wrong: *1 deployments*, *1 likes* |
| Overview for a platform with no current readings | Nothing below **Lifetime**, with no message saying why |
| Resources, **Containers** | The columns stay Stars, Forks, Watchers and Views, all dashes. Columns should follow the kind |
| Overview load | `/api/insights/summary` is requested twice for the same range |

## Admin console

| Where | Problem |
|---|---|
| **Add resource** | **Kind** stays *Repository* when the account changes to GHCR or Hugging Face |
| **Add resource** | The cadence hint shows the raw platform id: *1 to 7 days on github* |
| **Accounts** | Every row menu is labelled *Actions for icicle-ai*, so screen readers cannot tell them apart |
| Row menus | After closing a sheet or menu with Escape, the next click on a trigger was sometimes ignored |
| **Add resource** for npm or PyPI | The resource is booked and dispatched weekly, and the dispatcher skips it. The console shows a **Next collection** that never collects anything |
| **Vaults** | Nothing warns before a platform token expires, unlike service tokens and `TAPIS_TOKEN`. Both current tokens expire 2027-08-24 |
| Console | No way to collect one resource now; only the command line can |

## Code and repository

- **Remove the dashboard's legacy data source** (`web/src/lib/data/legacy.ts`). Production serves the
  summary endpoints and no longer calls `/api/metrics` for the dashboard.
- **Remove the unused `layerchart` dependency** from `web/package.json`. The charts are drawn with
  `d3-scale` and SVG, and nothing imports it.
- **Fix `.github/dependabot.yml`.** It is the unfilled template, with `package-ecosystem: ""`.
- **The `Platform` enum comment** in `Models/Account.swift` still refers to the Angular dashboard's
  colour order, which no longer exists.
- **Retake or delete `assets/screenshots/`.** Every image shows the old Angular dashboard, so the
  README no longer shows any. Capture at 1440×900, 2× scale, light theme.

## Verify after the next deploy

- **Turn on database backups.** Until a bucket is chosen and the `BACKUP_S3_*` values are set, the
  only backup is a manual dump. See `docs/how-to/set-up-database-backups.md`.
- `/admin` → **Operations → Scheduler** is **Healthy**.
- **Resources** in the console shows no *Not scheduled* GHCR rows. npm and PyPI rows stay that way.
- The GHCR view on the dashboard has a **Pulls · 30 days** tile.
- Patra model cards show descriptions and authors.

## Not planned

- **npm and PyPI collection.** Both stay in the catalog, uncollected. Their download counts include
  every CI runner and mirror that fetches a package, so they cannot say how many people use it.

#icicle-insights# #Reference# #Administrator# #Developer#
