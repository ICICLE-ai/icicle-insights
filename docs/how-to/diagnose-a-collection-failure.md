# Diagnose a collection failure

Work out why metrics stopped arriving. For administrators and developers.

Start at **Administration → Operations**. The four status tiles and the watchlist name most
problems directly.

## Nothing is collecting at all

**Check the scheduler heartbeat** in the Administrator context panel.

A stale timestamp means the scheduler is not running. It is the one process that must be running
and must be alone. A stopped scheduler is silent: collection simply stops and nothing fails.

```bash
container logs -f scheduled
```

If the heartbeat is current, check the **Collection pipeline** tile. A rising waiting count with
nothing running means the scheduler is enqueueing but no worker is draining.

```bash
container logs -f queues
```

Restart the worker. The HTTP server and the scheduler do not execute jobs.

## Every account stopped at once

Almost always `TAPIS_TOKEN`. Every account's credential is read through it, so its expiry stops all
collection while the platforms stay healthy.

1. Find `tapis_token_expires_at` on the `Secret provider selected.` line of the boot log.
2. If that time has passed, renew the token in Tapis.
3. Update `TAPIS_TOKEN` on every process and restart them.

The next hourly sweep resumes collection. The `WarnExpiringTapisToken` alert gives 7, 3, and 1
days' notice, then one critical alert once the token has lapsed.

## One account stopped collecting

Almost always its credential.

Check the **Vault credentials healthy** tile. An expired credential fails every resource under that
account at once, while the platform APIs are perfectly healthy.

Rotate the credential on the platform, then use **Rotate** on the Vaults screen. The next sweep
picks it up. No backfill is needed.

## The same alert repeats every six hours

Working as intended.

A credential failure re-books its resource about an hour out rather than letting it sit out a full
cadence, so it fails again every hour until the credential is repaired. Slack hears about it once
per six hours; the rest are suppressed. That is what makes a fixed token resume collection
unattended without flooding the channel.

One alert can stand for many resources. To see every resource affected, search the log for the
alert's identifier, or read the persisted failures:

```bash
curl -H "Authorization: Bearer $TOKEN" https://insights.example.org/api/admin/failures?limit=200
```

To silence it without fixing the credential, clear the resource's next-collection date. The sweep
skips resources with no due date.

## GitHub returns 403

GitHub uses 403 for both an expired token and a secondary rate limit, and only the response body
distinguishes them. The alert quotes the body for exactly this reason.

If it is a rate limit, **do not add workers**. More workers consume the same allowance faster.
Lengthen cadences or reduce concurrency.

## Every GHCR package fails with `page_layout_changed`

GitHub has changed its package page, so the parser no longer finds the download figures. Nothing is
lost meanwhile: the next successful sweep reads GitHub's lifetime total again.

1. Open the URL in the alert. Find where the page now shows "Total downloads" and the 30-day chart.
2. Update the selectors in `Sources/Insights/Services/GHCR/GHCRPackagePage.swift`.
3. Save the page to `Tests/Fixtures/GHCR/`, trimmed like the copies already there, and run
   `just test`.
4. Deploy. The failing resources re-book within twelve hours and then collect on their own.

One GHCR package failing with status 404 is different. GitHub found no public page under either the
organization or the user address. Check the resource's name, or whether the package is now private.
See [ADR 009](../explanation/decisions/009-scraping-ghcr.md).

## A resource never collects

Check its **Next collection** date on the Catalog → Resources screen.

| Shows | Means |
|---|---|
| `Not set` | Never booked. The sweep skips it. New resources are created due, so only older or hand-made rows show this |
| A future date | Not due. Normal |
| A past date | Due, but the sweep is not running or is failing |

Changing the cadence does not make a resource due. It sets the spacing applied after the next
successful collection. To collect now, see
[Run collection immediately](run-collection-immediately.md).

## Readings arrive but the all-time total does not move

Usually correct.

Rolling values are folded through a watermark, and only completed days newer than the watermark are
added. If a response contains no new completed day, the total is already current. See
[Watermarks](../explanation/watermarks.md).

Also note that gauges — stars, forks, likes, followers — have no all-time total by design. The
series is the record.

## Failures are logged but never reach Slack

Check `SLACK_WEBHOOK_URL` on the `queues` and `scheduled` processes. Jobs fail there, so that is
where the notifier fires.

Unset or empty selects the log-only notifier, which is the intended default for tests and local
runs. The boot log says which was selected on the `Failure alerting configured.` line.

If it is set, look for a delivery failure in the log. Alert delivery never fails a job, so a log
line is its only trace.

The webhook belongs in `.env`, which is gitignored. Anything secret placed in `.env.container` is
secret in the repository.

## Everything returns 403

Not a collection problem. `TAPIS_BASE_URL` and `TAPIS_TENANT` are probably naming different tenants,
which boots cleanly and then refuses every administrator. Compare both values in the boot log — see
[Configuration](../reference/configuration.md).

## Webhook posts stopped working

Check the boot log for `No webhook token signing keyset found`. Until the keyset exists, webhook
authentication recognises nobody while everything else works normally.

Otherwise the token has expired or been revoked. `just token list` shows both.

## Where the durable record lives

Failed jobs are persisted, so the console's watchlist and failure list survive a restart and do not
depend on Slack being configured.

#icicle-insights# #How-To# #Administrator# #Developer# #troubleshooting#
