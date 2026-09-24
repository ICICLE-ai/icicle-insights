# ICICLE Insights

ICICLE Insights measures how the ICICLE institute's open-source work is used. It collects stars, forks,
traffic, downloads, pulls and deployments from the platforms the institute publishes on. It keeps the
history and shows it on a public dashboard.

- **Dashboard:** <https://insights.pods.icicleai.tapis.io>
- **Inside TapisUI:** <https://icicleai.tapis.io/#/insights>, under *ICICLE Services → Insights*
- **API reference:** `/docs` on any deployment, generated from `/openapi.json`

## What it tracks

| Platform | What is tracked | Collected |
|---|---|---|
| GitHub | Repositories: stars, forks, watchers, 14-day views and clones | Yes |
| Hugging Face | Models and datasets: 30-day downloads, likes, lifetime downloads | Yes |
| Patra | Model cards and datasheets: deployments, card details | Yes |
| GHCR | Container images: 30-day pulls, lifetime pulls | Yes |
| npm | Packages | Listed only |
| PyPI | Packages | Listed only |

npm and PyPI are not collected on purpose. Their download counts cannot tell a person from a CI
runner or a mirror refreshing its cache.

## What you can do with it

- **Read the dashboard.** Pick a platform and a time range, then drill into any resource. Start with
  [Tour the dashboard](docs/tutorials/tour-the-dashboard.md).
- **Run the catalog.** Administrators sign in with a Tapis account to add accounts, resources,
  credentials and releases. Start with [Administer Insights](docs/tutorials/administer-insights.md).
- **Change the code.** A Swift server and a SvelteKit dashboard. Start with
  [Run Insights locally](docs/tutorials/run-insights-locally.md).

## How it is built

| Part | Technology |
|---|---|
| API and collectors | Swift 6.3, Vapor 4, Fluent |
| Storage | PostgreSQL 18 |
| Job queue and rate limits | Valkey 9 (any Redis-protocol server) |
| Dashboard | SvelteKit (Svelte 5), Tailwind 4, shadcn-svelte, built with Deno |
| Sign-in and secrets | Tapis tokens and Tapis Vault |
| Delivery | One container image, `ghcr.io/icicle-ai/insights` |

The image runs as three processes: the API, a queue worker and a scheduler.
[Architecture](docs/explanation/architecture.md) explains how they fit together.

## Quick start for developers

```bash
cp .env.example .env        # then fill in the Tapis values; see the tutorial
just web-install
just run                    # API on http://127.0.0.1:8080
just web                    # dashboard on http://localhost:5174
```

This needs PostgreSQL and Valkey running locally. The full walkthrough is
[Run Insights locally](docs/tutorials/run-insights-locally.md).

## Documentation

Everything is under [docs/](docs/README.md), in four kinds:

- tutorials to learn by doing
- how-to guides for one task
- reference tables to look things up
- explanations of why it works the way it does

## Acknowledgment

National Science Foundation (NSF) funded AI institute for Intelligent Cyberinfrastructure with
Computational Learning in the Environment (ICICLE) (OAC 2112606).

## License

See [LICENSE](LICENSE).
