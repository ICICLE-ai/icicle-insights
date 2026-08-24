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

**Administrator**

| Page | Goal |
|---|---|
| [Get admin access](how-to/get-admin-access.md) | Sign in and gain administrator rights |
| [Register an account](how-to/register-an-account.md) | Add a platform account and its credential |
| [Add a resource](how-to/add-a-resource.md) | Put a repository or model under collection |
| [Run collection immediately](how-to/run-collection-immediately.md) | Collect now instead of waiting |
| [Issue a service token](how-to/issue-a-service-token.md) | Let a deployed service post its own metrics |
| [Rotate the signing keyset](how-to/rotate-the-signing-keyset.md) | Roll the webhook signing key with no downtime |
| [Manage administrators](how-to/manage-administrators.md) | Grant and revoke administrator access |
| [Diagnose a collection failure](how-to/diagnose-a-collection-failure.md) | Work out why metrics stopped |
| [Deploy Insights](how-to/deploy-insights.md) | Stand up a new deployment |
| [Embed the dashboard](how-to/embed-the-dashboard.md) | Put the dashboard in an iframe |

**Developer**

| Page | Goal |
|---|---|
| [Set up the dashboard toolchain](how-to/set-up-the-dashboard-toolchain.md) | Angular, the MCP server, and the `llms-full.txt` files |
| [Add a collector](how-to/add-a-collector.md) | Collect from a new platform |
| [Add a queue or worker](how-to/add-a-queue-or-worker.md) | Introduce a new named queue |
| [Add a secret provider](how-to/add-a-secret-provider.md) | Store credentials somewhere else |
| [Run the tests](how-to/run-the-tests.md) | Get the suite passing locally |

## Reference

Facts. Look things up; do not read start to finish.

| Page | Contains |
|---|---|
| [Admin console](reference/admin-console.md) | Every console screen, with screenshots |
| [Configuration](reference/configuration.md) | Every environment variable |
| [CLI](reference/cli.md) | Every command and flag |
| [HTTP API](reference/http-api.md) | Routes, guards, status codes, conventions |
| [Collection schedule](reference/collection-schedule.md) | What is collected, when, from where |
| [Data model](reference/data-model.md) | Tables, fields, enumerations |
| [just recipes](reference/just-recipes.md) | Every recipe in both justfiles |
| [Invariants](reference/invariants.md) | Rules a change must not break |
| [Test suite](reference/test-suite.md) | What the 195 tests cover |
| [Glossary](reference/glossary.md) | Project vocabulary |

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
