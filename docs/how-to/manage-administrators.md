# Manage administrators

Grant and revoke administrator access. For administrators.

## Grant access

1. Open **Administration → Administrators**.
2. Select **Add administrator**.
3. Enter the person's **Tapis username**, not their email address.
4. Save.

They hold access on their next request. They do not need to sign in again.

The username must exist in the tenant this deployment is configured for. A username that does not
match anything is accepted and simply never matches, so check the spelling with them.

## Revoke access

1. Open **Administration → Administrators**.
2. Select **Remove** on their row.

Revocation takes effect on the **next request**. Admin status is resolved once per authenticated
request, so there is no cache to wait out and no restart needed.

## The root administrator

One row shows **Protected root** and offers no Remove action. That is `ROOT_ADMIN_USERNAME` from the
environment.

It holds access whatever the table says, and cannot be removed through the API. That is deliberate:
administrators are managed from this screen, so deleting the last row would otherwise lock everyone
out of the screen needed to fix it.

To change who the root is, set `ROOT_ADMIN_USERNAME` in the environment and restart.

## Confirm it worked

The Operations screen's **Administrator context** panel reports the current count, including how
many are root.

## Troubleshooting

**They still cannot see the Administration tab.** Their client may be holding a stale view. Ask
them to reload. If it persists, confirm the username matches their Tapis username exactly.

**Nobody can administer anything.** Sign in as the root administrator. If that also fails,
`ROOT_ADMIN_USERNAME` does not match a real username in the tenant — check the boot log's
`Root admin resolved.` line.

## Notes

- Administrators hold full access: every write, every vault route, every token route.
- There are no partial roles. Someone is an administrator or they are not.
- Grants are recorded with who made them and when, visible on this screen.

#icicle-insights# #How-To# #Administrator# #access#
