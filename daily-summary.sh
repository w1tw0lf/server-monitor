#!/bin/bash
# Daily server summary — runs at 07:00 via systemd timer.
# Sends a single Gotify message with key server metrics.
# Sections controlled by SUMMARY_SECTIONS in .env.

set -euo pipefail
source "$(dirname "$0")/notify.sh"

# Parse SUMMARY_SECTIONS (default: core sections only)
SECTIONS="${SUMMARY_SECTIONS:-uptime,load,ram,swap,disk,ssh,alerts}"

has_section() {
    [[ ",$SECTIONS," == *",$1,"* ]]
}

MESSAGE=""
add_line() { MESSAGE+="$1"$'\n'; }

# --- Core sections (always available) ---

if has_section "uptime"; then
    UPTIME=$(uptime -p | sed 's/^up //')
    add_line "Uptime: $UPTIME"
fi

if has_section "load"; then
    LOAD=$(awk '{print $1" / "$2" / "$3}' /proc/loadavg)
    add_line "Load: $LOAD"
fi

if has_section "ram"; then
    read -r mem_total mem_available <<< "$(free -m | awk '/^Mem:/ {print $2, $7}')"
    mem_used=$((mem_total - mem_available))
    mem_pct=$((mem_used * 100 / mem_total))
    add_line "RAM: ${mem_used}/${mem_total} MB (${mem_pct}%)"
fi

if has_section "swap"; then
    read -r swap_total swap_used <<< "$(free -m | awk '/^Swap:/ {print $2, $3}')"
    if (( swap_total > 0 )); then
        swap_pct=$((swap_used * 100 / swap_total))
        add_line "Swap: ${swap_used}/${swap_total} MB (${swap_pct}%)"
    else
        add_line "Swap: not configured"
    fi
fi

if has_section "disk"; then
    disk_pct=$(df / | awk 'NR==2 {print $5}')
    disk_used=$(df -h / | awk 'NR==2 {print $3}')
    disk_total=$(df -h / | awk 'NR==2 {print $2}')
    add_line "Disk: ${disk_used}/${disk_total} (${disk_pct})"
fi

if has_section "ssh"; then
    SSH_SESSIONS=$(who 2>/dev/null | wc -l)
    RECENT_LOGINS=$(last -n 5 -a 2>/dev/null | head -5 || echo "unavailable")
    add_line "SSH sessions: $SSH_SESSIONS"
    add_line ""
    add_line "Recent logins:"
    add_line "$RECENT_LOGINS"
fi

# --- Optional sections (only if configured AND software detected) ---

if has_section "pm2" && command -v pm2 &>/dev/null; then
    PM2_STATUS=$(pm2 jlist 2>/dev/null | \
        python3 -c "import sys,json; procs=json.load(sys.stdin); print(', '.join(f\"{p['name']} ({p['pm2_env']['status']})\" for p in procs))" 2>/dev/null || echo "unable to read")
    # Try common service users if current user has no processes
    if [[ "$PM2_STATUS" == "unable to read" || "$PM2_STATUS" == "" ]]; then
        for unit in $(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -i pm2); do
            user=$(echo "$unit" | sed 's/pm2-//;s/\.service//')
            if id "$user" &>/dev/null 2>&1; then
                PM2_STATUS=$(sudo -u "$user" pm2 jlist 2>/dev/null | \
                    python3 -c "import sys,json; procs=json.load(sys.stdin); print(', '.join(f\"{p['name']} ({p['pm2_env']['status']})\" for p in procs))" 2>/dev/null || echo "unable to read")
                [[ -n "$PM2_STATUS" && "$PM2_STATUS" != "unable to read" ]] && break
            fi
        done
    fi
    add_line ""
    add_line "PM2: $PM2_STATUS"
fi

if has_section "docker" && command -v docker &>/dev/null; then
    DOCKER_STATUS=$(docker ps --format '{{.Names}} ({{.Status}})' 2>/dev/null | paste -sd', ' || echo "unable to read")
    add_line ""
    add_line "Docker: $DOCKER_STATUS"
fi

if has_section "systemd"; then
    FAILED_UNITS=$(systemctl --failed --no-legend 2>/dev/null | head -5 || echo "none")
    add_line ""
    add_line "Failed systemd units:"
    if [[ -z "$FAILED_UNITS" ]]; then
        add_line "  none"
    else
        add_line "$FAILED_UNITS"
    fi
fi

if has_section "webserver"; then
    if command -v nginx &>/dev/null; then
        NGINX_STATUS=$(systemctl is-active nginx 2>/dev/null || echo "not running")
        add_line ""
        add_line "Nginx: $NGINX_STATUS"
    fi
    if command -v caddy &>/dev/null; then
        CADDY_STATUS=$(systemctl is-active caddy 2>/dev/null || echo "not running")
        add_line ""
        add_line "Caddy: $CADDY_STATUS"
    fi
fi

if has_section "postgres" && command -v psql &>/dev/null; then
    PG_STATUS=$(systemctl is-active postgresql 2>/dev/null || echo "not running")
    PG_SIZE=$(sudo -u postgres psql -t -c "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database;" 2>/dev/null | xargs || echo "unknown")
    add_line ""
    add_line "PostgreSQL: $PG_STATUS (total size: $PG_SIZE)"
fi

# --- Active alerts (always included) ---
if has_section "alerts"; then
    ALERTS=$(ls "$STATE_DIR"/alert-* 2>/dev/null | xargs -I{} basename {} | sed 's/^alert-/  - /' || echo "  none")
    add_line ""
    add_line "Active alerts:"
    add_line "$ALERTS"
fi

send_notification "$PREFIX Daily Summary" "$MESSAGE" 2
