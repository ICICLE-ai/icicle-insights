# Run Insights locally

A first run of the whole system on your own machine, for developers. By the end you will have the
API, the dashboard with seeded data, and the admin console running, and the tests passing. Allow
about 30 minutes, most of it for the first Swift build.

## What you need

- macOS or Linux with Swift 6.3 (`swift --version`)
- [Deno](https://deno.com) 2.9 and [just](https://just.systems)
- Docker with Compose, or Apple Container on macOS 26
- A Tapis account on the **staging** tenant, `icicleai.staging.tapis.io`, and a token for it

Staging matters. Its Tapis Vault is separate from production's, so nothing you do locally can touch
production credentials.

## 1. Start PostgreSQL and Valkey

With Docker:

```bash
docker compose up -d db valkey
```

With Apple Container, register the local DNS domain once per machine, then start both:

```bash
just dns
just db valkey
```

**Checkpoint:** port 5432 and port 6379 accept connections on `localhost`.

## 2. Configure the environment

```bash
cp .env.example .env
echo 'DATABASE_TLS=disable' >> .env
```

Then edit `.env` and fill in:

| Variable | Value |
|---|---|
| `TAPIS_TOKEN` | Your staging token |
| `TAPIS_USER` | Your staging username |
| `ROOT_ADMIN_USERNAME` | Your staging username again, so you can use the admin console |

Leave `TAPIS_BASE_URL` on staging and `VAPOR_ENV=development`. Development adds seed data: ICICLE's
real accounts, resources and a July 2026 snapshot of their figures.

## 3. Create the database and start the API

```bash
just migrate
just run
```

The first build takes several minutes. When it finishes, the log ends with *Insights configured.*

**Checkpoint:** in another terminal, `curl http://127.0.0.1:8080/health` answers `{"status":"ok"}`.
<http://127.0.0.1:8080/docs> shows the API reference.

## 4. Start the dashboard

```bash
just web-install
just web
```

Open <http://localhost:5174>. The overview shows the seeded accounts and resources. Most charts have
a single point, because the seed is one snapshot.

**Checkpoint:** the **Models** page lists Patra model cards.

## 5. Open the admin console

1. Click **Admin** in the dashboard header.
2. Paste your staging token and click **Sign in**.
3. The console opens at **Operations**. You are the root administrator.

The **Scheduler** card says *Not seen yet*, because no scheduler is running. That is expected.

## 6. Collect something (optional)

Collection runs in separate processes. Start a worker, then queue every resource:

```bash
swift run Insights queues --queue metrics
```

```bash
just collect --force
```

Seeded resources have no due date, so `--force` is needed the first time. GHCR and Patra collect
without credentials. GitHub and Hugging Face fail with `missing_token` until you store a token under
**Vaults**. Watch both in the console under **Operations** and **Metrics**.

## 7. Run the tests

Create the `test` database once, then run both suites. The Apple Container equivalent of
`docker compose exec db` is `container exec db`.

```bash
docker compose exec db psql -U vapor_username -d vapor_database -c 'CREATE DATABASE test'
just test
just web-check
just web-test
```

**Checkpoint:** every suite passes.

## Where to go next

- [Architecture](../explanation/architecture.md) for how the processes fit together
- [Develop the dashboard](../how-to/develop-the-dashboard.md) for frontend work
- [Add a collector](../how-to/add-a-collector.md) for a new platform
- [Commands](../reference/commands.md) for every `just` recipe

#icicle-insights# #Tutorial# #Developer#
