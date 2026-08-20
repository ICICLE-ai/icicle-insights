# Apple Container replacement for docker compose.
# Requires Apple Container 1.x and macOS 26 or later for custom networks.
#
# Containers address each other by DNS name under `{{container_domain}}`, so run
# `just dns` once before the first `just stack-scheduled`. Names resolve to the
# container's current address on every connection, which an IP baked into the
# environment at launch does not: recreating `db` leaves such a value stale.

container_image := "icicle-insights"
container_network := "icicle-insights"
container_domain := "icicle-insights"
container_db_image := "postgres:18-alpine"
container_db_volume := "icicle-insights-postgres"
container_db_name := "vapor_database"
container_db_user := "vapor_username"
container_db_password := "vapor_password"
container_valkey_image := "valkey/valkey:9-alpine"
container_valkey_volume := "icicle-insights-valkey"
# Port inside the container, and therefore the port in the http://app.{{container_domain}} URL,
# which reaches the container's own address directly rather than through --publish below.
container_app_port := env_var_or_default("APP_PORT", "80")
# Host-side port for the 127.0.0.1 mapping. macOS reserves ports below 1024 for root, so this
# one stays high even though the container's is 80.
container_host_port := env_var_or_default("APP_HOST_PORT", "8080")
container_build_dns_primary := env_var_or_default("CONTAINER_BUILD_DNS_PRIMARY", "75.75.75.75")
container_build_dns_secondary := env_var_or_default("CONTAINER_BUILD_DNS_SECONDARY", "75.75.76.76")

# Environment shared by every application container, layered in precedence order.
#
# `.env` first: gitignored, and therefore the only place credentials belong. `.env.container`
# second, because repeated --env-file flags merge with the later file winning — which is what
# lets the tracked local defaults override the deployment database values `.env` carries without
# either file having to know about the other. The --env flags below outrank both regardless of
# where they appear, so the in-network DNS names always win.
#
# `.env` must exist: a missing --env-file is a hard error, not a skipped file. Copy .env.example.
# `.env.container` also carries VAPOR_ENV, which every process here reads. No recipe passes
# `--env` on a command line: that flag outranks the variable, so pinning it on `serve` alone is
# how the stack came to hold processes disagreeing about their own environment.
container_app_env := '--env-file .env --env-file .env.container' + \
  ' --env DATABASE_HOST=db.' + container_domain + \
  ' --env REDIS_HOST=valkey.' + container_domain

# Start Apple's container services.
container-runtime:
    container system start

# Prompts for an administrator password and restarts the container service, which stops
# every running container. Run once, before the first `just stack-scheduled`.
# Register the local DNS domain so containers resolve each other by name.
dns:
    #!/bin/bash
    set -euo pipefail
    config="$HOME/.config/container/config.toml"
    mkdir -p "$(dirname "$config")"
    # The service reads the default domain at startup, so the config edit must precede
    # the restart below.
    if ! grep -q '^\[dns\]' "$config" 2>/dev/null; then
        printf '\n[dns]\ndomain = "%s"\n' '{{container_domain}}' >> "$config"
        echo "Added [dns] domain = \"{{container_domain}}\" to $config"
    fi
    container system stop
    container system start
    # Writes /etc/resolver/{{container_domain}} so macOS routes the domain to the
    # embedded resolver. Without it names resolve between containers but not from the host.
    if container system dns list --quiet 2>/dev/null | grep -qx '{{container_domain}}'; then
        echo "DNS domain '{{container_domain}}' already registered."
    else
        sudo container system dns create '{{container_domain}}'
    fi
    # Confirms the service actually loaded the domain, rather than only that the
    # resolver file exists.
    container system property list | grep -A1 '^\[dns\]'

# The --dns values here are upstream nameservers for fetching Swift packages during the
# build, unrelated to the container name resolution configured by `just dns`.
# Start BuildKit with enough memory for Swift and explicit DNS for package resolution.
builder: container-runtime
    container builder status --quiet >/dev/null 2>&1 || container builder start --cpus 4 --memory 8g --dns '{{container_build_dns_primary}}' --dns '{{container_build_dns_secondary}}'

# Create persistent resources once. The data volumes survive `just clean`.
up: container-runtime
    container network list --quiet | grep -qx '{{container_network}}' || container network create '{{container_network}}'
    container volume list --quiet | grep -qx '{{container_db_volume}}' || container volume create '{{container_db_volume}}'
    container volume list --quiet | grep -qx '{{container_valkey_volume}}' || container volume create '{{container_valkey_volume}}'
    @container system dns list --quiet 2>/dev/null | grep -qx '{{container_domain}}' || echo "warning: DNS domain '{{container_domain}}' is not registered; run 'just dns' or containers will fail to resolve each other" >&2

# Override the CONTAINER_BUILD_DNS_* values if these resolvers are unavailable.
# Build the application image.
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
    container stop db >/dev/null 2>&1 || true
    container delete db >/dev/null 2>&1 || true
    container run --detach --name db \
        --network '{{container_network}}' \
        --publish 127.0.0.1:5432:5432 \
        --volume '{{container_db_volume}}:/var/lib/postgresql' \
        --env POSTGRES_USER='{{container_db_user}}' \
        --env POSTGRES_PASSWORD='{{container_db_password}}' \
        --env POSTGRES_DB='{{container_db_name}}' \
        '{{container_db_image}}'
    @for i in $(seq 60); do container exec db pg_isready -U '{{container_db_user}}' -d '{{container_db_name}}' >/dev/null 2>&1 && exit 0; sleep 0.5; done; echo 'PostgreSQL did not become ready; run: container logs db' >&2; exit 1

# Start Valkey and wait until it answers. Append-only so queued jobs survive a restart.
valkey: up
    container stop valkey >/dev/null 2>&1 || true
    container delete valkey >/dev/null 2>&1 || true
    container run --detach --name valkey \
        --network '{{container_network}}' \
        --publish 127.0.0.1:6379:6379 \
        --volume '{{container_valkey_volume}}:/data' \
        '{{container_valkey_image}}' valkey-server --appendonly yes
    @for i in $(seq 60); do container exec valkey valkey-cli ping >/dev/null 2>&1 && exit 0; sleep 0.5; done; echo 'Valkey did not become ready; run: container logs valkey' >&2; exit 1

# Apply migrations in a temporary one-shot container.
migrate-container: build
    container run --rm --name migrate \
        --network '{{container_network}}' \
        {{container_app_env}} \
        '{{container_image}}' migrate --yes

# Reachable at http://app.{{container_domain}} with no port, and at
# http://127.0.0.1:{{container_host_port}}. Override APP_PORT or APP_HOST_PORT to move either.
# The image's default `vapor` user cannot bind anything below 1024, so serving the bare URL
# requires overriding it with --user root; drop that override if APP_PORT moves above 1024.
# Start the HTTP server.
start: build
    container stop app >/dev/null 2>&1 || true
    container delete app >/dev/null 2>&1 || true
    container run --detach --name app \
        --user root \
        --network '{{container_network}}' \
        --publish 127.0.0.1:{{container_host_port}}:{{container_app_port}} \
        {{container_app_env}} \
        '{{container_image}}' serve --hostname 0.0.0.0 --port '{{container_app_port}}'

# Drain the metrics queue.
queues: build
    container stop queues >/dev/null 2>&1 || true
    container delete queues >/dev/null 2>&1 || true
    container run --detach --name queues \
        --network '{{container_network}}' \
        {{container_app_env}} \
        '{{container_image}}' queues --queue metrics

# Dispatch scheduled work. Run exactly one scheduler.
scheduled: build
    container stop scheduled >/dev/null 2>&1 || true
    container delete scheduled >/dev/null 2>&1 || true
    container run --detach --name scheduled \
        --network '{{container_network}}' \
        {{container_app_env}} \
        '{{container_image}}' queues --scheduled

# Run the due-resource sweep once without waiting for the hourly scheduler.
collect-now: build
    container run --rm --name collect-now \
        --network '{{container_network}}' \
        {{container_app_env}} \
        '{{container_image}}' collect-resources

# Mark every active resource due, then run the resource sweep once.
collect-all-now: build
    container run --rm --name collect-all-now \
        --network '{{container_network}}' \
        {{container_app_env}} \
        '{{container_image}}' collect-resources --force

# Run the monthly account-level sweep once.
collect-accounts-now: build
    container run --rm --name collect-accounts-now \
        --network '{{container_network}}' \
        {{container_app_env}} \
        '{{container_image}}' collect-accounts

# Recreate the complete local stack in Compose dependency order.
stack-scheduled: stop db valkey migrate-container start queues scheduled

stack-collect-all-now: stop db valkey migrate-container start queues collect-all-now


# The insights-* names predate the move to DNS-based addressing; they are listed so a
# stack started before that change is cleaned up rather than left running.
# Stop and remove stack containers while preserving database and queue data.
stop: container-runtime
    @for name in scheduled queues app valkey db insights-scheduled insights-queues insights-app insights-valkey insights-db; do container stop "$name" >/dev/null 2>&1 || true; container delete "$name" >/dev/null 2>&1 || true; done

# Remove ephemeral stack resources while preserving both data volumes.
clean: stop
    container network delete '{{container_network}}' >/dev/null 2>&1 || true

# Irreversible. The Postgres volume holds the collected metric history and the Valkey
# volume holds queued jobs; neither is recoverable afterwards. `just clean` is the
# non-destructive option. Set CONFIRM=yes to skip the prompt in scripts.
# Delete everything: containers, both data volumes, the network, the image, the builder.
destroy: container-runtime
    #!/bin/bash
    set -euo pipefail
    if [ "${CONFIRM:-}" != "yes" ]; then
        echo "About to delete volumes '{{container_db_volume}}' and '{{container_valkey_volume}}'."
        echo "All collected metrics and queued jobs will be lost."
        read -r -p "Type 'destroy' to continue: " reply
        [ "$reply" = "destroy" ] || { echo "Aborted."; exit 1; }
    fi
    # Long-lived containers first, then the one-shot names, which are `--rm` but survive
    # a failed run. Volumes and images cannot be deleted while a container references them.
    for name in scheduled queues app valkey db migrate collect-now collect-all-now collect-accounts-now \
                insights-scheduled insights-queues insights-app insights-valkey insights-db insights-migrate \
                insights-collect-now insights-collect-all-now insights-collect-accounts-now; do
        container stop "$name" >/dev/null 2>&1 || true
        container delete --force "$name" >/dev/null 2>&1 || true
    done
    container volume delete '{{container_db_volume}}' >/dev/null 2>&1 || true
    container volume delete '{{container_valkey_volume}}' >/dev/null 2>&1 || true
    container network delete '{{container_network}}' >/dev/null 2>&1 || true
    container image delete '{{container_image}}' >/dev/null 2>&1 || true
    # Holds the Swift build cache, which is the bulk of the reclaimable space.
    container builder delete --force >/dev/null 2>&1 || true
    echo "Destroyed. Remaining disk usage:"
    container system df

# Separate from `destroy` because this is host configuration rather than project data,
# and it needs an administrator password.
# Unregister the local DNS domain.
dns-delete:
    #!/bin/bash
    set -euo pipefail
    if container system dns list --quiet 2>/dev/null | grep -qx '{{container_domain}}'; then
        sudo container system dns delete '{{container_domain}}'
    else
        echo "DNS domain '{{container_domain}}' is not registered."
    fi
    echo "Note: the [dns] section remains in $HOME/.config/container/config.toml; remove it by hand if you want the default domain unset."
