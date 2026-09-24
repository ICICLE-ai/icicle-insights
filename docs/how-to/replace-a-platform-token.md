# Replace a platform token

How to swap the GitHub or Hugging Face token an account is read with, before it expires or after it
stops working. For administrators signed in to the console.

Insights does not warn before a platform token expires. The first sign is a `missing_token` or
`api_request_failed` 401/403 alert once collection has already failed. Check the **Expires** column
on **Vaults** from time to time.

## Steps

1. Create a new read-only token on the platform. For GitHub, give it push access to the tracked
   repositories so the traffic figures can be read.
2. Open **Vaults**.
3. Open the **⋯** menu on the account's row and choose **Replace token**.
4. Paste the new **Token** and set **Expires on** to its expiry date.
5. Click **Replace token**.
6. Revoke the old token on the platform.

## Check it worked

- The row's **Expires** shows the new date.
- Failed resources are retried within an hour of the failure. They leave **Operations → Recent
  failures** only as new failures replace them, so check each resource's **Next collection** and
  its readings on the **Metrics** page instead.

To collect at once rather than wait, see [Collect now](collect-now.md).

## Remove a credential instead

**Delete credential** destroys every version of the secret in Tapis Vault. Collection for that
account stops until a new token is stored. An account cannot be deleted while it still has one.

## This is not the Tapis token

Every vault read also depends on the deployment's own `TAPIS_TOKEN`. When that one expires, all
accounts fail at once. See [Renew the Tapis service token](renew-the-tapis-token.md).

#icicle-insights# #How-To# #Administrator#
