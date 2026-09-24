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
FROM node:24-bookworm-slim AS frontend-build

WORKDIR /web

# Dependency metadata first so source edits do not invalidate npm's install layer.
COPY Dashboard/package.json Dashboard/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY Dashboard/ ./
RUN npm run build -- --output-path=/web-dist

# ================================
# Server build image
# ================================
FROM swift:6.3-noble AS build

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

# The Angular production output, added after the compile rather than before it so a frontend
# change does not invalidate the Swift build layer. The application builder emits browser
# artifacts in a nested directory; Vapor serves the stable /Public path. Read-only, so a
# compromised process cannot rewrite what it serves.
COPY --from=frontend-build /web-dist/browser/ ./Public/
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
