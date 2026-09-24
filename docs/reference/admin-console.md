# Admin console reference

Every page, form and row action in the admin console at `/admin`, for administrators. Each page
lists what it shows and what each control changes.

## Sign-in and layout

| Part | Contents |
|---|---|
| Sign-in screen | Shown until a token proves its holder is an administrator. A **Tapis token** box, **Sign in**, and **Clear token** once a token is held |
| Refusal messages | *This token did not verify…* for an expired or foreign token. *…is signed in but is not an administrator of this deployment* for a valid non-admin |
| Sidebar | **Operations**, **Accounts**, **Resources**, **Releases**, **Metrics**, **Vaults**, **Service tokens**, **Administrators** |
| Sidebar footer | Your username, **Token expires in …**, **Sign out** |
| **← Public dashboard** | Returns to the public screens |

The token is held in memory only. Reloading the page forgets it unless TapisUI supplies it again.

## Operations

*Queue health, recent failures and collection progress.* **Refresh** reloads every card.

| Card | Shows |
|---|---|
| **Waiting on "metrics"** | Jobs queued and not yet picked up |
| **In progress** | Jobs a worker is running now |
| **Scheduler** | **Healthy**, *Stale — no recent heartbeat* after 2 hours of silence, or *Not seen yet*. Plus **Last seen** |
| **Recent failures** | Collections that used up their retries, newest first. *No failures recorded.* when empty |
| **Watermarks** | Per resource and metric: the last day folded into the all-time total (**Counted through**) |

## Accounts

*One per organisation or user on each platform.* Columns: **Account**, **Platform**, **Resources**,
**Credential** (*Stored in vault* or —), **Added**.

| Control | Fields or effect |
|---|---|
| **Add account** | **Platform**: GitHub, Hugging Face, Patra, GHCR, npm, PyPI. **Name**: exactly as the platform spells it |
| **Delete account** | Blocked with *Delete its N resources first* or *Delete its vault credential first*. Collected history stays in the database |

## Resources

*N resources under collection.* A filter box matches name, kind or account. Columns: **Resource**,
**Kind**, **Account**, **Cadence**, **Next collection** (*in N days* or *Not scheduled*).

| Control | Fields or effect |
|---|---|
| **Add resource** | **Account**, **Name** (as in its URL, stored lowercase), **Kind**, **Collect every (days)**. Collected right away, then on the cadence. Disabled until an account exists |
| **Edit** | **Name**, **Kind**, **Collect every (days)**. Moving to another account means deleting and re-adding |
| **Delete resource** | Collection stops and it leaves the dashboard. History stays in the database |

Kinds: agent, container, dataset, model, package, repository, service. The cadence limit shows
under the field, for example *1 to 7 days on github*.

## Releases

*N releases recorded.* Filter by resource or version. Columns: **Resource**, **Version**,
**Released** (month and year).

| Control | Fields or effect |
|---|---|
| **Add release** | **Resource**, **Version**, **Month**, **Year** (defaults to this month) |
| **Edit** | The same fields |
| **Delete release** | Removed from the catalog and the release charts |

## Metrics

*The 100 newest readings. Manual changes also adjust the matching all-time total.* Columns:
**Resource**, **Metric**, **Reading**, **Recorded**.

| Control | Fields or effect |
|---|---|
| **Record reading** | **Resource**, **Metric**, **Reading** (0 or more). Also added to the all-time total |
| **Correct reading** | **Reading**. The all-time total moves by the difference. Blocked on lifetime rows: *All-time totals are derived by the server* |
| **Delete reading** | Taken back out of its all-time total. On a lifetime row, resets the total instead |

## Vaults

*One platform token per account, stored in Tapis Vault.* Columns: **Account**, **Secret name**,
**Expires**. Secret names follow `insights-{platform}-{account}`.

| Control | Fields or effect |
|---|---|
| **Add credential** | **Account** (only those without one), **Token** (hidden), **Expires on**. Never shown again |
| **Replace token** | **Token**, **Expires on** |
| **Delete credential** | Destroys every version of the secret. Collection for the account stops |

## Service tokens

*Let a deployed service post metrics for its own resource.* Columns: **Label**, **Service**,
**Status** (*Active*, *Expired* or *Revoked …*), **Expires**.

| Control | Fields or effect |
|---|---|
| **Issue token** | **Service** (a resource of kind *service*), **Deployment label**, **Lifetime in days** (1–365, default 90). The token is shown once with **Copy token**. Disabled until a service resource exists |
| **Revoke token** | The service gets 401 on its next request. Blocked with *Already inactive* |
| **Rotate signing key** | New tokens use a new key. Existing tokens keep working until they expire |

Issuing a token for a service revokes its previous one.

## Administrators

*Tapis users who can manage the catalog, credentials and tokens.* Columns: **Username**, **Added
by**, **Since**. The root administrator is marked **Root**, and you are marked **(you)**.

| Control | Fields or effect |
|---|---|
| **Add administrator** | **Tapis username** on this deployment's tenant. Applies from their next request |
| **Remove access** | Blocked for the root administrator: *Set by ROOT_ADMIN_USERNAME* |

#icicle-insights# #Reference# #Administrator#
