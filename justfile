# ICICLE Insights task runner. `just` with no arguments lists everything.
# Local container stack recipes live in justfiles/apple-container.just.

set dotenv-load
set export

import 'justfiles/apple-container.just'

[private]
default:
    @just --list --list-heading $'ICICLE Insights\n'

# ---------------------------------------------------------------------------
# Swift
# ---------------------------------------------------------------------------

# Serve the API on http://127.0.0.1:8080 against local PostgreSQL and Valkey.
[group('swift')]
run:
    swift run Insights serve

# Apply every pending migration.
[group('swift')]
migrate:
    swift run Insights migrate --yes

# Roll back the most recent migration batch.
[group('swift')]
revert:
    swift run Insights migrate --revert --yes

# Serial is required: every suite shares the `test` database and migrates and
# reverts around itself.

# Run the test suite.
[group('swift')]
test:
    swift test --no-parallel

# Format Swift sources in place.
[group('swift')]
fmt:
    swift-format format -i -r -p Sources Tests Package.swift

# Report formatting problems without writing.
[group('swift')]
fmt-check:
    swift-format lint -r -p Sources Tests Package.swift

# ---------------------------------------------------------------------------
# Dashboard (SvelteKit, run with Deno, in web/)
# ---------------------------------------------------------------------------

# Install dashboard dependencies exactly as deno.lock records them.
[group('web')]
web-install:
    deno install --frozen --cwd web

# Serve the dashboard on http://localhost:5174, proxying /api to port 8080.
[group('web')]
web:
    deno task --cwd web dev

# Type-check the dashboard.
[group('web')]
web-check:
    deno task --cwd web check

# Run the dashboard unit tests.
[group('web')]
web-test:
    deno task --cwd web test

# Build the static dashboard into web/build.
[group('web')]
web-build:
    deno task --cwd web build

# Regenerate web/src/lib/api/schema.d.ts from the running API's OpenAPI document.
[group('web')]
web-types:
    deno task --cwd web api:types

# ---------------------------------------------------------------------------
# Operator commands
# ---------------------------------------------------------------------------

# Manage webhook tokens: init-key, rotate-key, issue, revoke, list.
[group('cli')]
token *args:
    swift run Insights service-token {{ args }}

# Sweep due resources now. Pass --force to mark every active resource due first.
[group('cli')]
collect *args:
    swift run Insights collect-resources {{ args }}

# Run the account-level sweep now.
[group('cli')]
collect-accounts:
    swift run Insights collect-accounts

# Run the Patra catalog discovery sweep now.
[group('cli')]
collect-patra-catalog:
    swift run Insights collect-patra-catalog
