#!/bin/bash
# Shared notification library — sourced by other monitoring scripts.
# Do not execute directly.

MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/tmp/server-monitor"

# Load environment
if [[ -f "$MONITOR_DIR/.env" ]]; then
    source "$MONITOR_DIR/.env"
fi

# Notification provider — "gotify", "slack", or "telegram" (default: gotify)
NOTIFY_PROVIDER="${NOTIFY_PROVIDER:-gotify}"

case "$NOTIFY_PROVIDER" in
    gotify)
        if [[ -z "${GOTIFY_URL:-}" || -z "${GOTIFY_TOKEN:-}" ]]; then
            echo "ERROR: NOTIFY_PROVIDER=gotify but GOTIFY_URL/GOTIFY_TOKEN not set in $MONITOR_DIR/.env" >&2
            exit 1
        fi
        ;;
    slack)
        if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
            echo "ERROR: NOTIFY_PROVIDER=slack but SLACK_WEBHOOK_URL not set in $MONITOR_DIR/.env" >&2
            exit 1
        fi
        ;;
    telegram)
        if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
            echo "ERROR: NOTIFY_PROVIDER=telegram but TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not set in $MONITOR_DIR/.env" >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: NOTIFY_PROVIDER must be 'gotify', 'slack', or 'telegram' (got: '$NOTIFY_PROVIDER')" >&2
        exit 1
        ;;
esac

# Server name prefix for all notifications
PREFIX="[${SERVER_NAME:-$(hostname)}]"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Minimal JSON string escape (handles the cases that actually appear in our messages).
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# HTML entity escape for Telegram's parse_mode=HTML (only &, <, > are special).
# The '\&' guards against bash's patsub_replacement (5.2+), where a bare '&' in
# the replacement string means "the matched text".
_html_escape() {
    local s="$1"
    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    s="${s//>/\&gt;}"
    printf '%s' "$s"
}

# Map Gotify-style priority (1-10) to a colored-circle emoji (used by Slack & Telegram).
# Bytes are written explicitly so this file stays plain-ASCII.
_severity_emoji() {
    if   (( $1 >= 8 )); then printf '\xf0\x9f\x94\xb4'   # red circle
    elif (( $1 >= 5 )); then printf '\xf0\x9f\x9f\xa1'   # yellow circle
    else                     printf '\xf0\x9f\x9f\xa2'   # green circle
    fi
}

_send_gotify() {
    local title="$1" message="$2" priority="$3"
    curl -sfk --max-time 10 \
        "$GOTIFY_URL/message" \
        -H "X-Gotify-Key: $GOTIFY_TOKEN" \
        -F "title=$title" \
        -F "message=$message" \
        -F "priority=$priority" \
        >/dev/null 2>&1
}

_send_slack() {
    local title="$1" message="$2" priority="$3"
    local emoji payload
    emoji=$(_severity_emoji "$priority")
    payload="{\"text\":\"$emoji *$(_json_escape "$title")*\\n$(_json_escape "$message")\"}"
    curl -sfk --max-time 10 \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$SLACK_WEBHOOK_URL" \
        >/dev/null 2>&1
}

_send_telegram() {
    local title="$1" message="$2" priority="$3"
    local emoji
    emoji=$(_severity_emoji "$priority")
    curl -sfk --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" \
        --data-urlencode "text=${emoji} <b>$(_html_escape "$title")</b>
$(_html_escape "$message")" \
        >/dev/null 2>&1
}

# Send a notification via the configured provider.
# Usage: send_notification "title" "message" priority
send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-4}"

    case "$NOTIFY_PROVIDER" in
        gotify)   _send_gotify   "$title" "$message" "$priority" ;;
        slack)    _send_slack    "$title" "$message" "$priority" ;;
        telegram) _send_telegram "$title" "$message" "$priority" ;;
    esac || {
        echo "$(date '+%Y-%m-%d %H:%M:%S') FAILED ($NOTIFY_PROVIDER): $title" >> "$STATE_DIR/notify-errors.log"
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
