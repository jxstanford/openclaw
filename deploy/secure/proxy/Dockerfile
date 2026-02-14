# Pipelock + GeoIP egress proxy.
# Extends the stock Pipelock image with MaxMind GeoLite2-Country
# CIDR extraction and weekly refresh via cron.

FROM ghcr.io/luckypipewrench/pipelock:latest AS pipelock-bin

FROM debian:bookworm-slim

# Install runtime dependencies for refresh-geodb
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      cron \
      curl \
      python3-yaml \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# Copy Pipelock binary from official image
COPY --from=pipelock-bin /pipelock /pipelock

# Copy refresh tooling
COPY refresh-geodb.sh /usr/local/bin/refresh-geodb
COPY entrypoint.sh    /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/refresh-geodb /usr/local/bin/entrypoint

# Default blocked-countries list (can be overridden via bind mount)
COPY geo-blocked-countries.conf /etc/geogate/blocked-countries.conf

# Weekly cron: refresh GeoIP every Sunday at 03:00 UTC
COPY crontab /etc/cron.d/geodb-refresh
RUN chmod 0644 /etc/cron.d/geodb-refresh && crontab /etc/cron.d/geodb-refresh

# Directories for GeoIP data and config
RUN mkdir -p /var/lib/geogate /config

EXPOSE 8888

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD ["/pipelock", "healthcheck", "--addr", "127.0.0.1:8888"]

ENTRYPOINT ["/usr/local/bin/entrypoint"]
