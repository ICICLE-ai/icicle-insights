# Get admin access

Sign in and gain administrator rights. For administrators.

## Sign in

1. Open the Insights dashboard.
2. Sign in to Tapis in the same browser, on the same tenant the deployment is configured for.
3. Return to the dashboard.

An **ADMIN** chip and an **Administration** tab appear in the header once you hold access. Without
them you see the public dashboard, which is the correct view for everyone else.

When the dashboard is embedded in another application, the parent hands the token over
automatically. Nothing to do.

## Get rights granted

Administrator access is not automatic. Someone who already holds it adds you from the
Administrators screen — see [Manage administrators](manage-administrators.md).

Give them your **Tapis username**, not your email.

## If you are the first administrator

The first administrator comes from the environment, not the database.

1. Set `ROOT_ADMIN_USERNAME` to a real Tapis username in the configured tenant.
2. Restart the service.

That username holds access whatever the table says, and cannot be removed through the API. It is
the recovery path if the administrator list is ever emptied.

## Troubleshooting

**Signed in, but no Administration tab.**
You authenticated but hold no rights. Ask an existing administrator to add you.

**Every write returns 403, including yours as root.**
`ROOT_ADMIN_USERNAME` probably does not match a real username in the tenant. A placeholder boots
perfectly well and matches nobody. Check the boot log line `Root admin resolved.` against your
actual Tapis username.

**Everything returns 403 for everyone.**
`TAPIS_BASE_URL` and `TAPIS_TENANT` are likely naming different tenants. The pair boots cleanly and
then refuses every administrator. Compare the two values in the boot log — see
[Configuration](../reference/configuration.md).

**Access worked yesterday and not today.**
Tapis tokens are short-lived. Sign in again.

#icicle-insights# #How-To# #Administrator# #access#
