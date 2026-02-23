<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/logo-light.svg">
    <img src="assets/logo-light.svg" alt="ICICLE Insights Logo" width="700"/>
  </picture>

  <p><strong>A C++23 HTTP server for collecting and storing metrics about ICICLE project components</strong></p>

  <p>
    <a href="#overview">Overview</a> •
    <a href="#quick-start">Quick Start</a> •
    <a href="#api">API</a> •
    <a href="#deployment">Deployment</a> •
    <a href="#documentation">Documentation</a>
  </p>
</div>

---

## Overview

ICICLE Insights collects and stores metrics for the [ICICLE](https://icicle.osu.edu/) research project — tracking repositories and accounts across Git hosting platforms (GitHub) and container registries.

Metrics tracked include: **stars, forks, clones, views, watchers, followers**.

The server exposes a REST API for querying stored data and runs a background sync task every two weeks to pull fresh statistics from platform APIs.

## Prerequisites

- C++23 compiler (GCC 13+, Clang 17+, or Apple Clang 15+)
- [Conan 2.x](https://conan.io/)
- [CMake](https://cmake.org/) 3.25+
- [Ninja](https://ninja-build.org/)
- [just](https://just.systems/)
- PostgreSQL

## Quick Start

```bash
git clone https://github.com/guzman109/icicle-insights.git
cd icicle-insights
```

Create a `.env` file:

```bash
# Required
DATABASE_URL=postgresql://user:password@localhost:5432/icicle_insights
GITHUB_TOKEN=your_github_token

# Optional
HOST=127.0.0.1    # default: 127.0.0.1
PORT=3000         # default: 3000
LOG_LEVEL=info    # trace | debug | info | warn | error
SSL_CERT_FILE=    # path to CA bundle (macOS: /opt/homebrew/etc/ca-certificates/cert.pem)
```

Build and run:

```bash
just full-build   # install deps, configure, build
just run          # start the server on http://localhost:3000
```

## API

### Core

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Database connectivity check |
| `GET` | `/routes` | List all registered routes |

### GitHub Accounts

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/github/accounts` | List all accounts |
| `POST` | `/api/github/accounts` | Create an account |
| `GET` | `/api/github/accounts/:id` | Get account by ID |
| `DELETE` | `/api/github/accounts/:id` | Delete account |

### GitHub Repositories

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/github/repos` | List all repositories |
| `POST` | `/api/github/repos` | Create a repository |
| `GET` | `/api/github/repos/:id` | Get repository by ID |
| `PATCH` | `/api/github/repos/:id` | Update repository |
| `DELETE` | `/api/github/repos/:id` | Delete repository |

## Deployment

The CI/CD pipeline (GitHub Actions) builds the binary on `ubuntu-24.04`, packages it into a Docker image, and pushes to GHCR.

```bash
# Pull and run the latest image
docker pull ghcr.io/icicle-ai/insights:latest
docker run -p 3000:3000 --env-file .env ghcr.io/icicle-ai/insights:latest
```

To publish a release, push a version tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

This triggers the full pipeline: build → Docker image → GitHub Release with binary tarball.

### Local Docker build

```bash
just docker-build   # build image locally
just docker-run     # run with .env
```

## Development

### Common Commands

```bash
just deps          # Install Conan dependencies
just setup         # Configure CMake
just build         # Compile
just run           # Run the server
just full-build    # deps + setup + build
just clean-build   # wipe build dir and rebuild

just act-linux     # Test the linux CI job locally with act
just act-build     # Test the docker CI job locally with act
```

### Project Structure

```
.
├── include/insights/
│   ├── core/        # Config, error handling, logging, scheduler, HTTP status
│   ├── db/          # Database layer (Database struct, DbTraits, DbEntity concept)
│   ├── github/      # GitHub models, routes, and sync tasks
│   └── server/      # HTTP server setup and middleware
├── src/
│   ├── core/        # Health check and route listing endpoints
│   ├── github/      # Route handlers and sync task implementation
│   └── insights.cpp # Entry point
├── docs/            # Developer documentation
├── .github/
│   └── workflows/
│       └── build.yaml  # CI/CD: build → Docker → release
├── Dockerfile       # Runtime image (ubuntu:24.04)
├── conanfile.txt    # Conan dependencies
├── CMakeLists.txt   # Build configuration
└── justfile         # Build command runner
```

### Code Style

LLVM naming conventions throughout:

| Construct | Convention | Example |
|-----------|-----------|---------|
| Types | `PascalCase` | `Platform`, `HttpStatus` |
| Variables | `PascalCase` | `Database`, `Config` |
| Functions | `lowerCamelCase` | `registerRoutes()`, `syncStats()` |
| Enumerators | `PascalCase` | `Ok`, `BadRequest` |
| Members | `PascalCase` | `.Id`, `.Name`, `.AccountId` |

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| asio | 1.36.0 | Async I/O, timers, thread pool |
| openssl | — | TLS for outbound HTTP requests |
| glaze | main | HTTP server, router, JSON |
| libpqxx | 7.10.5 | PostgreSQL C++ client |
| spdlog | 1.17.0 | Structured logging |

## Documentation

- [Architecture](docs/architecture.md) — module structure, core patterns, data model, design decisions
- [Developer Guide](docs/README.md) — how to add routes, tasks, loggers; debugging tips

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).

## Acknowledgments

Part of the [ICICLE (Intelligent Cyberinfrastructure with Computational Learning in the Environment)](https://icicle.osu.edu/) initiative.
