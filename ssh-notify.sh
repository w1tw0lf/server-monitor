#!/bin/bash
# SSH login notification — called by PAM on session open.
# Must always exit 0 to never block SSH access.

# Only fire on session open, not close
if [[ "${PAM_TYPE:-}" != "open_session" ]]; then
    exit 0
fi

# Auto-detect install directory from script location
MONITOR_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source env directly (no exit on failure — must not block SSH)
if [[ -f "$MONITOR_DIR/.env" ]]; then
    source "$MONITOR_DIR/.env"
fi

if [[ -z "${GOTIFY_URL:-}" || -z "${GOTIFY_TOKEN:-}" ]]; then
    exit 0
fi

SERVER="${SERVER_NAME:-$(hostname)}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
LOGIN_USER="${PAM_USER:-unknown}"

# Get source IP: PAM_RHOST is primary, fall back to SSH_CONNECTION or who output
SOURCE_IP="${PAM_RHOST:-}"
if [[ -z "$SOURCE_IP" && -n "${SSH_CONNECTION:-}" ]]; then
    SOURCE_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
fi
if [[ -z "$SOURCE_IP" ]]; then
    SOURCE_IP=$(who --ips 2>/dev/null | grep "$LOGIN_USER" | tail -1 | awk '{print $NF}')
fi
SOURCE_IP="${SOURCE_IP:-unknown}"

# Send notification in background so SSH is not delayed
{
    curl -sfk --max-time 10 \
        "$GOTIFY_URL/message" \
        -H "X-Gotify-Key: $GOTIFY_TOKEN" \
        -F "title=[$SERVER] SSH Login: $LOGIN_USER" \
        -F "message=User: $LOGIN_USER
IP: $SOURCE_IP
Time: $TIMESTAMP" \
        -F "priority=5" \
        >/dev/null 2>&1
} &

exit 0
