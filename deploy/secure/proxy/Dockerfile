# Pipelock egress proxy with GeoIP blocking + threat intelligence feeds.
# Extends the stock Pipelock image with:
#   - db-ip Lite country CIDR extraction (monthly refresh)
#   - Threat intelligence feed aggregation (daily refresh)
#
# Data sources:
#   GeoIP:  https://db-ip.com/db/download/ip-to-country-lite (CC BY 4.0)
#   Threats: HaGeZi TIF Medium, urlhaus-filter, phishing-filter

FROM ghcr.io/luckypipewrench/pipelock:latest AS pipelock-bin

FROM debian:bookworm-slim

# Install runtime dependencies for refresh-geodb + Squid CONNECT proxy
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      cron \
      curl \
      python3-yaml \
      squid \
    && rm -rf /var/lib/apt/lists/*

# Copy Pipelock binary from official image
COPY --from=pipelock-bin /pipelock /pipelock

# Copy refresh tooling and Squid ACL generator
COPY refresh-geodb.sh         /usr/local/bin/refresh-geodb
COPY refresh-threats.sh       /usr/local/bin/refresh-threats
COPY generate-squid-acls.sh   /usr/local/bin/generate-squid-acls
COPY entrypoint.sh            /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/refresh-geodb /usr/local/bin/refresh-threats \
             /usr/local/bin/generate-squid-acls /usr/local/bin/entrypoint

# Squid configuration and ACL directory
COPY squid.conf /etc/squid/squid.conf
RUN mkdir -p /etc/squid /var/spool/squid \
    && touch /etc/squid/acl-allowed-domains.txt \
             /etc/squid/acl-blocked-domains.txt \
             /etc/squid/acl-blocked-cidrs.txt

# Default blocked-countries list (can be overridden via bind mount)
COPY geo-blocked-countries.conf /etc/geogate/blocked-countries.conf

# Monthly cron: refresh GeoIP on the 2nd of each month at 03:00 UTC
# (db-ip publishes on the 1st; we wait a day for propagation)
COPY crontab /etc/cron.d/geodb-refresh
RUN chmod 0644 /etc/cron.d/geodb-refresh && crontab /etc/cron.d/geodb-refresh

# Directories for GeoIP data, threat feeds, and config
RUN mkdir -p /var/lib/geogate /var/lib/threatfeeds /config

EXPOSE 8888 3128

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
  CMD /pipelock healthcheck --addr 127.0.0.1:8888 && squid -k check

ENTRYPOINT ["/usr/local/bin/entrypoint"]
