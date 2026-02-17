#!/usr/bin/env bash
set -euo pipefail

# signal-cli daemon entrypoint.
# Runs in HTTP daemon mode for OpenClaw.
#
# Modes:
#   SIGNAL_MODE=daemon  (default) — run the HTTP daemon
#   SIGNAL_MODE=link    — generate a device link URI (scan with Signal app)
#   SIGNAL_MODE=register — register a new number via SMS
#   SIGNAL_MODE=shell   — drop to shell for manual operations

DATA_DIR="${SIGNAL_CLI_DATA:-/data}"
HOST="${SIGNAL_HTTP_HOST:-0.0.0.0}"
PORT="${SIGNAL_HTTP_PORT:-8080}"
MODE="${SIGNAL_MODE:-daemon}"
ACCOUNT="${SIGNAL_ACCOUNT:-}"

mkdir -p "${DATA_DIR}"

case "${MODE}" in
  daemon)
    if [ -z "${ACCOUNT}" ]; then
      echo "[signal-cli] ERROR: SIGNAL_ACCOUNT not set (E.164 format, e.g. +15551234567)"
      echo "[signal-cli] Set SIGNAL_ACCOUNT in .env and restart."
      echo "[signal-cli] If you haven't registered yet, run with SIGNAL_MODE=link or SIGNAL_MODE=register"
      # Keep container alive for debugging
      sleep infinity
    fi

    echo "[signal-cli] Starting daemon for ${ACCOUNT} on ${HOST}:${PORT}"
    exec signal-cli \
      --config "${DATA_DIR}" \
      -a "${ACCOUNT}" \
      daemon \
      --http "${HOST}:${PORT}" \
      --no-receive-stdout \
      --receive-mode manual \
      --send-read-receipts
    ;;

  link)
    echo "[signal-cli] Generating device link..."
    echo "[signal-cli] Scan the QR code below with your Signal app:"
    echo "[signal-cli]   Signal > Settings > Linked Devices > Link New Device"
    echo ""
    # signal-cli link prints the sgnl:// URI to stdout, then blocks until
    # the primary device completes provisioning. Pipe through a reader that
    # renders a terminal QR code for easy scanning.
    signal-cli --config "${DATA_DIR}" link -n "OpenClaw" | while IFS= read -r line; do
      if [[ "${line}" == sgnl://* ]]; then
        echo "Link URI: ${line}"
        echo ""
        if command -v qrencode >/dev/null 2>&1; then
          qrencode -t ANSIUTF8 "${line}"
        fi
        echo ""
        echo "[signal-cli] Scan the QR code above, or open this URI on your phone."
      else
        echo "${line}"
      fi
    done
    echo ""
    echo "[signal-cli] Link complete. Set SIGNAL_MODE=daemon and restart."
    ;;

  register)
    if [ -z "${ACCOUNT}" ]; then
      echo "[signal-cli] ERROR: SIGNAL_ACCOUNT not set for registration"
      exit 1
    fi
    echo "[signal-cli] Registering ${ACCOUNT}..."
    echo "[signal-cli] If captcha required, visit: https://signalcaptchas.org/registration/generate.html"
    echo "[signal-cli] Then run: docker exec <container> signal-cli --config ${DATA_DIR} -a ${ACCOUNT} register --captcha '<URL>'"
    signal-cli --config "${DATA_DIR}" -a "${ACCOUNT}" register || true
    echo "[signal-cli] Waiting for verification code..."
    echo "[signal-cli] Run: docker exec <container> signal-cli --config ${DATA_DIR} -a ${ACCOUNT} verify <CODE>"
    sleep infinity
    ;;

  shell)
    echo "[signal-cli] Shell mode — run signal-cli commands manually."
    echo "[signal-cli] Data dir: ${DATA_DIR}"
    exec /bin/bash
    ;;

  *)
    echo "[signal-cli] Unknown SIGNAL_MODE: ${MODE}"
    echo "[signal-cli] Valid modes: daemon, link, register, shell"
    exit 1
    ;;
esac
