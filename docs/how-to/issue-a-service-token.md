# Issue a service token

How to let a deployed ICICLE service report its own metrics, such as how many users authenticated.
For administrators signed in to the console, and developers wiring up the service.

A service token can write readings for one resource and nothing else.

## 1. Register the service

1. Open **Resources** and click **Add resource**.
2. Choose an account, name the service and set **Kind** to *service*.

**Issue token** stays disabled until at least one *service* resource exists.

## 2. Issue the token

1. Open **Service tokens** and click **Issue token**.
2. Choose the **Service**.
3. Type a **Deployment label**, such as *prod pod* or *staging*.
4. Set **Lifetime in days**, from 1 to 365. The default is 90.
5. Click **Issue token**, then **Copy token**.
6. Store it in the service's own secret store. It is not shown again.

Issuing a token for a service revokes that service's previous token.

## 3. Post readings from the service

```bash
curl -X POST "https://insights.pods.icicleai.tapis.io/api/resources/$RESOURCE_ID/metrics" \
  -H "Authorization: Bearer $INSIGHTS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reading": 42, "type": "authentications"}'
```

- `type` is any metric id except the lifetime ones. See [Metrics](../reference/metrics.md).
- A `201` response returns the stored reading.
- Retrying a request records the reading twice. Deduplicate in the service before posting.
- The limit is 60 requests a minute per token. Beyond it the answer is `429` with `Retry-After`.

## Check it worked

The token's row shows **Status** *Active*. The service's readings appear on the **Metrics** page.

## When it expires

Insights alerts 14, 7, 3 and 1 days before expiry. Issue a new token and update the service before
then. To withdraw one early, choose **Revoke token** in its row menu. The service gets `401` from its
next request.

#icicle-insights# #How-To# #Administrator# #Developer#
