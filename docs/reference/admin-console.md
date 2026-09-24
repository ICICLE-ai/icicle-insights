# Admin console

Every screen in the console, and what each one shows. For administrators.

The console lives at `/admin`, with its sections in a sidebar. Signing in asks the API whether the
token's holder is an administrator; the answer is never inferred from the token itself.

| Sign-in message | Means |
|---|---|
| This token did not verify | Expired, malformed, or from another Tapis tenant (401) |
| Signed in but is not an administrator | A valid Tapis user without admin rights (403) |

Every table has one actions menu (`…`) per row. An action that cannot run says why in the menu.
Create and edit open a side sheet; a failed request keeps the sheet open with the server's reason.

## Operations

`/admin` — the landing screen. Read it first when something looks wrong.

| Section | Shows |
|---|---|
| Waiting | Jobs queued on `metrics` |
| In progress | Jobs a worker has claimed |
| Scheduler | Healthy, Stale, Not seen yet, or Valkey unreachable, with the last heartbeat |
| Recent failures | The 50 newest exhausted jobs: severity, subject, job, cause, and when. Select a cause for its details |
| Watermarks | How far each rolling metric has been counted into its all-time total, oldest first |

A Stale scheduler is the first sign collection has stopped. "Not seen yet" is normal on a new
deployment until the scheduler's first run.

## Accounts

`/admin/accounts` — platform accounts. Each owns resources and at most one vault credential.

| Column | Meaning |
|---|---|
| Account | Name on the platform |
| Platform | GitHub, Hugging Face, Patra, GHCR, npm, or PyPI |
| Resources | How many resources this account owns |
| Credential | Whether a vault credential is stored |
| Added | When the account was registered |

**Delete** is offered only once the account has no resources and no credential. See
[Register an account](../how-to/register-an-account.md).

## Resources

`/admin/resources` — what is collected, filterable by name, kind or account.

| Column | Meaning |
|---|---|
| Resource | Name on the platform, stored lowercase |
| Kind | Agent, container, dataset, model, package, repository, or service |
| Account | Owning account and its platform |
| Cadence | Days between collections. Default 7 |
| Next collection | When it next becomes due |

Cadence is capped per platform: 7 days on GitHub, 30 elsewhere. Editing cannot move a resource to
another account. See [Collection schedule](collection-schedule.md) and
[Add a resource](../how-to/add-a-resource.md).

## Releases

`/admin/releases` — published versions, recorded to the month. Add, edit, or delete.

## Metrics

`/admin/metrics` — the 100 newest readings.

| Action | Effect on the all-time total |
|---|---|
| Record reading | Adds the reading |
| Correct reading | Moves the total by the difference |
| Delete reading | Takes the reading back out |

All-time rows cannot be recorded or corrected, only deleted. Collection then rebuilds the total
from the next uncounted day, not from the beginning.

## Vaults

`/admin/vaults` — platform credentials, by metadata only.

| Column | Meaning |
|---|---|
| Account | Which account uses it |
| Secret name | The secret's name in Tapis Vault |
| Expires | The expiry you recorded. Marked within 14 days, and once past |

Adding asks for the account, the token, and its expiry date. Only accounts without a credential
are offered. **Replace token** writes a new value and expiry. **Secret values are never returned
to this screen.**

## Service tokens

`/admin/service-tokens` — write access for deployed services.

| Column | Meaning |
|---|---|
| Label | Where the token is deployed |
| Service | The one resource it may report for |
| Status | Active, Revoked, or Expired |
| Expires | When it stops working |

**Issue token** asks for a resource of kind Service, a label, and a lifetime of 1 to 365 days
(default 90). The token is shown once, with the endpoint to post to. **Rotate signing key** adds a
key; existing tokens keep working. See [Issue a service token](../how-to/issue-a-service-token.md).

## Administrators

`/admin/administrators` — who holds administrator access.

| Column | Meaning |
|---|---|
| Username | Tapis username. The root is marked Root |
| Added by | Who granted it, or Deployment environment for the root |
| Since | When it was granted |

The root comes from `ROOT_ADMIN_USERNAME` and cannot be removed here. Removal takes effect on the
next request. See [Manage administrators](../how-to/manage-administrators.md).

## Public dashboard

`/` and its sibling pages — what an anonymous visitor sees. Filters in the header apply to every
page and live in the URL, so any view can be shared as a link.

| Page | Shows |
|---|---|
| Overview | Metric tiles with change and trend, a chart of the selected metric by platform, catalog mix, and the resources reporting it |
| Resources | Every resource in scope, sortable, with change over the range |
| Resource | One resource: tiles, a chart per metric, releases, and the same artifact on other registries |
| Releases | Releases per month and the newest releases |
| Provenance | Artifacts Patra recorded under more than one registry |

#icicle-insights# #Reference# #Administrator# #console#
