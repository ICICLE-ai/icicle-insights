# Apple Container replacement for docker compose.
# Requires Apple Container 1.x and macOS 26 or later for custom networks.

container_image := "icicle-insights"
container_network := "icicle-insights"
container_db_image := "postgres:18-alpine"
container_db_volume := "icicle-insights-postgres"
container_db_name := "vapor_database"
container_db_user := "vapor_username"
container_db_password := "vapor_password"
container_valkey_image := "valkey/valkey:9-alpine"
container_valkey_volume := "icicle-insights-valkey"
container_build_dns_primary := env_var_or_default("CONTAINER_BUILD_DNS_PRIMARY", "75.75.75.75")
container_build_dns_secondary := env_var_or_default("CONTAINER_BUILD_DNS_SECONDARY", "75.75.76.76")

# Start Apple's container services.
container-runtime:
    container system start

# Start BuildKit with enough memory for Swift and explicit DNS for package resolution.
builder: container-runtime
    container builder status --quiet >/dev/null 2>&1 || container builder start --cpus 4 --memory 8g --dns '{{container_build_dns_primary}}' --dns '{{container_build_dns_secondary}}'

# Create persistent resources once. The data volumes survive `just clean`.
up: container-runtime
    container network list --quiet | grep -qx '{{container_network}}' || container network create '{{container_network}}'
    container volume list --quiet | grep -qx '{{container_db_volume}}' || container volume create '{{container_db_volume}}'
    container volume list --quiet | grep -qx '{{container_valkey_volume}}' || container volume create '{{container_valkey_volume}}'

# Build the application image.
# Override the CONTAINER_BUILD_DNS_* values if these resolvers are unavailable.
build: builder
    #!/bin/bash
    set -euo pipefail
    build_root="$PWD"
    mkdir -p "$build_root/.container"
    build_context="$(mktemp -d "$build_root/.container/build-context.XXXXXX")"
    trap 'rm -rf -- "$build_context"' EXIT
    cp Dockerfile Package.swift Package.resolved "$build_context/"
    cp -R Sources Tests Resources Public "$build_context/"
    cd "$build_context"
    container build --dns '{{container_build_dns_primary}}' --dns '{{container_build_dns_secondary}}' --tag '{{container_image}}' --file Dockerfile .

# Start PostgreSQL and wait until it accepts connections.
db: up
    container stop insights-db >/dev/null 2>&1 || true
    container delete insights-db >/dev/null 2>&1 || true
    container run --detach --name insights-db \
        --network '{{container_network}}' \
        --publish 127.0.0.1:5432:5432 \
        --volume '{{container_db_volume}}:/var/lib/postgresql' \
        --env POSTGRES_USER='{{container_db_user}}' \
        --env POSTGRES_PASSWORD='{{container_db_password}}' \
        --env POSTGRES_DB='{{container_db_name}}' \
        '{{container_db_image}}'
    @for i in $(seq 60); do container exec insights-db pg_isready -U '{{container_db_user}}' -d '{{container_db_name}}' >/dev/null 2>&1 && exit 0; sleep 0.5; done; echo 'PostgreSQL did not become ready; run: container logs insights-db' >&2; exit 1

# Start Valkey and wait until it answers. Append-only so queued jobs survive a restart.
valkey: up
    container stop insights-valkey >/dev/null 2>&1 || true
    container delete insights-valkey >/dev/null 2>&1 || true
    container run --detach --name insights-valkey \
        --network '{{container_network}}' \
        --publish 127.0.0.1:6379:6379 \
        --volume '{{container_valkey_volume}}:/data' \
        '{{container_valkey_image}}' valkey-server --appendonly yes
    @for i in $(seq 60); do container exec insights-valkey valkey-cli ping >/dev/null 2>&1 && exit 0; sleep 0.5; done; echo 'Valkey did not become ready; run: container logs insights-valkey' >&2; exit 1

# Apply migrations in a temporary one-shot container.
migrate-container: build
    container run --rm --name insights-migrate \
        --network '{{container_network}}' \
        --env-file .env \
        --env-file .env.container \
        --env DATABASE_HOST="$(container inspect insights-db | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        --env REDIS_HOST="$(container inspect insights-valkey | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        '{{container_image}}' migrate --yes

# Start the HTTP server.
start: build
    container stop insights-app >/dev/null 2>&1 || true
    container delete insights-app >/dev/null 2>&1 || true
    container run --detach --name insights-app \
        --network '{{container_network}}' \
        --publish 127.0.0.1:8080:8080 \
        --env-file .env \
        --env-file .env.container \
        --env DATABASE_HOST="$(container inspect insights-db | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        --env REDIS_HOST="$(container inspect insights-valkey | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        '{{container_image}}' serve --env production --hostname 0.0.0.0 --port 8080

# Drain the metrics queue.
queues: build
    container stop insights-queues >/dev/null 2>&1 || true
    container delete insights-queues >/dev/null 2>&1 || true
    container run --detach --name insights-queues \
        --network '{{container_network}}' \
        --env-file .env \
        --env-file .env.container \
        --env DATABASE_HOST="$(container inspect insights-db | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        --env REDIS_HOST="$(container inspect insights-valkey | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        '{{container_image}}' queues --queue metrics

# Dispatch scheduled work. Run exactly one scheduler.
scheduled: build
    container stop insights-scheduled >/dev/null 2>&1 || true
    container delete insights-scheduled >/dev/null 2>&1 || true
    container run --detach --name insights-scheduled \
        --network '{{container_network}}' \
        --env-file .env \
        --env-file .env.container \
        --env DATABASE_HOST="$(container inspect insights-db | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        --env REDIS_HOST="$(container inspect insights-valkey | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        '{{container_image}}' queues --scheduled

# Run the due-resource sweep once without waiting for the hourly scheduler.
collect-now: build
    container run --rm --name insights-collect-now \
        --network '{{container_network}}' \
        --env-file .env \
        --env-file .env.container \
        --env DATABASE_HOST="$(container inspect insights-db | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        --env REDIS_HOST="$(container inspect insights-valkey | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        '{{container_image}}' collect-resources

# Mark every active resource due, then run the resource sweep once.
collect-all-now: build
    container run --rm --name insights-collect-all-now \
        --network '{{container_network}}' \
        --env-file .env \
        --env-file .env.container \
        --env DATABASE_HOST="$(container inspect insights-db | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        --env REDIS_HOST="$(container inspect insights-valkey | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        '{{container_image}}' collect-resources --force

# Run the monthly account-level sweep once.
collect-accounts-now: build
    container run --rm --name insights-collect-accounts-now \
        --network '{{container_network}}' \
        --env-file .env \
        --env-file .env.container \
        --env DATABASE_HOST="$(container inspect insights-db | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        --env REDIS_HOST="$(container inspect insights-valkey | jq -r '.[0].status.networks[0].ipv4Address | split("/")[0]')" \
        '{{container_image}}' collect-accounts

# Recreate the complete local stack in Compose dependency order.
stack: stop db valkey migrate-container start queues scheduled

# Stop and remove stack containers while preserving database and queue data.
stop: container-runtime
    @for name in insights-scheduled insights-queues insights-app insights-valkey insights-db; do container stop "$name" >/dev/null 2>&1 || true; container delete "$name" >/dev/null 2>&1 || true; done

# Remove ephemeral stack resources while preserving both data volumes.
clean: stop
    container network delete '{{container_network}}' >/dev/null 2>&1 || true
