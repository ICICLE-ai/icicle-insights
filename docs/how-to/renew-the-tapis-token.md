# Renew the Tapis service token

How to replace `TAPIS_TOKEN`, the credential the deployment uses to read Tapis Vault. For
administrators with access to the deployment's configuration.

Every platform token lives in Tapis Vault. When `TAPIS_TOKEN` expires, every vault read fails and
collection stops for every GitHub and Hugging Face account at once. Nothing renews it
automatically.

## Know when it expires

- Every process logs it at startup: *Secret provider selected.* with `tapis_token_expires_at`.
- The scheduler alerts 7, 3, 1 and 0 days before it expires, at 07:00.
- After expiry, collections fail with `tapis_request_failed` and a 401.

## Steps

1. Get a new Tapis token for the service user named in `TAPIS_USER`, on the tenant in
   `TAPIS_TENANT`.
2. Update `TAPIS_TOKEN` wherever the deployment keeps its secrets.
3. Restart all three processes: the API, the `queues` worker and the scheduler. Each reads the value
   only at startup.
4. Queue the resources that failed:

   ```bash
   ./Insights collect-resources
   ```

## Check it worked

- The startup log shows the new `tapis_token_expires_at`, with no *TAPIS_TOKEN has already
  expired* line.
- In the admin console, **Vaults** lists the credentials. That page reads the database, not
  Tapis, so also check that **Operations → Recent failures** gains no new `tapis_` rows.

## Keep the tenant consistent

`TAPIS_BASE_URL` and `TAPIS_TENANT` must name the same tenant as the token. A mismatch starts
cleanly, then refuses every administrator with a bare 403. See
[Configuration](../reference/configuration.md).

#icicle-insights# #How-To# #Administrator#
