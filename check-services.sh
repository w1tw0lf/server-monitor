#!/bin/bash
# Service health monitoring — runs every 2 minutes via systemd timer.
# Reads services.conf for the list of services to check.

set -euo pipefail
source "$(dirname "$0")/notify.sh"

NOW=$(date '+%Y-%m-%d %H:%M:%S')
SERVICES_CONF="$MONITOR_DIR/services.conf"

if [[ ! -f "$SERVICES_CONF" ]]; then
    echo "ERROR: $SERVICES_CONF not found. Run discover.sh or copy services.conf.example." >&2
    exit 1
fi

check_service() {
    local name="$1"
    local check_cmd="$2"
    local priority="$3"
    local label="$4"

    if eval "$check_cmd" >/dev/null 2>&1; then
        # Service is up
        if clear_alerting "svc-$name"; then
            send_notification "$PREFIX $label Recovered" "$label is responding normally. Checked at $NOW" 2
        fi
    else
        # Service is down
        if ! is_alerting "svc-$name"; then
            send_notification "$PREFIX $label DOWN" "$label health check failed at $NOW" "$priority"
            set_alerting "svc-$name"
        fi
    fi
}

# Read services.conf line by line
while IFS='|' read -r name cmd priority label; do
    # Skip comments and blank lines
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    # Trim whitespace
    name=$(echo "$name" | xargs)
    cmd=$(echo "$cmd" | xargs)
    priority=$(echo "$priority" | xargs)
    label=$(echo "$label" | xargs)

    [[ -z "$name" || -z "$cmd" ]] && continue
    check_service "$name" "$cmd" "${priority:-5}" "${label:-$name}"
done < "$SERVICES_CONF"
