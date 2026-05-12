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

NOTIFY_PROVIDER="${NOTIFY_PROVIDER:-gotify}"

# Bail silently if the chosen provider has no creds — must never block SSH.
case "$NOTIFY_PROVIDER" in
    gotify)   [[ -z "${GOTIFY_URL:-}" || -z "${GOTIFY_TOKEN:-}" ]] && exit 0 ;;
    slack)    [[ -z "${SLACK_WEBHOOK_URL:-}" ]] && exit 0 ;;
    telegram) [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && exit 0 ;;
    *)        exit 0 ;;
esac

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

TITLE="[$SERVER] SSH Login: $LOGIN_USER"
BODY="User: $LOGIN_USER
IP: $SOURCE_IP
Time: $TIMESTAMP"

# Send notification in background so SSH is not delayed
{
    case "$NOTIFY_PROVIDER" in
        gotify)
            curl -sfk --max-time 10 \
                "$GOTIFY_URL/message" \
                -H "X-Gotify-Key: $GOTIFY_TOKEN" \
                -F "title=$TITLE" \
                -F "message=$BODY" \
                -F "priority=5" \
                >/dev/null 2>&1
            ;;
        slack)
            # Inline JSON escape of BODY (newlines → \n, quotes → \")
            esc_body="${BODY//\\/\\\\}"
            esc_body="${esc_body//\"/\\\"}"
            esc_body="${esc_body//$'\n'/\\n}"
            curl -sfk --max-time 10 \
                -H "Content-Type: application/json" \
                -d "{\"text\":\"$(printf '\xf0\x9f\x9f\xa1') *$TITLE*\\n$esc_body\"}" \
                "$SLACK_WEBHOOK_URL" \
                >/dev/null 2>&1
            ;;
        telegram)
            # Inline HTML escape of BODY (&, <, > are special under parse_mode=HTML).
            # '\&' guards against bash's patsub_replacement (5.2+).
            esc_body="${BODY//&/\&amp;}"
            esc_body="${esc_body//</\&lt;}"
            esc_body="${esc_body//>/\&gt;}"
            esc_title="${TITLE//&/\&amp;}"
            esc_title="${esc_title//</\&lt;}"
            esc_title="${esc_title//>/\&gt;}"
            curl -sfk --max-time 10 \
                "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "parse_mode=HTML" \
                --data-urlencode "disable_web_page_preview=true" \
                --data-urlencode "text=$(printf '\xf0\x9f\x9f\xa1') <b>${esc_title}</b>
${esc_body}" \
                >/dev/null 2>&1
            ;;
    esac
} &

exit 0
