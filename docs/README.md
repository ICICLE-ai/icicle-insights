# ICICLE Insights documentation

Organised on [Diátaxis](https://diataxis.fr/). Four kinds of page, two audiences.

**Administrator** — you run a deployment. You use the console, the CLI, and the environment.
**Developer** — you change the code.

| | Learning | Doing | Looking up | Understanding |
|---|---|---|---|---|
| | Tutorial | How-to | Reference | Explanation |

## Start here

| You are | Read |
|---|---|
| New administrator | [Administering Insights](tutorials/administering-insights.md) |
| New contributor | [Local development](tutorials/local-development.md) |
| Deploying for the first time | [Deploy Insights](how-to/deploy-insights.md) |
| Looking for a setting | [Configuration](reference/configuration.md) |

## Tutorials

Learning by doing. Follow start to finish.

| Page | For |
|---|---|
| [Administering Insights](tutorials/administering-insights.md) | Administrator |
| [Local development](tutorials/local-development.md) | Developer |

## How-to guides

One goal each. Assume you know what you want.

| Page | Goal | For |
|---|---|---|
| [Get admin access](how-to/get-admin-access.md) | Sign in and gain administrator rights | Admin |
| [Register an account](how-to/register-an-account.md) | Add a platform account and its credential | Admin |
| [Add a resource](how-to/add-a-resource.md) | Put a repository or model under collection | Admin |
| [Issue a service token](how-to/issue-a-service-token.md) | Let a deployed service post its own metrics | Admin |
| [Rotate the signing keyset](how-to/rotate-the-signing-keyset.md) | Roll the webhook signing key with no downtime | Admin |
| [Manage administrators](how-to/manage-administrators.md) | Grant and revoke administrator access | Admin |
| [Deploy Insights](how-to/deploy-insights.md) | Stand up and operate a deployment | Both |
| [Run collection immediately](how-to/run-collection-immediately.md) | Collect now instead of waiting | Both |
| [Diagnose a collection failure](how-to/diagnose-a-collection-failure.md) | Work out why metrics stopped | Both |
| [Embed the dashboard](how-to/embed-the-dashboard.md) | Put the dashboard in an iframe | Both |
| [Set up the dashboard toolchain](how-to/set-up-the-dashboard-toolchain.md) | Angular, the MCP server, and the `llms-full.txt` files | Dev |
| [Add a collector](how-to/add-a-collector.md) | Collect from a new platform | Dev |
| [Add a queue or worker](how-to/add-a-queue-or-worker.md) | Introduce a new named queue | Dev |
| [Add a secret provider](how-to/add-a-secret-provider.md) | Store credentials somewhere else | Dev |
| [Run the tests](how-to/run-the-tests.md) | Get the suite passing locally | Dev |

## Reference

Facts. Look things up; do not read start to finish.

| Page | Contains | For |
|---|---|---|
| [Admin console](reference/admin-console.md) | Every console screen, with screenshots | Admin |
| [Configuration](reference/configuration.md) | Every environment variable | Both |
| [CLI](reference/cli.md) | Every command and flag | Both |
| [HTTP API](reference/http-api.md) | Routes, guards, status codes, conventions | Both |
| [Collection schedule](reference/collection-schedule.md) | What is collected, when, from where | Both |
| [Data model](reference/data-model.md) | Tables, fields, enumerations | Dev |
| [just recipes](reference/just-recipes.md) | Every recipe in both justfiles | Dev |
| [Invariants](reference/invariants.md) | Rules a change must not break | Dev |
| [Test suite](reference/test-suite.md) | What the 195 tests cover | Dev |
| [Glossary](reference/glossary.md) | Project vocabulary | Both |

## Explanation

Why the system is shaped the way it is.

| Page | Explains |
|---|---|
| [Architecture](explanation/architecture.md) | The parts and how they fit |
| [Metric collection](explanation/metric-collection.md) | Gauges, rolling windows, retention |
| [Watermarks](explanation/watermarks.md) | Why totals are not double counted |
| [Authentication](explanation/authentication.md) | Two credential paths, one guard |
| [Queues and scheduling](explanation/queues-and-scheduling.md) | One scheduler, many workers |
| [Secret providers](explanation/secret-providers.md) | Why credentials sit behind an interface |
| [The dashboard](explanation/the-dashboard.md) | How the Angular application is served |
| [Decisions](explanation/decisions/) | Seven architecture decision records |

#icicle-insights# #Reference# #Administrator# #Developer# #documentation-index#
