set dotenv-load
set export

default:
    @just --list

run:
    swift run

migrate:
    swift run Insights migrate --yes

revert:
    swift run Insights migrate --revert --yes

# Serial: every suite shares the `test` database and runs its own migrate/revert,
# so they must not run in parallel.
test:
    swift test --no-parallel

fmt:
    swift-format format -i -r -p Sources Tests Package.swift

fmt-check:
    swift-format lint -r -p Sources Tests Package.swift

# --- containers --------------------------------------------------------------
# Containers on a shared network resolve each other by name under `.test`. Needs macOS 26+.
# DATABASE_HOST is left out of `.env` so local runs fall back to localhost; recipes inject it.

image := "icicle-insights"
network := "icicle-insights"
db_image := "postgres:18-alpine"
db_host := "insights-db.test"
db_data := justfile_directory() / ".container/postgres"

build:
    container  build --tag {{image}} --file Dockerfile .

# Start the runtime and create the network. Idempotent.
up:
    container system start
    container network ls -q | grep -qx '{{network}}' || container network create '{{network}}'

# Postgres, also published to the host for `just test` and psql.
db: up
    mkdir -p '{{db_data}}'
    container run --detach --rm --name insights-db --network '{{network}}' --publish 5432:5432 --volume '{{db_data}}:/var/lib/postgresql/data' --env POSTGRES_USER="${DATABASE_USERNAME:-vapor_username}" --env POSTGRES_PASSWORD="${DATABASE_PASSWORD:-vapor_password}" --env POSTGRES_DB="${DATABASE_NAME:-vapor_database}" '{{db_image}}'
    for i in $(seq 60); do nc -z localhost 5432 && break; sleep 0.5; done

migrate-container: build
    container run --rm --name insights-migrate --network '{{network}}' --env-file .env --env DATABASE_HOST='{{db_host}}' '{{image}}' migrate --yes

start: build
    container run --detach --rm --name insights-app --network '{{network}}' --publish 8080:8080 --env-file .env --env DATABASE_HOST='{{db_host}}' '{{image}}' serve --env production --hostname 0.0.0.0 --port 8080

# Drains the metrics queue. `serve` does not run queued jobs, so without this nothing does.
queues: build
    container run --detach --rm --name insights-queues --network '{{network}}' --env-file .env --env DATABASE_HOST='{{db_host}}' '{{image}}' queues --queue metrics

# One instance only — a second scheduler dispatches every due resource twice.
scheduled: build
    container run --detach --rm --name insights-scheduled --network '{{network}}' --env-file .env --env DATABASE_HOST='{{db_host}}' '{{image}}' queues --scheduled

stack: db migrate-container start queues scheduled

stop:
    container stop insights-scheduled insights-queues insights-app insights-db || true

clean: stop
    container network delete '{{network}}' || true
