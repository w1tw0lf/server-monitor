#!/bin/bash
# Shared notification library — sourced by other monitoring scripts.
# Do not execute directly.

MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/tmp/server-monitor"

# Load environment
if [[ -f "$MONITOR_DIR/.env" ]]; then
    source "$MONITOR_DIR/.env"
fi

if [[ -z "$GOTIFY_URL" || -z "$GOTIFY_TOKEN" ]]; then
    echo "ERROR: GOTIFY_URL and GOTIFY_TOKEN must be set in $MONITOR_DIR/.env" >&2
    exit 1
fi

# Server name prefix for all notifications
PREFIX="[${SERVER_NAME:-$(hostname)}]"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Send a Gotify notification
# Usage: send_notification "title" "message" priority
send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-4}"

    curl -sfk --max-time 10 \
        "$GOTIFY_URL/message" \
        -H "X-Gotify-Key: $GOTIFY_TOKEN" \
        -F "title=$title" \
        -F "message=$message" \
        -F "priority=$priority" \
        >/dev/null 2>&1 || {
        echo "$(date '+%Y-%m-%d %H:%M:%S') FAILED: $title" >> "$STATE_DIR/notify-errors.log"
    }
}

# State management — prevents alert storms
is_alerting() {
    [[ -f "$STATE_DIR/alert-$1" ]]
}

set_alerting() {
    touch "$STATE_DIR/alert-$1"
}

clear_alerting() {
    if [[ -f "$STATE_DIR/alert-$1" ]]; then
        rm -f "$STATE_DIR/alert-$1"
        return 0  # was alerting
    fi
    return 1  # was not alerting
}

get_alert_time() {
    if [[ -f "$STATE_DIR/alert-$1" ]]; then
        date -r "$STATE_DIR/alert-$1" '+%H:%M:%S'
    fi
}

# Fail count helpers (for sustained-threshold checks like CPU)
get_fail_count() {
    local file="$STATE_DIR/count-$1"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo 0
    fi
}

increment_fail_count() {
    local file="$STATE_DIR/count-$1"
    local count
    count=$(get_fail_count "$1")
    echo $((count + 1)) > "$file"
}

reset_fail_count() {
    rm -f "$STATE_DIR/count-$1"
}
