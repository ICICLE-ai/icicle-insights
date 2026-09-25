# Metrics and collection

What Insights measures, where each figure comes from and when it is collected. For readers checking
a definition, and administrators and developers checking a schedule.

## Metric types

The id is what the API and the URL use. The label is what the dashboard shows.

| Id | Dashboard label | Kind | Source |
|---|---|---|---|
| `stars` | Stars | Total | GitHub |
| `forks` | Forks | Total | GitHub |
| `subscribers` | Watchers | Total | GitHub |
| `views` | Views · 14 days | Window | GitHub traffic |
| `clones` | Clones · 14 days | Window | GitHub traffic |
| `downloads` | Downloads · 30 days | Window | Hugging Face |
| `likes` | Likes | Total | Hugging Face |
| `deployments` | Deployments | Total | Patra |
| `pulls` | Pulls · 30 days | Window | GHCR package page |
| `authentications` | Authentications | Window | Posted by a service |
| `viewsAllTime` | Views · all time | Lifetime | Summed by Insights from `views` |
| `clonesAllTime` | Clones · all time | Lifetime | Summed by Insights from `clones` |
| `downloadsAllTime` | Downloads · all time | Lifetime | Reported by Hugging Face |
| `pullsAllTime` | Pulls · all time | Lifetime | Reported by GHCR |
| `authenticationsAllTime` | Authentications · all time | Lifetime | Summed by Insights from `authentications` |

- **Total:** the platform reports the whole figure each time. It can go down.
- **Window:** activity over a trailing window. It rises and falls with activity.
- **Lifetime:** a running total. The API refuses writes to these types directly.

Any type except the lifetime ones can be recorded by hand or posted by a service. A reading of a
windowed type recorded that way is also added to its lifetime total.

## Platforms

| Platform | Resource kinds | Metrics written | Needs a stored token | Longest cadence | Data-loss window |
|---|---|---|---|---|---|
| GitHub | Repositories | `stars`, `forks`, `subscribers`, `views`, `clones`, `viewsAllTime`, `clonesAllTime` | Yes | 7 days | 14 days |
| Hugging Face | Models, datasets | `downloads`, `likes`, `downloadsAllTime` | Yes | 30 days | None |
| Patra | Models, datasets | `deployments`, plus card details | No | 30 days | None |
| GHCR | Containers | `pulls`, `pullsAllTime` | No | 30 days | None |
| npm | Packages | Not collected, on purpose | No | 30 days | None |
| PyPI | Packages | Not collected, on purpose | No | 30 days | None |

- **Longest cadence** is the largest *Collect every (days)* the API accepts for a resource.
- **Data-loss window** is how long the platform keeps daily figures. If GitHub traffic goes
  uncollected for more than 14 days, the missing days are gone for good.
- GitHub accounts also get a follower count, collected monthly.
- npm and PyPI are catalogued but not collected. Their download counts cannot separate people from
  CI runners and caches, so they would not measure use. Nothing collects them, whatever the console says about their next
  collection.

## Where each figure comes from

| Platform | Request |
|---|---|
| GitHub | `api.github.com/repos/{owner}/{repo}`, then `/traffic/clones` and `/traffic/views` |
| GitHub account | `api.github.com/orgs/{account}` |
| Hugging Face | `huggingface.co/api/models/{owner}/{name}` or `/api/datasets/…`, expanded with downloads, lifetime downloads and likes |
| Patra catalog | `patrabackend.pods.icicleai.tapis.io`: every public model card and datasheet |
| Patra deployments | `/modelcard/{uuid}/deployments` for each card the resource groups |
| GHCR | `github.com/orgs/{account}/packages/container/package/{name}`, then the `/users/…` address |

GHCR has no API for download counts, so Insights reads the public package page. See
[How collection works](../explanation/how-collection-works.md).

## Schedule

The scheduler process runs these on the container clock, which is UTC unless `TZ` is set.

| Job | When | What it does |
|---|---|---|
| `CollectDueResources` | Hourly, on the hour | Queues a sync for every resource whose next collection is due |
| `CollectAccountStats` | Monthly, the 1st at 03:00 | Queues a follower sync for every GitHub account |
| `ScheduleDatabaseBackup` | Daily at 02:00 | Queues a database backup, when `BACKUP_S3_BUCKET` is set |
| `CollectPatraCatalog` | Daily at 04:00 | Queues discovery of new or changed Patra cards |
| `WarnExpiringServiceTokens` | Daily at 07:00 | Alerts at 14, 7, 3 and 1 days before a service token expires |
| `WarnExpiringTapisToken` | Daily at 07:00 | Alerts at 7, 3, 1 and 0 days before `TAPIS_TOKEN` expires |

The sync jobs run on the `metrics` queue:

| Sync job | Platform |
|---|---|
| `SyncGitHubRepoStats` | GitHub repositories |
| `SyncGitHubOrgStats` | GitHub accounts |
| `SyncHuggingFaceHubStats` | Hugging Face |
| `SyncPatraCatalog` | Patra accounts |
| `SyncPatraDeployments` | Patra resources |
| `SyncGHCRStats` | GHCR containers |

`BackupDatabase` also runs there. It dumps the database and uploads it; see
[Set up database backups](../how-to/set-up-database-backups.md).

## Retries and re-booking

| Situation | What happens |
|---|---|
| A sync throws | Retried after 30 seconds, 2 minutes, then 8 minutes |
| Retries exhausted, credential problem | Logged as critical, alerted, re-booked in 1 hour |
| Retries exhausted, anything else | Alerted as a warning, re-booked after a quarter of its overdue time, between 1 and 12 hours |
| GitHub gap passes 14 days | One extra alert saying days were lost |
| Same alert within 6 hours | Logged and stored, but not sent again |
| A backup throws | Retried after 30 seconds, then 2 minutes. Then alerted as a warning, `backup_failed`, and tried again the next night |

Error identifiers are listed in [Collection failures](collection-failures.md).

#icicle-insights# #Reference# #Reader# #Administrator# #Developer#
