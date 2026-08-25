# Issue a service token

Let a deployed service post its own metrics. For administrators.

A service token authorises one deployed service to write metrics for exactly one resource. It
grants nothing else.

## Prerequisites

- A resource of kind **service** exists. No other kind can be issued a token.
- The signing keyset exists. If it does not, see [Deploy Insights](deploy-insights.md); the boot log
  says so at `critical` and minting returns an error naming the command.

## From the console

1. Open **Administration → Service tokens**.
2. Select **Mint token**.
3. Choose the service resource.
4. Enter a label naming the deployment, such as `prod-inference`.
5. Set the lifetime in days, or leave the default of 90.
6. Select **Mint**.

**Copy the token now.** It is shown exactly once. Nothing stores it and no screen reads it back.

## From the command line

```bash
just token issue --resource <uuid> --label prod-inference
```

The resource identifier is on the Catalog → Resources screen.

## Configure the service

The service needs two values, named however it already names its own configuration. Insights
defines no variable names for this.

| Value | What it is |
|---|---|
| Endpoint | `https://<your-host>/api/resources/<uuid>/metrics` |
| Token | The value you just copied |

It posts readings to that endpoint with the token as a bearer credential:

```
Authorization: Bearer <token>
```

It needs no Tapis identity and no vault access.

## Confirm it worked

The token appears on the Service tokens screen with the expiry you chose. Have the service post
one reading and check it arrives on Catalog → Metrics.

## Revoking

```bash
just token revoke --jti <uuid>
```

Or use the console. Revocation takes effect on the **next request** — there is no cache and no
restart.

Revoked rows stay visible as an audit trail.

## Replacing a lost token

Mint a new one for the same resource. Minting revokes any live token for that resource in the same
transaction, so there is always exactly one working credential per resource.

A lost token cannot be recovered. Nothing persists the value.

## Expiry

Tokens expire after their chosen lifetime, which defaults to 90 days and may be 1 to 365. A daily
sweep warns at 14, 7, 3, and 1 days remaining, escalating to critical at three days or fewer.

Warnings go wherever failure alerting points. With no Slack webhook configured they are log lines.
`just token list` shows expiry dates directly.

Replace an expiring token by minting a new one and updating the deployment's secret. Tokens cannot
renew themselves: a leaked token that could renew itself would never expire, which removes the only
thing expiry buys.

## Notes

- The resource binding and the expiry live inside the signature. The holder cannot widen either.
- A service token can never mint another, and cannot reach any admin route.
- Deletes are administrator-only everywhere. A malfunctioning service can at worst write bad rows,
  never remove history.

#icicle-insights# #How-To# #Administrator# #credentials#
