# ICICLE Insights documentation

The map of every page, for anyone looking for the right one. Pages are grouped by what you want to
do. Each is written for a reader, an administrator or a developer.

- **Reader:** anyone looking at the dashboard
- **Administrator:** runs the catalog in the admin console, or runs the deployment
- **Developer:** changes the code

## Tutorials: learn by doing

| Page | For | You will |
|---|---|---|
| [Tour the dashboard](tutorials/tour-the-dashboard.md) | Reader | Read the overview, filter, and drill into a resource |
| [Administer Insights](tutorials/administer-insights.md) | Administrator | Sign in, check health, and follow a resource to its first reading |
| [Run Insights locally](tutorials/run-insights-locally.md) | Developer | Run the API, dashboard and tests on your machine |

## How-to guides: one task each

### Using the admin console

| Page | For |
|---|---|
| [Sign in as an administrator](how-to/sign-in-as-an-administrator.md) | Administrator |
| [Track a new account](how-to/track-a-new-account.md) | Administrator |
| [Add a resource](how-to/add-a-resource.md) | Administrator |
| [Replace a platform token](how-to/replace-a-platform-token.md) | Administrator |
| [Record a release](how-to/record-a-release.md) | Administrator |
| [Correct a metric](how-to/correct-a-metric.md) | Administrator |
| [Manage administrators](how-to/manage-administrators.md) | Administrator |
| [Issue a service token](how-to/issue-a-service-token.md) | Administrator, Developer |
| [Rotate the signing key](how-to/rotate-the-signing-key.md) | Administrator |
| [Diagnose a collection failure](how-to/diagnose-a-collection-failure.md) | Administrator |

### Running the deployment

| Page | For |
|---|---|
| [Deploy Insights](how-to/deploy-insights.md) | Administrator, Developer |
| [Renew the Tapis service token](how-to/renew-the-tapis-token.md) | Administrator |
| [Collect now](how-to/collect-now.md) | Administrator, Developer |
| [Embed the dashboard in TapisUI](how-to/embed-in-tapisui.md) | Administrator |

### Changing the code

| Page | For |
|---|---|
| [Run the tests](how-to/run-the-tests.md) | Developer |
| [Develop the dashboard](how-to/develop-the-dashboard.md) | Developer |
| [Add a collector](how-to/add-a-collector.md) | Developer |

## Reference: facts to look up

| Page | For | Covers |
|---|---|---|
| [Dashboard](reference/dashboard.md) | Reader | Every public screen, control and URL parameter |
| [Metrics and collection](reference/metrics.md) | All | Metric types, platforms, schedules, retries |
| [Admin console](reference/admin-console.md) | Administrator | Every console page, form and action |
| [Collection failures](reference/collection-failures.md) | Administrator, Developer | Failure identifiers, severity, alerts |
| [Configuration](reference/configuration.md) | Administrator, Developer | Every environment variable |
| [Commands](reference/commands.md) | Administrator, Developer | The binary's commands and `just` recipes |
| [HTTP API](reference/http-api.md) | Developer | Every route and who may call it |
| [Data model](reference/data-model.md) | Developer | Tables, columns and constraints |
| [CI pipeline](reference/ci-pipeline.md) | Developer | Workflow jobs, caches, image tags |

## Explanation: why it works this way

| Page | For | Explains |
|---|---|---|
| [Reading the numbers](explanation/reading-the-numbers.md) | Reader | Readings, windows, lifetime totals, how tiles add up |
| [How collection works](explanation/how-collection-works.md) | Administrator, Developer | Due dates, retries, windows, storage, Patra, GHCR |
| [Access and sign-in](explanation/access-and-sign-in.md) | Administrator, Developer | Public reads, administrators, service tokens |
| [Architecture](explanation/architecture.md) | Developer, Administrator | Processes, request path, source layout |
| [The dashboard](explanation/the-dashboard.md) | Developer | Static build, summaries, URL state, charts |

## Elsewhere

- [README](../README.md): what Insights is
- [TODO](../TODO.md): known problems and what is left
- [CLAUDE.md](../CLAUDE.md): working notes and documentation rules
- `/docs` on a running deployment: the generated API reference

#icicle-insights# #Reference# #Reader# #Administrator# #Developer#
