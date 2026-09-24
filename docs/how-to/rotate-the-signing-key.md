# Rotate the signing key

How to change the key that service tokens are signed with, for administrators. Rotate after a
suspected leak, or on a schedule you choose.

Rotation adds a new key and keeps the old ones. Tokens already issued keep working until they
expire. Deployed services need no change.

## From the console

1. Open **Service tokens**.
2. Click **Rotate signing key**.
3. Confirm with **Rotate key**.

The running API starts signing with the new key at once.

## From a terminal

Run this where the deployment's environment is available:

```bash
./Insights service-token rotate-key
```

Restart the API afterwards. A running API keeps the keyset it loaded at startup until it restarts.

## If a token has leaked

Rotation alone does not stop a leaked token, because the old key still verifies it. Revoke that
token as well: open its row menu on **Service tokens** and choose **Revoke token**.

## Starting over

`service-token init-key --force` discards the whole keyset. Every token ever issued stops working at
once, and every service needs a new one. Use it only when that is what you want.

## Check it worked

The API log line *Webhook token signing keys loaded.* shows a new `active_kid` after the restart.

#icicle-insights# #How-To# #Administrator#
