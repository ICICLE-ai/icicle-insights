# Sign in as an administrator

How to open the admin console, for administrators. You need a Tapis account on the `icicleai`
tenant that has been added as an administrator.

## From TapisUI (recommended)

1. Sign in at <https://icicleai.tapis.io>.
2. In the sidebar, open **ICICLE Services → Insights**.
3. Check the dashboard header. It shows your username where it otherwise says **Admin**.
4. Click your username. The admin console opens at **Operations**.

TapisUI hands the dashboard your token, so there is nothing to paste.

## On the standalone site

If you are signed in to TapisUI in the same browser, there is nothing to do. The dashboard reads
TapisUI's `X-Tapis-Token` cookie, and its header shows your username. Click it.

Otherwise, paste a token:

1. Open <https://insights.pods.icicleai.tapis.io/admin>.
2. Paste a Tapis access token for the `icicleai` tenant into **Tapis token**.
3. Click **Sign in**.

A pasted token stays in the page's memory only. Reloading the page forgets it.

## Check it worked

The sidebar footer shows your username and **Token expires in …**. Tapis tokens last a few hours.
When yours lapses, the console asks you to sign in again.

## If you are refused

| Message | Cause | Fix |
|---|---|---|
| *This token did not verify. It may have expired or come from another Tapis tenant.* | Expired token, or one from another tenant | Get a fresh token from the `icicleai` tenant |
| *… is signed in but is not an administrator of this deployment.* | You are not on the administrator list | Ask an administrator to [add you](manage-administrators.md) |

## Sign out

Click **Sign out** in the sidebar footer. If the TapisUI cookie is still present, reloading signs you
back in; sign out of TapisUI to end the session everywhere.

Related: [Access and sign-in](../explanation/access-and-sign-in.md) explains how the console
decides who is an administrator.

#icicle-insights# #How-To# #Administrator#
