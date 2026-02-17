# signal-cli daemon for OpenClaw.
# Uses the Java-based distribution (not GraalVM native) for reliable
# WebSocket/provisioning support, especially under Rosetta on Apple Silicon.
# Runs in HTTP daemon mode on port 8080.

FROM eclipse-temurin:21-jre-jammy AS download

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG SIGNAL_CLI_VERSION=latest
RUN set -eux; \
    if [ "${SIGNAL_CLI_VERSION}" = "latest" ]; then \
      SIGNAL_CLI_VERSION="$(curl -Ls -o /dev/null -w '%{url_effective}' \
        https://github.com/AsamK/signal-cli/releases/latest | sed 's/.*\/v//')"; \
    fi; \
    echo "Downloading signal-cli ${SIGNAL_CLI_VERSION} (Java)..."; \
    curl -fSL -o /tmp/signal-cli.tar.gz \
      "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}.tar.gz"; \
    mkdir -p /opt/signal-cli; \
    tar xf /tmp/signal-cli.tar.gz -C /opt/signal-cli --strip-components=1; \
    rm /tmp/signal-cli.tar.gz

# ── Runtime ───────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-jammy

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl qrencode \
    && rm -rf /var/lib/apt/lists/*

COPY --from=download /opt/signal-cli /opt/signal-cli
RUN ln -s /opt/signal-cli/bin/signal-cli /usr/local/bin/signal-cli

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# signal-cli stores account keys here
VOLUME /data

ENV SIGNAL_CLI_DATA=/data
ENV SIGNAL_HTTP_HOST=0.0.0.0
ENV SIGNAL_HTTP_PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -sf http://localhost:8080/api/v1/check || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
