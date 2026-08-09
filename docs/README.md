# Developer handbook

These guides explain both how Insights works and why its boundaries exist. Start with the
[introduction](introduction.md), continue to [architecture](architecture.md), then use the
task-oriented guides as needed.

| Guide | Use it when |
|---|---|
| [Introduction](introduction.md) | You are new to the project and want the visual mental model |
| [Architecture](architecture.md) | You need the system map and request/job lifecycles |
| [Invariants](invariants.md) | You are changing behavior and need the rules that must remain true |
| [Secret providers](secret-providers.md) | You are configuring or adding a credential backend |
| [Queue workers and scheduling](queue-workers.md) | You are changing clocks, queues, workers, or scaling |
| [Testing collection](testing-collection.md) | You need to run collection immediately and inspect it |
| [Adding a job](jobs.md) | You are implementing another platform collector |
| [Metric collection](collection.md) | You need to understand snapshots, rolling windows, and retention |
| [Watermarks](watermarks.md) | You need a focused explanation of double-count prevention |
| [Troubleshooting](troubleshooting.md) | Something is running incorrectly |
| [Glossary](glossary.md) | A project term is unfamiliar |

Architecture decisions live under [`decisions/`](decisions/). They preserve the reasoning
behind important choices so future changes retain the system's correctness guarantees.

#icicle-insights# #documentation-index# #developer-documentation#
