# Deploy Insights

How to run Insights on a cluster or server from the published image, for administrators who run the
deployment. [Architecture](../explanation/architecture.md) explains the moving parts.

## Before you start

- PostgreSQL and a Redis-protocol server such as Valkey, reachable from the pods.
- A Tapis service user on the tenant, with a token, for Tapis Vault.
- The image `ghcr.io/icicle-ai/insights`. CI publishes `:latest` and `:<commit sha>` on every push
  to `main` or `dev`.

## Steps

1. Set the environment for all three processes. The five with no default are `TAPIS_BASE_URL`,
   `TAPIS_TENANT`, `TAPIS_TOKEN`, `TAPIS_USER` and `ROOT_ADMIN_USERNAME`. Also set the `DATABASE_*`
   and `REDIS_*` values. The image already sets `VAPOR_ENV=production`. Every variable is in
   [Configuration](../reference/configuration.md).
2. Run three workloads from the same image, with these arguments:

   | Workload | Arguments | Replicas |
   |---|---|---|
   | API and dashboard | `serve` | 1 or more |
   | Queue worker | `queues --queue metrics` | 1 or more |
   | Scheduler | `queues --scheduled` | **Exactly 1** |

3. Expose port 8080 of the API only, behind TLS. Keep the database and Valkey private.
4. Point probes at the API: liveness `GET /health`, readiness `GET /ready`.
5. Start the API. It applies database migrations before serving, under a lock, so several replicas
   can start together.
6. Once only, create the signing keyset for service tokens, then restart the API:

   ```bash
   ./Insights service-token init-key
   ```

7. To embed in TapisUI, set `FRAME_ANCESTORS` on the API. See
   [Embed the dashboard in TapisUI](embed-in-tapisui.md).

## Check it worked

The API's startup log contains, in order:

- *Secret provider selected.* with the tenant, base URL and `tapis_token_expires_at`
- *Root admin resolved.*
- *Tapis tenant public key loaded; admin tokens verify locally.*
- *Webhook token signing keys loaded.* A critical line naming `service-token init-key` instead
  means step 6 is still to do.
- *Insights configured.* with `environment` `production`

Then open `/admin`, sign in as the root administrator, and check **Operations → Scheduler** says
**Healthy** within the hour.

## Updating

Deploy a new image tag to all three workloads. Migrations run when the new API starts.

#icicle-insights# #How-To# #Administrator# #Developer#
