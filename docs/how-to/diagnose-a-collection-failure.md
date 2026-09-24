# Diagnose a collection failure

How to work out why a resource stopped updating and get it collecting again. For administrators
answering an alert or noticing a flat chart.

## 1. Find the failure

1. Open the admin console at **Operations**.
2. Check the **Scheduler** card. If it says *Stale — no recent heartbeat* or *Not seen yet*, nothing
   is being queued. Restart the scheduler process and stop here.
3. Check **Waiting on "metrics"**. A number that keeps growing means no worker is running. Restart
   the `queues` process and stop here.
4. Read **Recent failures**. Each row names the job, the account and resource, and an identifier.

## 2. Match the identifier

| Identifier | Most likely cause | What to do |
|---|---|---|
| `missing_token` | No credential stored for the account | [Track a new account](track-a-new-account.md), step 2 |
| `api_request_failed` 401 or 403 | Platform token expired or lacks access | [Replace a platform token](replace-a-platform-token.md) |
| `api_request_failed` 404 | Resource renamed, deleted or made private | Fix its name, or delete the resource |
| `api_request_failed` 5xx or 429 | The platform is having a bad day | Nothing; it re-books itself |
| `tapis_request_failed` 401, on every account | `TAPIS_TOKEN` expired | [Renew the Tapis service token](renew-the-tapis-token.md) |
| `tapis_secret_not_found` | The vault entry points at a secret that is gone | Replace the token for that account |
| `page_layout_changed` | GitHub changed its package page | A developer updates `GHCRPackagePage` |
| `decoding_failed` | The platform changed its API response | A developer updates the collector |

The full list is in [Collection failures](../reference/collection-failures.md).

## 3. Confirm the fix

Failures re-book themselves within 1 to 12 hours, and credential failures within 1 hour. To try
straight away, see [Collect now](collect-now.md).

Then check the resource's page on the public dashboard. **Last reading** in the tables, or the
readings on the console's **Metrics** page, should show today.

## A resource that is never collected

If **Resources** in the console shows **Next collection** as *Not scheduled*, the sweep will never
pick it up. That is expected for npm and PyPI, which are not collected. For any other platform,
editing the resource does not change it. Book it as described in [Collect now](collect-now.md),
under *Resources that are not scheduled*.

## GitHub gaps past 14 days

An alert saying the collection gap has passed the retention window means some GitHub traffic days
are gone. They cannot be recovered. Fix the cause so no more are lost.

#icicle-insights# #How-To# #Administrator#
