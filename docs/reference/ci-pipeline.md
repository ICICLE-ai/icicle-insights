# CI pipeline

What `.github/workflows/build.yaml` runs, when, and what it publishes. For developers reading a CI
result or changing the workflow.

## Triggers

| Event | Runs | Publishes |
|---|---|---|
| Pull request to `main` or `dev` | `test`, `build`, `web`, `image` | Nothing |
| Push to `main` or `dev` | The same | Image to GHCR |
| Push of a tag `v*` | The same, plus `release` | Image, and a GitHub release |

A newer push to the same pull request cancels the older run. Pushes to branches and tags always
finish.

## Jobs

`test`, `build` and `web` start together. `image` waits for all three.

| Job | Runs in | Does |
|---|---|---|
| `test` | `swift:6.3-noble`, with PostgreSQL 18 and Valkey 9 services | `swift build --build-tests`, then `swift test --no-parallel` against a `test` database |
| `build` | `swift:6.3-noble` | Release build of `Insights`, statically linked with jemalloc. Uploads the binary as `server` |
| `web` | Ubuntu with Deno 2.9.7 | `deno install --frozen`, `deno task check`, `deno task test`, `deno task build`. Uploads the site as `web` |
| `image` | Ubuntu with Buildx | Unpacks both artifacts and builds the Dockerfile's `prebuilt` target. Pushes except on pull requests |
| `release` | Ubuntu | Tags only. Publishes `icicle-insights-linux-amd64.tar.gz` |

## Test environment

| Variable | Value |
|---|---|
| `TAPIS_BASE_URL` | `https://icicleai.staging.tapis.io/v3` |
| `TAPIS_TENANT` | `icicleai` |
| `TAPIS_USER` | `ci` |
| `TAPIS_TOKEN` | `ci-placeholder-not-a-jwt`, so vault tests skip themselves |
| `ROOT_ADMIN_USERNAME` | `ci-root-admin` |
| `DATABASE_TLS` | `disable` |

## Caches

| Cache | Key | Restores from |
|---|---|---|
| Debug `.build` | `swift-debug-<os>-<Package.resolved hash>-<Sources and Tests hash>` | The same resolved packages, then any debug build |
| Release `.build` | `swift-release-<os>-<Package.resolved hash>-<Sources hash>` | The same resolved packages, then any release build |
| Deno | `deno.lock` | Managed by `setup-deno` |
| Docker layers | GitHub Actions cache | `cache-from` and `cache-to` `type=gha` |

Swift caches are saved right after building, before tests run, so a failing test does not throw
away a good build.

## Image

| Tag | Points at |
|---|---|
| `ghcr.io/icicle-ai/insights:latest` | The latest push to `main` or `dev` |
| `ghcr.io/icicle-ai/insights:<commit sha>` | That commit |

Pushing needs the repository secrets `REGISTRY_USERNAME` and `REGISTRY_PASSWORD`.

## Dockerfile targets

| Target | Used by | Builds |
|---|---|---|
| `runtime` (default) | `docker build`, Compose, `just build` | The dashboard and the server from source |
| `prebuilt` | CI | Copies an already built server and dashboard from `.ci-staging/` |
| `runtime-base` | Both of the above | Ubuntu with the `vapor` user, entrypoint and production defaults |

Both final targets make `Public/` read-only.

#icicle-insights# #Reference# #Developer#
