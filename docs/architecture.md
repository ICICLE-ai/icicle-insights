# Architecture

Insights separates HTTP delivery, scheduling, queue execution, persistence, platform APIs, and
credential storage so each can change or scale independently.

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#DBEAFE","primaryTextColor":"#172554","primaryBorderColor":"#2563EB","secondaryColor":"#DCFCE7","secondaryTextColor":"#14532D","secondaryBorderColor":"#16A34A","tertiaryColor":"#F3E8FF","tertiaryTextColor":"#581C87","tertiaryBorderColor":"#9333EA","lineColor":"#64748B","noteBkgColor":"#FEF3C7","noteTextColor":"#78350F","actorBkg":"#E0E7FF","actorBorder":"#4F46E5","actorTextColor":"#1E1B4B","signalColor":"#475569","signalTextColor":"#334155"}}}%%
flowchart TB
    UI[Dashboard / API client] --> HTTP[Vapor HTTP service]
    HTTP --> PG[(PostgreSQL)]
    SCH[Single scheduler] --> V[(Valkey / Redis)]
    HTTP --> V
    V --> W[One or more named workers]
    W --> API[GitHub / Hugging Face / future platforms]
    W --> SP[SecretProvider]
    SP -. current adapter .-> TV[Tapis Vault]
    W --> PG
```

## Responsibilities

| Component | Owns | Does not own |
|---|---|---|
| Controllers | HTTP decoding, validation, responses | Provider-specific secret access |
| Scheduler | Deciding when dispatcher jobs run | Slow platform API calls |
| Dispatchers | Finding eligible records and enqueueing typed jobs | Executing the sync |
| Workers | Claiming and executing queued jobs | Clock evaluation |
| PostgreSQL | Catalog, readings, due dates, watermarks | Queue delivery |
| Valkey | Durable queued payloads | Domain records or metric history |
| `SecretProvider` | Named credential lifecycle | Metrics or platform routing |
| Platform jobs | Fetching and translating provider data | Choosing the secret backend |

## Resource collection lifecycle

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#DBEAFE","primaryTextColor":"#172554","primaryBorderColor":"#2563EB","secondaryColor":"#DCFCE7","secondaryTextColor":"#14532D","secondaryBorderColor":"#16A34A","tertiaryColor":"#F3E8FF","tertiaryTextColor":"#581C87","tertiaryBorderColor":"#9333EA","lineColor":"#64748B","noteBkgColor":"#FEF3C7","noteTextColor":"#78350F","actorBkg":"#E0E7FF","actorBorder":"#4F46E5","actorTextColor":"#1E1B4B","signalColor":"#475569","signalTextColor":"#334155"}}}%%
sequenceDiagram
    participant S as Scheduler
    participant D as CollectDueResources
    participant DB as PostgreSQL
    participant Q as Valkey metrics queue
    participant W as Worker
    participant P as SecretProvider
    participant A as Platform API

    S->>D: hourly trigger
    D->>DB: nextCollectionAt <= now
    D->>Q: dispatch typed resource job
    D->>DB: book nextCollectionAt
    W->>Q: atomically claim job
    W->>P: readSecret(name)
    W->>A: fetch complete response set
    W->>DB: write snapshots / watermark fold
```

## Composition root

`configure.swift` is the one place concrete infrastructure is selected. Consumers use
protocols or framework abstractions. For example, jobs call `application.secrets`; configuration
chooses `TapisClient.Vaults` when `SECRET_PROVIDER=tapis`.

## Source layout

```text
Sources/Insights/
├── Commands/       one-shot operator commands
├── Controllers/    HTTP boundaries (dashboard intentionally separate)
├── DTOs/           request and public response shapes
├── Errors/         configuration and job failures
├── Migrations/     PostgreSQL schema and development snapshot
├── Models/         Fluent domain persistence
├── Queues/         dispatchers, workers, routing, watermark folds
├── Services/
│   ├── Secrets/    provider-neutral protocol, redacted value, app storage
│   └── Tapis/      current Tapis Vault adapter
└── configure.swift composition root
```

Read [invariants.md](invariants.md) before changing interactions between these components.

#icicle-insights# #architecture# #swift# #vapor# #developer-documentation#
