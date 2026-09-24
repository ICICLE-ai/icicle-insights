# CI pipeline

The jobs in `.github/workflows/build.yaml`, what each one caches, and the `Dockerfile` targets they
use. For developers.

## Triggers

| Event | Branches | Pushes an image | Publishes a release |
|---|---|---|---|
| `push` | `main`, `dev` | Yes | No |
| `push` | tags `v*` | Yes | Yes |
| `pull_request` | into `main`, `dev` | No | No |

A newer push to the same pull request cancels the older run. Pushes to branches and tags always
finish.

## Jobs

`test`, `build` and `web` start together. `image` waits for all three. `release` waits for `image`.

| Job | Runs in | Does | Output |
|---|---|---|---|
| `test` | `swift:6.3-noble` with Postgres and Valkey services | `swift build --build-tests`, then `swift test --no-parallel` | — |
| `build` | `swift:6.3-noble` | Release build of `Insights` with static stdlib and jemalloc | `server` artifact: `server.tar` |
| `web` | Deno 2.9 | `deno install --frozen`, then `check`, `test` and `build` in `web/` | `web` artifact: `web.tar` |
| `image` | Docker Buildx | Assembles `.ci-staging/`, builds `--target prebuilt`, pushes to GHCR | `ghcr.io/icicle-ai/insights:{latest,<sha>}` |
| `release` | Ubuntu | Extracts `Insights` from `server.tar`, renames it `icicle-insights`, tars it | GitHub release asset |

`image` needs `test` even though it uses nothing `test` produces. Nothing is published from a tree
whose suite failed.

## Caches

| Cache | Job | Path | Key |
|---|---|---|---|
| `swift-debug-*` | `test` | `.build` | OS, `Package.resolved` hash, `Sources/**` and `Tests/**` hash |
| `swift-release-*` | `build` | `.build` | OS, `Package.resolved` hash, `Sources/**` hash |
| Deno | `web` | Deno's download cache | `web/deno.lock` hash, via `setup-deno` |
| Docker layers | `image` | BuildKit `type=gha` | Managed by Buildx |

Each Swift cache falls back to the newest entry with the same `Package.resolved`, then to any entry
for the OS. A restored `.build` recompiles only this repository's module, not Vapor, NIO or the
other dependencies.

Swift caches are saved right after the build step, before tests run. A failing test still leaves a
warm cache for the next run.

## Dockerfile targets

| Target | Used by | Builds |
|---|---|---|
| `runtime` (default, last stage) | `just build`, `docker compose` | Frontend and server from source |
| `prebuilt` | CI `image` job | Nothing. Copies `.ci-staging/` onto the runtime base |

Both targets extend `runtime-base`, which holds the user, entrypoint and environment.

`.ci-staging/` has the same layout as the source build's `/staging`:

| Path | From |
|---|---|
| `Insights` | `server.tar` |
| `swift-backtrace-static` | `server.tar` |
| `*.resources` | `server.tar`, when SwiftPM bundles any |
| `Public/` | `web.tar`. The `prebuilt` stage makes it read-only |

Artifacts are tarballs because an artifact upload drops the executable bit.

## Expected durations

| Run | Roughly |
|---|---|
| Cold caches, the first run after `Package.resolved` changes | 13–14 min |
| Warm caches | 6–8 min |
| Before this layout, every run | 21 min |

#icicle-insights# #Reference# #Developer# #tooling#
