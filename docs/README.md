# Developer Guide

Reference documentation for contributing to ICICLE Insights.

## Core Guides

| Guide | Description |
|-------|-------------|
| [architecture.md](architecture.md) | Module structure, core patterns, data model, and design decisions |
| [background-tasks.md](background-tasks.md) | How to schedule recurring background tasks using `scheduleRecurringTask` |
| [http-client-guide.md](http-client-guide.md) | Building reusable HTTP clients with SSL, connection pooling, and caching |
| [async-task-patterns.md](async-task-patterns.md) | Five async patterns from thread pools to C++20 coroutines |
| [logging.md](logging.md) | Per-component named loggers, log file layout, and log configuration |
| [tls-guide.md](tls-guide.md) | Configuring SSL/TLS for outbound HTTP client requests |
| [task-persistence.md](task-persistence.md) | Future: persisting task run history and results to the database |

## Quick Reference

### Error Handling

```cpp
#include "insights/core/result.hpp"

// Return a Result<T> from any function that can fail
Result<MyModel> fetchSomething(std::string_view Id) {
    auto Row = Db->get<MyModel>(Id);
    if (!Row) {
        return std::unexpected(Error{.Message = Row.error().Message});
    }
    return *Row;
}

// In a route handler
auto Entry = Db->get<github::Account>(Id);
if (!Entry) {
    return glz::response{HttpStatus::NotFound, Entry.error().Message};
}
```

### Adding a Route

1. Declare the handler in the appropriate module's `routes.hpp`.
2. Implement it in the corresponding `routes.cpp`.
3. Register it inside the module's `registerRoutes` function:

```cpp
// github/routes.cpp
Router.on<glz::GET>("/api/github/accounts/:id", [Db](glz::request& Req) {
    auto Id    = Req.params["id"];
    auto Entry = Db->get<github::Account>(Id);
    if (!Entry) {
        return glz::response{HttpStatus::NotFound, Entry.error().Message};
    }
    return glz::response{HttpStatus::Ok, *Entry};
});
```

### Adding a Task Logger

```cpp
#include "insights/core/logging.hpp"

// Inside a task function
auto Logger = createLogger("my_task", Config);
Logger->info("Starting sync");
Logger->warn("Rate limit approaching: {} requests remaining", Remaining);
```

Logs are written to `{LOG_DIR}/my_task.log` and to shared stdout. See
[logging.md](logging.md) for full details.

## Development Workflow

```bash
just deps        # Install Conan dependencies
just setup       # Configure CMake
just build       # Compile
just run         # Run the server

just full-build  # deps + setup + build in one step
just clean-build # Wipe build dir and rebuild from scratch
```

See the project [CLAUDE.md](../CLAUDE.md) for environment variable configuration.

## Common Tasks

### Add an Endpoint

1. **Model** — add or update a struct in `include/insights/<module>/models.hpp`.
2. **DbTraits** — add a `DbTraits<MyModel>` specialization in `db/db.hpp` if the model is
   database-backed.
3. **Schema** — add input/output schema structs to `<module>/routes.hpp` if the endpoint
   accepts or returns JSON.
4. **Handler** — implement the lambda in `src/<module>/routes.cpp`.
5. **Registration** — call `Router.on<METHOD>(path, handler)` inside `registerRoutes`.
6. **CMakeLists.txt** — add any new `.cpp` files to the executable sources, then re-run
   `just setup`.

### Add a Task Logger

1. Call `createLogger("task_name", Config)` at the start of the task function.
2. Use the returned `spdlog::logger` pointer for all logging in that task.
3. Set `LOG_DIR` in your `.env` to direct file output to a known location.

## Code Style

This project follows LLVM naming conventions:

| Construct | Convention | Example |
|-----------|-----------|---------|
| Types (class, struct, enum, typedef) | PascalCase | `Platform`, `HttpStatus` |
| Variables | PascalCase | `Database`, `Config`, `NewAccount` |
| Functions | lowerCamelCase verb phrase | `registerRoutes()`, `syncStats()` |
| Enumerators | PascalCase | `Ok`, `BadRequest`, `NotFound` |
| Struct/class members | PascalCase | `.Id`, `.Name`, `.AccountId` |

Additional rules:
- `#pragma once` for all header guards.
- Namespaced by module: `insights::<module>` (e.g., `insights::github`, `insights::core`).
- No cryptic abbreviations: `JsonError` not `Ec`, `ErrorCode` not `Err`.
- Header-only for small utilities; separate `.cpp` for route handlers and task implementations.

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| `std::expected` instead of exceptions | Zero-cost on the happy path; explicit error handling at every boundary |
| Two database connections | Sync tasks hold transactions for seconds; a dedicated connection prevents blocking route handlers |
| Shared io_context, `Server.start(0)` | One thread pool for HTTP and timers; clean shutdown via `IOContext->stop()` |
| `scheduleRecurringTask` free function | No scheduler class to maintain; timer ownership is explicit via `shared_ptr<steady_timer>` |
| Per-component named loggers | Isolates log output per subsystem; `server.log` and `github_sync.log` can be tailed independently |
| Non-TLS HTTP server | TLS termination belongs to a reverse proxy (nginx, Caddy) in production deployments |

## Debugging Tips

### Database Errors

Set `LOG_LEVEL=debug` in `.env` to see full SQL queries and libpqxx error messages. The
`/health` endpoint pings the database and reports connection failures without exposing
connection strings.

### Sync Task Failures

Background task output goes to `{LOG_DIR}/github_sync.log` (and stdout). If `LOG_DIR` is not
set, only stdout is used. Tail the log during a sync run:

```bash
tail -f /path/to/logs/github_sync.log
```

The GitHub sync fires immediately on startup (`InitialDelay = seconds(0)`), so any
misconfiguration (bad token, network issue) will appear in the log within seconds of starting
the server.

### Route Not Found

Call `GET /routes` on the running server to get a machine-readable list of all registered
paths and methods. This is faster than grepping source files and reflects the exact state of
the live router.

### Per-Component Log Files

Each named logger writes to its own file under `LOG_DIR`:

| Logger name | File |
|-------------|------|
| `server` | `{LOG_DIR}/server.log` |
| `github_sync` | `{LOG_DIR}/github_sync.log` |

All loggers also write to shared stdout. Log level is controlled globally by the `LOG_LEVEL`
environment variable. Logs flush immediately on `warn` or above, and flush automatically
every second otherwise.
