# Local development

From a clone to a running stack with the tests passing. For developers.

By the end you will have the API, the dashboard, and the test suite all running locally.

## What you need

| Tool | Why |
|---|---|
| Swift 6.3+ | The service |
| Node.js 24+ | The dashboard |
| [`just`](https://just.systems/) | Every command below |
| macOS 26+ and Apple Container | The container stack. Optional |
| Tapis staging credentials | Vault reads |

## 1. Configure

```bash
cp .env.example .env
```

Open `.env` and set at least these:

```dotenv
TAPIS_BASE_URL=https://icicleai.staging.tapis.io/v3
TAPIS_TENANT=icicleai
TAPIS_USER=your-service-user
TAPIS_TOKEN=replace-me
ROOT_ADMIN_USERNAME=your-tapis-username
DATABASE_TLS=disable
```

**Use staging, never production.** It is a separate vault, so nothing you do locally touches
production credentials.

Two of these bite:

- `TAPIS_BASE_URL` and `TAPIS_TENANT` must name the **same** tenant, and the `/v3` suffix is
  required. Get the pair wrong and the service boots cleanly, then refuses every administrator with
  a bare 403.
- `DATABASE_TLS=disable` is required locally. The stock PostgreSQL container serves no TLS, and
  without this every connection fails.

`.env` is gitignored. It is the only place credentials belong.

## 2. Start the backing services

```bash
container system start
```

```bash
just dns
```

`just dns` is needed **once per machine**. It registers a local DNS domain so containers can find
each other by name. It asks for an administrator password and restarts the container service.

```bash
just db
```

```bash
just valkey
```

Each waits until the service actually accepts connections before returning.

## 3. Run the API

```bash
just migrate
```

```bash
just run
```

Open http://127.0.0.1:8080/health — it should return a healthy response.

| URL | Serves |
|---|---|
| http://127.0.0.1:8080/docs | Browsable API reference |
| http://127.0.0.1:8080/openapi.json | The generated OpenAPI document |
| http://127.0.0.1:8080/health | Liveness |
| http://127.0.0.1:8080/ready | Readiness: PostgreSQL and Valkey |

Because `VAPOR_ENV` is unset, you are in development. That means two things: the database is `dev`,
and a seed migration has populated it with real ICICLE figures so the dashboard has something to
render.

## 4. Run the dashboard

In a second terminal:

```bash
just web-install
```

```bash
just web
```

Open http://localhost:4200.

The dev server proxies `/api` to port 8080, so browser requests are same-origin and no CORS
configuration is needed. Hot reload works.

The dashboard renders fully for an anonymous visitor. Administration features are progressive
enhancement, which is why signing out does not break it.

## 5. Run the tests

```bash
just test
```

195 tests across 15 suites, and it takes a few minutes because it runs serially.

Serial is required, not a performance oversight. Every suite shares the `test` database and migrates
and reverts around itself, so any overlap has one suite reverting the schema out from under another.

Note the database: tests always use `test`, never `dev`. A stray run cannot clobber your seed data.

If the whole suite fails in setup rather than in a test, `.env` is missing or `DATABASE_TLS` is not
`disable`. See [Run the tests](../how-to/run-the-tests.md).

## 6. Try the full container stack

The native loop above is faster for day-to-day work. The container stack is what a deployment
actually runs.

```bash
just stack
```

This builds the image, then starts PostgreSQL, Valkey, the migrator, the API, a queue worker, and
the scheduler, in dependency order.

Once it settles:

```bash
container list
```

Five containers: `db`, `valkey`, `app`, `queues`, `scheduled`. The dashboard is on
http://127.0.0.1:8080.

Those names match the services in `docker-compose.yml` exactly, so the two files describe the same
stack.

To stop without losing data:

```bash
just stop
```

## 7. Collect something

```bash
just collect --force
```

This marks every resource due and dispatches collection.

It only *enqueues*. The `queues` worker does the collecting, so watch it:

```bash
container logs -f queues
```

That split is the core of the design: the scheduler stays cheap, and throughput scales by adding
workers.

## What to remember

**Three processes, and only one of them can be duplicated safely.** `serve` and
`queues --queue metrics` scale freely. `queues --scheduled` must be exactly one, or every due
resource is dispatched twice.

**Never pass `--env` on a command line.** It outranks `VAPOR_ENV`, which is how a stack ends up with
processes disagreeing about their own environment.

**Format before committing.**

```bash
just fmt
```

**Some things only fail on a real boot.** The testing environment skips the Tapis tenant key fetch
and the vault keyset read. Two real bugs hid there. Verify changes on those paths against staging.

## Next

| To | Read |
|---|---|
| Understand the shape of the system | [Architecture](../explanation/architecture.md) |
| Know what you must not break | [Invariants](../reference/invariants.md) |
| Set up the Angular tooling | [Set up the dashboard toolchain](../how-to/set-up-the-dashboard-toolchain.md) |
| Add a platform collector | [Add a collector](../how-to/add-a-collector.md) |
| Look up a recipe | [just recipes](../reference/just-recipes.md) |

#icicle-insights# #Tutorial# #Developer# #setup#
