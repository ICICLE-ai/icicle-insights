# Two ways to produce the same runtime image:
#
#   default (`runtime`, the last stage)  builds the frontend and the server from source. This is
#                                        what `just build` and `docker compose` use.
#   `--target prebuilt`                  packages a server and frontend that were already built,
#                                        from `.ci-staging/`. CI uses it so the release build runs
#                                        once, in its own cached job, rather than again in here.
#
# Both finish on `runtime-base`, so the user, entrypoint and environment cannot drift apart.

# ================================
# Frontend build image
# ================================
# Debian rather than Alpine: Vite's bundler and Tailwind load native bindings, and the glibc
# builds are the ones every platform in deno.lock is known to have.
FROM denoland/deno:debian-2.9.7 AS frontend-build

WORKDIR /web

# Dependency metadata first so source edits do not invalidate the install layer. `--frozen`
# fails the build if deno.lock would change, rather than resolving something new at image time.
COPY web/package.json web/deno.lock ./
RUN deno install --frozen

COPY web/ ./

# Parent origins allowed to hand an embedded dashboard a token. Baked into the bundle at build time,
# because the page has to know before it has talked to anything. See
# docs/how-to/embed-in-tapisui.md.
ARG VITE_TRUSTED_PARENT_ORIGINS=https://icicleai.tapis.io
ENV VITE_TRUSTED_PARENT_ORIGINS=$VITE_TRUSTED_PARENT_ORIGINS
RUN deno task build

# ================================
# Server build image
# ================================
FROM swift:6.4-noble AS build

# Install OS updates
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev

# Set up a build area
WORKDIR /build

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
COPY ./Package.* ./
RUN swift package resolve \
        $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Only what SwiftPM reads, not `COPY . .`. Anything else copied here becomes part of the compile
# step's cache key, so a dashboard or documentation edit would re-run the Swift build. Tests is
# included because SwiftPM errors when a declared target's directory is missing, even building
# only the Insights product.
COPY Sources ./Sources
COPY Tests ./Tests

RUN mkdir /staging

# Build the application, with optimizations, with static linking, and using jemalloc
# N.B.: The static version of jemalloc is incompatible with the static Swift runtime.
RUN --mount=type=cache,target=/build/.build \
    swift build -c release \
        --product Insights \
        --static-swift-stdlib \
        -Xlinker -ljemalloc && \
    # Copy main executable to staging area
    cp "$(swift build -c release --show-bin-path)/Insights" /staging && \
    # Copy resources bundled by SPM to staging area
    find -L "$(swift build -c release --show-bin-path)" -regex '.*\.resources$' -exec cp -Ra {} /staging \;

# Switch to the staging area
WORKDIR /staging

# Copy static swift backtracer binary to staging area
RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

# The dashboard's static build, added after the compile rather than before it so a frontend
# change does not invalidate the Swift build layer. Vapor serves it from the stable /Public path.
# Read-only, so a compromised process cannot rewrite what it serves.
COPY --from=frontend-build /web/build/ ./Public/
RUN chmod -R a-w ./Public

# ================================
# Run image, shared by both targets
# ================================
FROM ubuntu:noble AS runtime-base

# Make sure all system packages are up to date, and install only essential packages.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
      libjemalloc2 \
      ca-certificates \
      tzdata \
# If your app or its dependencies import FoundationNetworking, also install `libcurl4`.
      # libcurl4 \
# If your app or its dependencies import FoundationXML, also install `libxml2`.
      # libxml2 \
    && rm -r /var/lib/apt/lists/*

# pg_dump, for the nightly database backup (Sources/Insights/Services/Backups/). pg_dump refuses
# to dump a server whose major version is newer than its own. Noble's own postgresql-client is 16
# and the database runs 18, so the client comes from PostgreSQL's apt repository instead, checked
# against its signing key. Keep PG_CLIENT_MAJOR at or above the server's major version: a newer
# pg_dump reads an older server, never the reverse.
#
# curl is only here to fetch the key, and is purged in the same layer so it adds nothing to the
# image. Pinning the key file by checksum with `ADD --checksum` was rejected: PGDG extends the
# key's expiry from time to time, which changes the file and would break every build until the
# checksum was updated. HTTPS to www.postgresql.org is what vouches for it, as in PGDG's own
# instructions.
#
# The layer is about 70 MB installed, and most of that is Perl: postgresql-client-common depends on
# it for Debian's pg_wrapper, which nothing here runs. Unpacking pg_dump alone from the .deb would
# save it, but leaves a binary apt does not know about, with libraries nothing keeps in step.
# Worth revisiting only if image size starts to matter.
ARG PG_CLIENT_MAJOR=18
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q install -y --no-install-recommends curl \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl --fail --silent --show-error --location \
      --output /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && . /etc/os-release \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
    && apt-get -q update \
    && apt-get -q install -y --no-install-recommends "postgresql-client-${PG_CLIENT_MAJOR}" \
    && apt-get -q purge -y --auto-remove curl \
    && rm -r /var/lib/apt/lists/*

# `pg_dump` resolves straight to the pinned major's binary rather than through Debian's
# pg_wrapper, which chooses among installed versions by rules of its own. The backup finds it on
# this PATH, which is the one variable it passes through to the child process.
ENV PATH=/usr/lib/postgresql/${PG_CLIENT_MAJOR}/bin:${PATH}

# Create a vapor user and group with /app as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

# Switch to the new home directory
WORKDIR /app

# Wraps the command: migrates first when this container is the one serving. See the script.
COPY --chown=vapor:vapor --chmod=755 docker-entrypoint.sh /app/docker-entrypoint.sh

# Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Production defaults as variables rather than flags on CMD, which is where this departs from
# Vapor's template. A `--env` flag outranks VAPOR_ENV in `Environment.detect`, and `--port`
# outranks SERVER_PORT, so pinning either on the command line would make this image ignore the
# variables every other process in the stack reads — `docker-compose.yml` and the container
# justfile both avoid the flags for exactly this reason. Override the ordinary way, with `-e`.
ENV VAPOR_ENV=production
ENV SERVER_PORT=8080

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to port 8080
EXPOSE 8080

# The entrypoint applies migrations when the command is `serve`, then execs the binary with
# whatever arguments it was given — so `queues`, `migrate` and the one-shot commands are
# unaffected by it.
#
# No flags on CMD. `serve` reads its hostname and port from SERVER_HOSTNAME and SERVER_PORT for
# the same reason VAPOR_ENV carries no `--env`: a command-line flag outranks the variable, so
# pinning one here would make this image quietly ignore what the rest of the stack is configured
# with.
ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["serve"]

# ================================
# CI: package an already-built server and frontend
# ================================
# `.ci-staging/` holds exactly what the `build` stage's /staging holds: the binary, the backtracer,
# any SwiftPM resource bundles, and Public/. The workflow builds it in a Swift container matching
# `build` above and carries it here as a tarball, because an artifact upload drops the executable
# bit.
#
# Public/ is made read-only here rather than trusted from the context: the context transfer
# resets directory modes, so a `chmod` in the workflow left the directory itself writable.
FROM runtime-base AS prebuilt
COPY --chown=vapor:vapor .ci-staging/ /app/
RUN chmod -R a-w /app/Public

# ================================
# Default: build everything from source
# ================================
# Last, so a build without `--target` produces this one.
FROM runtime-base AS runtime
COPY --from=build --chown=vapor:vapor /staging /app
