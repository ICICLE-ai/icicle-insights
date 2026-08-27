# just recipes

Every recipe in `justfile` and `justfiles/apple-container.just`. For developers.

`just` with no arguments lists them all, grouped.

## swift

Run against local PostgreSQL and Valkey. No containers involved.

| Recipe | Runs |
|---|---|
| `just run` | `Insights serve` on http://127.0.0.1:8080 |
| `just migrate` | `Insights migrate --yes` |
| `just revert` | `Insights migrate --revert --yes` |
| `just test` | `swift test --no-parallel` |
| `just fmt` | `swift-format` in place |
| `just fmt-check` | `swift-format lint` |

`just test` must stay serial. Every suite shares the `test` database and migrates and reverts
around itself, so any overlap has one suite reverting the schema out from under another.

## web

| Recipe | Runs |
|---|---|
| `just web-install` | `npm ci` in `Dashboard/` |
| `just web` | `ng serve` on http://localhost:4200, proxying `/api` to port 8080 |
| `just web-test` | Vitest |
| `just web-build` | Production bundle |

## cli

| Recipe | Runs |
|---|---|
| `just token <args>` | `Insights service-token …` |
| `just collect [--force]` | `Insights collect-resources` |
| `just collect-accounts` | `Insights collect-accounts` |
| `just collect-patra-catalog` | `Insights collect-patra-catalog` |

See [CLI](cli.md) for the arguments each accepts.

## setup

One-time host configuration for the Apple Container stack. Needs macOS 26 or later.

| Recipe | Does |
|---|---|
| `just dns` | Registers the local DNS domain. **Run once per machine, first** |
| `just dns-delete` | Unregisters it |
| `just runtime` | Starts Apple's container services |
| `just builder` | Starts BuildKit with 4 CPUs, 8 GiB, and explicit resolvers |
| `just up` | Creates the network and both data volumes |

`just dns` asks for an administrator password and restarts the container service, stopping
everything currently running. Without it, containers cannot resolve each other by name and the
whole stack fails to connect.

The builder's `--dns` values are upstream resolvers for fetching Swift packages during a build.
They are unrelated to the container name resolution `just dns` configures. Override with
`CONTAINER_BUILD_DNS` and `CONTAINER_BUILD_DNS_ALT` if those resolvers are unavailable.

## containers

One recipe per `docker-compose.yml` service, with matching names and commands.

| Recipe | Container | Command |
|---|---|---|
| `just build` | — | Builds the `icicle-insights` image |
| `just db` | `db` | PostgreSQL 18, waits for `pg_isready` |
| `just valkey` | `valkey` | Valkey 9, append-only, waits for `PING` |
| `just stack-migrate` | `migrate` | `migrate --yes`, then exits |
| `just stack-revert` | `revert` | `migrate --revert --yes`, then exits |
| `just app` | `app` | `serve` |
| `just queues` | `queues` | `queues --queue metrics` |
| `just scheduled` | `scheduled` | `queues --scheduled` |

`just build` assembles a minimal build context by hand rather than handing the repository to the
builder. The Dockerfile does `COPY . .`, and `Dashboard/node_modules` is the wrong platform's
binaries and hundreds of megabytes; that cost lands before the builder ever reads `.dockerignore`.

The `app` container runs as root because the image's `vapor` user cannot bind below 1024 and the
container serves port 80. Drop the override if you move `APP_PORT` above 1024.

## collect

Each dispatches onto the `metrics` queue and exits. **`just queues` must be running** or nothing
is collected.

| Recipe | Selects |
|---|---|
| `just collect-now` | Resources already due |
| `just collect-all-now` | Every active resource. Shifts every cadence forward |
| `just collect-accounts-now` | Every GitHub account |
| `just collect-patra-catalog-now` | Every Patra account |

## stack

| Recipe | Does | Data |
|---|---|---|
| `just stack` | Recreates the whole stack in dependency order | kept |
| `just stop` | Stops and removes the stack containers | kept |
| `just clean` | Also removes the network | kept |
| `just destroy` | Removes containers, volumes, network, image, and builder | **destroyed** |

`just destroy` prompts for confirmation. The PostgreSQL volume holds the collected metric history
and the Valkey volume holds queued jobs; neither is recoverable. Set `CONFIRM=yes` to skip the
prompt in a script.

## Variables

Override on the command line or in the environment.

| Variable | Default | Controls |
|---|---|---|
| `APP_PORT` | `80` | Port inside the container |
| `APP_HOST_PORT` | `8080` | Host side of the 127.0.0.1 mapping |
| `CONTAINER_BUILD_DNS` | `75.75.75.75` | Resolver for package fetching |
| `CONTAINER_BUILD_DNS_ALT` | `75.75.76.76` | Secondary resolver |

## Environment layering

Application containers load, in precedence order:

1. `--env-file .env` — credentials. Gitignored, and the only place they belong.
2. `--env-file .env.container` — tracked local defaults. Later file wins on conflict.
3. `--env` flags for the in-network database and queue hostnames. These outrank both files.

**`.env` must exist.** A missing `--env-file` is an error, not a skipped file. Copy `.env.example`.

Anything secret placed in `.env.container` is secret in the repository.

## Upgrading from older recipe names

Recipes were renamed to match the Compose service names.

| Old | New |
|---|---|
| `stack-scheduled` | `stack` |
| `start` | `app` |
| `migrate-container` | `stack-migrate` |
| `container-runtime` | `runtime` |

Containers were once named `insights-app`, `insights-db`, and so on. If a stack from before that
change is still running, clear it once:

```bash
for n in insights-app insights-db insights-valkey insights-queues insights-scheduled; do container stop $n 2>/dev/null; container delete $n 2>/dev/null; done
```

#icicle-insights# #Reference# #Developer# #tooling#
