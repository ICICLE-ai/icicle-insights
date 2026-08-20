# Welcome to ICICLE Insights

ICICLE Insights measures the reach of open-source work across hosting platforms. It collects
signals such as stars, forks, clones, views, downloads, likes, and followers; preserves their
history; and serves the results through a Vapor API and dashboard.

Built for the ICICLE research ecosystem, its core model is intentionally general-purpose:

```text
platform account → published resource → metric history
```

Platform credentials are resolved through the `SecretProvider` application service. The
composition root selects a credential adapter; the included configuration selects Tapis Vault.

## The system in one picture

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#DBEAFE","primaryTextColor":"#172554","primaryBorderColor":"#2563EB","secondaryColor":"#DCFCE7","secondaryTextColor":"#14532D","secondaryBorderColor":"#16A34A","tertiaryColor":"#F3E8FF","tertiaryTextColor":"#581C87","tertiaryBorderColor":"#9333EA","lineColor":"#64748B","noteBkgColor":"#FEF3C7","noteTextColor":"#78350F","actorBkg":"#E0E7FF","actorBorder":"#4F46E5","actorTextColor":"#1E1B4B","signalColor":"#475569","signalTextColor":"#334155"}}}%%
flowchart LR
    P[Hosting platforms<br/>GitHub, Hugging Face, future providers]
    S[Single scheduler]
    Q[(Valkey queues)]
    W[Scalable workers]
    C[SecretProvider]
    DB[(PostgreSQL)]
    API[Vapor API]
    UI[Dashboard and API clients]

    S -->|find due work| Q
    Q --> W
    W --> C
    W --> P
    W --> DB
    API --> DB
    UI --> API
    classDef app fill:#DBEAFE,stroke:#2563EB,color:#172554
    classDef data fill:#DCFCE7,stroke:#16A34A,color:#14532D
    classDef service fill:#F3E8FF,stroke:#9333EA,color:#581C87
    classDef external fill:#FEF3C7,stroke:#D97706,color:#78350F
    class API,UI app
    class DB,Q data
    class S,W,C service
    class P external
```

There is one scheduler because duplicate schedulers can dispatch the same work twice. Queue
workers can scale horizontally because Valkey atomically assigns each available payload to one
worker. Delivery remains at-least-once, so jobs must still be safe to retry.

## The collection story

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#DBEAFE","primaryTextColor":"#172554","primaryBorderColor":"#2563EB","secondaryColor":"#DCFCE7","secondaryTextColor":"#14532D","secondaryBorderColor":"#16A34A","tertiaryColor":"#F3E8FF","tertiaryTextColor":"#581C87","tertiaryBorderColor":"#9333EA","lineColor":"#64748B","noteBkgColor":"#FEF3C7","noteTextColor":"#78350F","actorBkg":"#E0E7FF","actorBorder":"#4F46E5","actorTextColor":"#1E1B4B","signalColor":"#475569","signalTextColor":"#334155"}}}%%
sequenceDiagram
    participant Clock as Scheduler
    participant Sweep as Due-resource sweep
    participant Queue as metrics queue
    participant Worker as Sync worker
    participant Platform as Platform API
    participant Data as PostgreSQL

    Clock->>Sweep: Run hourly
    Sweep->>Data: Find nextCollectionAt <= now
    Sweep->>Queue: Enqueue platform-specific job
    Sweep->>Data: Book next collection date
    Worker->>Queue: Claim job
    Worker->>Platform: Fetch metrics
    Worker->>Data: Store snapshots and safe totals
```

The hourly sweep is only a scanner. A resource normally runs every seven days—or its configured
cadence—not every hour. Account followers use a separate monthly dispatcher because they belong
to an account rather than an individual resource.

## Why watermarks exist

Some APIs return overlapping recent windows instead of new deltas. Adding every response would
count the shared days repeatedly. A watermark remembers the newest completed day already added.

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#DBEAFE","primaryTextColor":"#172554","primaryBorderColor":"#2563EB","secondaryColor":"#DCFCE7","secondaryTextColor":"#14532D","secondaryBorderColor":"#16A34A","tertiaryColor":"#F3E8FF","tertiaryTextColor":"#581C87","tertiaryBorderColor":"#9333EA","lineColor":"#64748B","noteBkgColor":"#FEF3C7","noteTextColor":"#78350F","actorBkg":"#E0E7FF","actorBorder":"#4F46E5","actorTextColor":"#1E1B4B","signalColor":"#475569","signalTextColor":"#334155"}}}%%
flowchart LR
    A[Rolling daily response] --> B{Day completed?}
    B -- No --> X[Wait for next sweep]
    B -- Yes --> C{Newer than watermark?}
    C -- No --> D[Skip: already counted]
    C -- Yes --> E[Add to all-time total]
    E --> F[Advance watermark]
    classDef decision fill:#FEF3C7,stroke:#D97706,color:#78350F
    classDef success fill:#DCFCE7,stroke:#16A34A,color:#14532D
    classDef muted fill:#F1F5F9,stroke:#64748B,color:#334155
    class B,C decision
    class E,F success
    class X,D muted
```

Read [watermarks.md](watermarks.md) when you want the full worked example.

## How the code is organized

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#DBEAFE","primaryTextColor":"#172554","primaryBorderColor":"#2563EB","secondaryColor":"#DCFCE7","secondaryTextColor":"#14532D","secondaryBorderColor":"#16A34A","tertiaryColor":"#F3E8FF","tertiaryTextColor":"#581C87","tertiaryBorderColor":"#9333EA","lineColor":"#64748B","noteBkgColor":"#FEF3C7","noteTextColor":"#78350F","actorBkg":"#E0E7FF","actorBorder":"#4F46E5","actorTextColor":"#1E1B4B","signalColor":"#475569","signalTextColor":"#334155"}}}%%
flowchart TB
    CR[Composition root<br/>configure.swift]
    CT[Controllers]
    QU[Queues and jobs]
    MO[Models and DTOs]
    SS[SecretProvider]
    TA[Tapis adapter]

    CR --> CT
    CR --> QU
    CR --> SS
    CT --> MO
    QU --> MO
    CT --> SS
    QU --> SS
    TA -. conforms to .-> SS
    classDef core fill:#DBEAFE,stroke:#2563EB,color:#172554
    classDef boundary fill:#DCFCE7,stroke:#16A34A,color:#14532D
    classDef adapter fill:#F3E8FF,stroke:#9333EA,color:#581C87
    class CR,CT,QU,MO core
    class SS boundary
    class TA adapter
```

- `Controllers/` owns HTTP boundaries.
- `Queues/` owns dispatch, workers, provider translation, and watermark folds.
- `Models/` and `DTOs/` own persisted and public data shapes.
- `Services/Secrets/` owns the provider-neutral credential boundary.
- `Services/Tapis/` is one secret-provider adapter.
- `configure.swift` selects concrete infrastructure once.

## Choose your path

```mermaid
%%{init: {"theme":"base","themeVariables":{"primaryColor":"#DBEAFE","primaryTextColor":"#172554","primaryBorderColor":"#2563EB","secondaryColor":"#DCFCE7","secondaryTextColor":"#14532D","secondaryBorderColor":"#16A34A","tertiaryColor":"#F3E8FF","tertiaryTextColor":"#581C87","tertiaryBorderColor":"#9333EA","lineColor":"#64748B","noteBkgColor":"#FEF3C7","noteTextColor":"#78350F","actorBkg":"#E0E7FF","actorBorder":"#4F46E5","actorTextColor":"#1E1B4B","signalColor":"#475569","signalTextColor":"#334155"}}}%%
flowchart TD
    START[What are you trying to learn?]
    START -->|Whole system| A[Architecture]
    START -->|Rules that must remain true| I[Invariants]
    START -->|Run collection now| T[Testing collection]
    START -->|Add a platform job| J[Adding a job]
    START -->|Change credential backend| S[Secret providers]
    START -->|Something is broken| R[Troubleshooting]
    START -->|Term is unfamiliar| G[Glossary]
    classDef start fill:#F3E8FF,stroke:#9333EA,color:#581C87
    classDef guide fill:#DBEAFE,stroke:#2563EB,color:#172554
    class START start
    class A,I,T,J,S,R,G guide
```

- Start with [architecture.md](architecture.md) for component ownership and lifecycles.
- Read [invariants.md](invariants.md) before refactoring core behavior.
- Use [testing-collection.md](testing-collection.md) to run jobs without changing schedules.
- Use [jobs.md](jobs.md) to implement another collector.
- Use [secret-providers.md](secret-providers.md) to add or switch credential backends.
- Use [troubleshooting.md](troubleshooting.md) for symptom-driven diagnosis.
- Browse [README.md](README.md) for the complete handbook index.

## Preserving design intent

These guides explain intent alongside mechanics. Architecture decision records under
[`decisions/`](decisions/) preserve the reasoning behind important choices. Review the relevant
invariant and decision record before changing a queue, watermark, lock, or service boundary.

#icicle-insights# #introduction# #architecture# #developer-documentation#
