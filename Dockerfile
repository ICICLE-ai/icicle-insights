# =============================================================================
# 1. GitHub Workers build the binary.
# 2. Build the Docker Image and copy the prebuilt binary over.
# 3. Push Image to Pods. 
# =============================================================================
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    libssl3 \
    libpq5 \
    libc++1-18 \
    libc++abi1-18 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY dist/icicle-insights ./icicle-insights

# Set up non-root user for security
RUN chmod +x ./icicle-insights && \
  useradd -m icicle && \
  mkdir -p /app/logs && \
  chown -R icicle:icicle /app
USER icicle

# Expose the default port (override with -e PORT=... at runtime)
EXPOSE 5000

# Health check — falls back to app default port if PORT is not set
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://${HOST:-localhost}:${PORT:-5000}/health || exit 1

CMD ["./icicle-insights"]
