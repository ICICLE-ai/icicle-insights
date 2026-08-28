# Add a resource

Put a repository, model, or dataset under collection. For administrators.

Its account must exist first — see [Register an account](register-an-account.md).

## Steps

1. Open **Administration → Catalog → Resources**.
2. Select **Add resource**.
3. Enter the resource name or path exactly as the platform spells it. Some platforms namespace
   theirs, so use whatever appears in the resource's own URL.
4. Choose the owning account.
5. Choose the kind: agent, container, dataset, model, package, repository, or service.
6. Set the cadence in days, or leave the default of 7.
7. Save.

The resource is collected immediately rather than waiting up to an hour for the next sweep, and its
next collection is booked from now.

A name that already exists for that account and kind is rejected as a conflict.

## Choosing a cadence

Cadence is the spacing between successful collections, not a guarantee of when one happens.

| Platform | Maximum |
|---|---|
| GitHub | 7 days |
| Hugging Face | 30 days |
| GHCR, npm, PyPI | 30 days |
| Patra | 30 days |

The form enforces each cap. See [Collection schedule](../reference/collection-schedule.md) for why
GitHub's is set where it is.

Seven days is the right default. Going faster costs API allowance without adding history, because
daily values are only counted once they complete.

## Choosing a kind

Kind describes what the thing is. It does **not** decide which API collects it — that comes from
the account's registry.

Choose **service** only for a deployed service that will report its own metrics. It is the only
kind that can be issued a service token.

Choose **agent** for an ICICLE AI agent. It can be registered, but nothing collects it yet —
Patra's API does not publish agents today.

## Confirm it worked

The Resources screen shows the resource with a **Next collection** date about one cadence away.

To see readings sooner, run a collection now — see
[Run collection immediately](run-collection-immediately.md).

## Notes

- Changing the cadence does **not** make a resource due. It sets the spacing applied after the next
  successful collection.
- A `Not set` next-collection date means the resource is never swept. That is the correct state for
  a platform with no collector yet.
- GHCR, npm, and PyPI resources are registered and re-booked, but skipped by the dispatcher until a
  collector exists for them.
- Deleting a resource deletes its readings, releases, and watermarks.

#icicle-insights# #How-To# #Administrator# #catalog#
