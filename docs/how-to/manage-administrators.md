# Manage administrators

How to give someone access to the admin console, or take it away. For administrators signed in to
the console.

## Add an administrator

1. Find their Tapis username on the `icicleai` tenant. It is the name TapisUI shows for them, not
   their email address, unless their username is an email address.
2. Open **Administrators** and click **Add administrator**.
3. Type the **Tapis username** and click **Add administrator**.

Access applies from their next request. They sign in as in
[Sign in as an administrator](sign-in-as-an-administrator.md).

## Remove an administrator

1. Open the **⋯** menu on their row and choose **Remove access**.
2. Confirm with **Remove access**.

Their next request is refused.

## The root administrator

The row marked **Root** is set by the deployment's `ROOT_ADMIN_USERNAME` variable. It cannot be
removed from the console; its menu says *Set by ROOT_ADMIN_USERNAME*. It exists so that removing the
last administrator by mistake can always be undone.

To change it, change the variable and restart the deployment. See
[Configuration](../reference/configuration.md).

## Check it worked

The list shows the username, **Added by** with your name, and **Since** with today's date.

#icicle-insights# #How-To# #Administrator#
