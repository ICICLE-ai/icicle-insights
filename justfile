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
# Dashboard
# ---------------------------------------------------------------------------

# Install dashboard dependencies from the lockfile.
[group('web')]
web-install:
    npm --prefix Dashboard ci

# Serve the dashboard on http://localhost:4200, proxying /api to port 8080.
[group('web')]
web:
    npm --prefix Dashboard start

# Run the dashboard unit tests.
[group('web')]
web-test:
    npm --prefix Dashboard test

# Build a production dashboard bundle.
[group('web')]
web-build:
    npm --prefix Dashboard run build

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
