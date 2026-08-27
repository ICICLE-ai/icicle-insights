# Local stack on Apple Container. Mirrors docker-compose.yml service for service.
# Requires Apple Container 1.x and macOS 26 or later for user-defined networks.
#
# First run:  just dns   (once per machine, asks for an administrator password)
# Then:       just stack

image := "icicle-insights"
network := "icicle-insights"
domain := "icicle-insights"

db_image := "postgres:18-alpine"
db_volume := "icicle-insights-postgres"
db_name := "vapor_database"
db_user := "vapor_username"
db_password := "vapor_password"

valkey_image := "valkey/valkey:9-alpine"
valkey_volume := "icicle-insights-valkey"

# Port inside the container, and therefore the port in the http://app.icicle-insights URL.
app_port := env("APP_PORT", "80")
# Host side of the 127.0.0.1 mapping. macOS reserves ports below 1024 for root.
host_port := env("APP_HOST_PORT", "8080")

# Upstream resolvers for fetching Swift packages during a build. Unrelated to the
# container name resolution that `just dns` configures.
build_dns := env("CONTAINER_BUILD_DNS", "75.75.75.75")
build_dns_alt := env("CONTAINER_BUILD_DNS_ALT", "75.75.76.76")

# Environment for every application container, in precedence order. Repeated
# --env-file flags merge with the later file winning, and an explicit --env outranks
# both. So `.env` holds the credentials, `.env.container` overrides them with local
# values, and the DNS names always apply. `.env` must exist: a missing --env-file is
# an error, not a skipped file.
env_files := "--env-file .env --env-file .env.container"
env_hosts := "--env DATABASE_HOST=db." + domain + " --env REDIS_HOST=valkey." + domain
app_env := env_files + " " + env_hosts

# Stop and delete a container, ignoring one that is not there.
[private]
rm name:
    @container stop {{ name }} >/dev/null 2>&1 || true
    @container delete {{ name }} >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Start Apple's container services.
[group('setup')]
runtime:
    container system start

# Needed once per machine, before the first `just stack`. Asks for an administrator
# password and restarts the container service, stopping everything running.

# Register the local DNS domain so containers reach each other by name.
[group('setup')]
dns:
    #!/usr/bin/env bash
    set -euo pipefail
    config="$HOME/.config/container/config.toml"
    mkdir -p "$(dirname "$config")"
    # The service reads its default domain at startup, so this edit precedes the restart.
    if ! grep -q '^\[dns\]' "$config" 2>/dev/null; then
        printf '\n[dns]\ndomain = "%s"\n' '{{ domain }}' >> "$config"
        echo "Added [dns] domain = \"{{ domain }}\" to $config"
    fi
    container system stop
    container system start
    # Writes /etc/resolver/{{ domain }} so the host resolves the domain too, not just
    # the containers.
    if container system dns list --quiet 2>/dev/null | grep -qx '{{ domain }}'; then
        echo "DNS domain '{{ domain }}' already registered."
    else
        sudo container system dns create '{{ domain }}'
    fi
    container system property list | grep -A1 '^\[dns\]'

# Host configuration rather than project data, so it is separate from `just destroy`.

# Unregister the local DNS domain.
[group('setup')]
dns-delete:
    #!/usr/bin/env bash
    set -euo pipefail
    if container system dns list --quiet 2>/dev/null | grep -qx '{{ domain }}'; then
        sudo container system dns delete '{{ domain }}'
    else
        echo "DNS domain '{{ domain }}' is not registered."
    fi
    echo "The [dns] section remains in ~/.config/container/config.toml. Remove it by hand"
    echo "to unset the default domain."

# Start BuildKit with enough memory for a Swift build and explicit resolvers.
[group('setup')]
builder: runtime
    @container builder status --quiet >/dev/null 2>&1 \
      || container builder start --cpus 4 --memory 8g \
           --dns '{{ build_dns }}' --dns '{{ build_dns_alt }}'

# Create the network and both data volumes. They survive `just clean`.
[group('setup')]
up: runtime
    @container network list --quiet | grep -qx '{{ network }}' || container network create '{{ network }}'
    @container volume list --quiet | grep -qx '{{ db_volume }}' || container volume create '{{ db_volume }}'
    @container volume list --quiet | grep -qx '{{ valkey_volume }}' || container volume create '{{ valkey_volume }}'
    @container system dns list --quiet 2>/dev/null | grep -qx '{{ domain }}' \
      || echo "warning: DNS domain '{{ domain }}' is not registered. Run 'just dns' first." >&2

# ---------------------------------------------------------------------------
# Image and containers
# ---------------------------------------------------------------------------

# The Dockerfile does `COPY . .`, so the context is assembled by hand. The Dashboard's
# node_modules is the wrong platform's binaries and hundreds of megabytes, and that cost
# lands before the builder ever reads .dockerignore.

# Build the application image.
[group('containers')]
build: builder
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "$PWD/.container"
    context="$(mktemp -d "$PWD/.container/build-context.XXXXXX")"
    trap 'rm -rf -- "$context"' EXIT
    # docker-entrypoint.sh belongs here because the Dockerfile COPYs it by name. Leaving it out
    # fails the build at that layer, not at `cd`, so the error names a cache key rather than the
    # missing file.
    cp Dockerfile .dockerignore Package.swift Package.resolved docker-entrypoint.sh "$context/"
    # Tests is included because SwiftPM errors when a declared target's directory
    # is missing, even building only the Insights product.
    cp -R Sources Tests Public "$context/"
    mkdir -p "$context/Dashboard"
    tar -cf - -C Dashboard --exclude=node_modules --exclude=dist --exclude=.angular . \
      | tar -xf - -C "$context/Dashboard"
    cd "$context"
    container build --dns '{{ build_dns }}' --dns '{{ build_dns_alt }}' \
      --tag '{{ image }}' --file Dockerfile .

# Start PostgreSQL and wait until it accepts connections.
[group('containers')]
db: up (rm "db")
    container run --detach --name db \
        --network '{{ network }}' \
        --publish 127.0.0.1:5432:5432 \
        --volume '{{ db_volume }}:/var/lib/postgresql' \
        --env POSTGRES_USER='{{ db_user }}' \
        --env POSTGRES_PASSWORD='{{ db_password }}' \
        --env POSTGRES_DB='{{ db_name }}' \
        '{{ db_image }}'
    @just await db "pg_isready -U {{ db_user }} -d {{ db_name }}"

# Start Valkey and wait until it answers. Append-only, so queued jobs survive a restart.
[group('containers')]
valkey: up (rm "valkey")
    container run --detach --name valkey \
        --network '{{ network }}' \
        --publish 127.0.0.1:6379:6379 \
        --volume '{{ valkey_volume }}:/data' \
        '{{ valkey_image }}' valkey-server --appendonly yes
    @just await valkey "valkey-cli ping"

# Reachable at http://app.icicle-insights and at http://127.0.0.1:8080. The image's
# `vapor` user cannot bind below 1024, so the bare URL needs --user root. Drop that
# override if APP_PORT moves above 1024.

# Serve the API and dashboard.
[group('containers')]
app: build (rm "app")
    container run --detach --name app \
        --user root \
        --network '{{ network }}' \
        --publish 127.0.0.1:{{ host_port }}:{{ app_port }} \
        {{ app_env }} \
        --env SERVER_PORT='{{ app_port }}' \
        '{{ image }}' serve

# Drain the metrics queue. This is what actually writes collected data.
[group('containers')]
queues: build (rm "queues")
    container run --detach --name queues \
        --network '{{ network }}' \
        {{ app_env }} \
        '{{ image }}' queues --queue metrics

# Dispatch scheduled work. Exactly one of these, ever.
[group('containers')]
scheduled: build (rm "scheduled")
    container run --detach --name scheduled \
        --network '{{ network }}' \
        {{ app_env }} \
        '{{ image }}' queues --scheduled

# Apply migrations in a one-shot container.
[group('containers')]
stack-migrate: build
    container run --rm --name migrate \
        --network '{{ network }}' \
        {{ app_env }} \
        '{{ image }}' migrate --yes

# Roll back the most recent migration batch in a one-shot container.
[group('containers')]
stack-revert: build
    container run --rm --name revert \
        --network '{{ network }}' \
        {{ app_env }} \
        '{{ image }}' migrate --revert --yes

# ---------------------------------------------------------------------------
# Collection, on demand
# ---------------------------------------------------------------------------
# Each of these only enqueues onto `metrics`, so `queues` has to be running or
# nothing is collected.

# Sweep the resources that are already due.
[group('collect')]
collect-now: build
    container run --rm --name collect-now \
        --network '{{ network }}' \
        {{ app_env }} \
        '{{ image }}' collect-resources

# Mark every active resource due, then sweep. Shifts every cadence forward.
[group('collect')]
collect-all-now: build
    container run --rm --name collect-all-now \
        --network '{{ network }}' \
        {{ app_env }} \
        '{{ image }}' collect-resources --force

# Run the monthly account sweep once.
[group('collect')]
collect-accounts-now: build
    container run --rm --name collect-accounts-now \
        --network '{{ network }}' \
        {{ app_env }} \
        '{{ image }}' collect-accounts

# ---------------------------------------------------------------------------
# Stack
# ---------------------------------------------------------------------------

# Recreate the whole stack, in dependency order.
[group('stack')]
stack: stop db valkey stack-migrate app queues scheduled

# Stop and remove the stack containers. Both data volumes survive.
[group('stack')]
stop: runtime
    @for name in scheduled queues app valkey db; do \
        container stop "$name" >/dev/null 2>&1 || true; \
        container delete "$name" >/dev/null 2>&1 || true; \
    done

# Remove the stack and its network. Both data volumes survive.
[group('stack')]
clean: stop
    @container network delete '{{ network }}' >/dev/null 2>&1 || true

# Irreversible. The PostgreSQL volume holds the collected metric history and the Valkey
# volume holds queued jobs. `just clean` is the non-destructive option. Set CONFIRM=yes
# to skip the prompt in a script.

# Delete everything: containers, both volumes, the network, the image, the builder.
[group('stack')]
destroy: runtime
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${CONFIRM:-}" != "yes" ]; then
        echo "About to delete volumes '{{ db_volume }}' and '{{ valkey_volume }}'."
        echo "All collected metrics and queued jobs will be lost."
        read -r -p "Type 'destroy' to continue: " reply
        [ "$reply" = "destroy" ] || { echo "Aborted."; exit 1; }
    fi
    # One-shot containers are --rm but survive a failed run. Volumes and images
    # cannot be deleted while a container still references them.
    for name in scheduled queues app valkey db migrate revert \
                collect-now collect-all-now collect-accounts-now; do
        container stop "$name" >/dev/null 2>&1 || true
        container delete --force "$name" >/dev/null 2>&1 || true
    done
    container volume delete '{{ db_volume }}' >/dev/null 2>&1 || true
    container volume delete '{{ valkey_volume }}' >/dev/null 2>&1 || true
    container network delete '{{ network }}' >/dev/null 2>&1 || true
    container image delete '{{ image }}' >/dev/null 2>&1 || true
    # Holds the Swift build cache, which is most of the reclaimable space.
    container builder delete --force >/dev/null 2>&1 || true
    echo "Destroyed. Remaining disk usage:"
    container system df

# Poll a container's readiness check until it passes.
[private]
await name check:
    @for i in $(seq 60); do \
        container exec {{ name }} {{ check }} >/dev/null 2>&1 && exit 0; \
        sleep 0.5; \
    done; \
    echo "{{ name }} did not become ready. Run: container logs {{ name }}" >&2; \
    exit 1
