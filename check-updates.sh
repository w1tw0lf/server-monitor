#!/bin/bash
# Software update checker — runs weekly via systemd timer.
# Auto-detects installed software and checks for available updates.

set -euo pipefail
source "$(dirname "$0")/notify.sh"

UPDATES=""
add_section() { UPDATES+="$1"$'\n'; }
add_item() { UPDATES+="  $1"$'\n'; }

# --- System packages (apt/dnf/yum) ---
if command -v apt &>/dev/null; then
    apt_updates=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
    security_updates=$(apt list --upgradable 2>/dev/null | grep -i security | grep -c upgradable || true)
    if (( apt_updates > 0 )); then
        add_section "📦 System Packages (apt): $apt_updates updates ($security_updates security)"
        apt list --upgradable 2>/dev/null | grep -v "^Listing" | head -10 | while read -r line; do
            add_item "$line"
        done
        if (( apt_updates > 10 )); then
            add_item "... and $((apt_updates - 10)) more"
        fi
    else
        add_section "📦 System Packages (apt): up to date"
    fi
elif command -v dnf &>/dev/null; then
    dnf_updates=$(dnf check-update --quiet 2>/dev/null | grep -c '.' || true)
    if (( dnf_updates > 0 )); then
        add_section "📦 System Packages (dnf): $dnf_updates updates available"
    else
        add_section "📦 System Packages (dnf): up to date"
    fi
elif command -v pacman &>/dev/null; then
    pac_updates=$(checkupdates 2>/dev/null | wc -l || true)
    if (( pac_updates > 0 )); then
        add_section "📦 System Packages (pacman): $pac_updates updates available"
        checkupdates 2>/dev/null | head -10 | while read -r line; do
            add_item "$line"
        done
    else
        add_section "📦 System Packages (pacman): up to date"
    fi
fi

# --- Node.js ---
if command -v node &>/dev/null; then
    current_node=$(node -v 2>/dev/null | sed 's/^v//' || echo "not found")
    latest_node=$(curl -sf --max-time 10 "https://nodejs.org/dist/index.json" | \
        python3 -c "import sys,json; releases=json.load(sys.stdin); lts=[r for r in releases if r.get('lts')]; print(lts[0]['version'].lstrip('v'))" 2>/dev/null || echo "unknown")
    if [[ "$latest_node" != "unknown" && "$current_node" != "$latest_node" ]]; then
        add_section "⬢ Node.js: $current_node → $latest_node available"
    else
        add_section "⬢ Node.js: $current_node (latest LTS)"
    fi
fi

# --- PM2 ---
if command -v pm2 &>/dev/null; then
    current_pm2=$(pm2 -v 2>/dev/null || echo "not found")
    latest_pm2=$(curl -sf --max-time 10 "https://registry.npmjs.org/pm2/latest" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "unknown")
    if [[ "$latest_pm2" != "unknown" && "$current_pm2" != "$latest_pm2" ]]; then
        add_section "🔄 PM2: $current_pm2 → $latest_pm2 available"
    else
        add_section "🔄 PM2: $current_pm2 (latest)"
    fi
fi

# --- Nginx ---
if command -v nginx &>/dev/null; then
    current_nginx=$(nginx -v 2>&1 | sed 's|.*/||' || echo "not found")
    add_section "🌐 Nginx: $current_nginx"
fi

# --- Caddy ---
if command -v caddy &>/dev/null; then
    current_caddy=$(caddy version 2>/dev/null | awk '{print $1}' | sed 's/^v//' || echo "not found")
    latest_caddy=$(curl -sf --max-time 10 "https://api.github.com/repos/caddyserver/caddy/releases/latest" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || echo "unknown")
    if [[ "$latest_caddy" != "unknown" && "$current_caddy" != "$latest_caddy" ]]; then
        add_section "🌐 Caddy: $current_caddy → $latest_caddy available"
    else
        add_section "🌐 Caddy: $current_caddy (latest)"
    fi
fi

# --- PostgreSQL ---
if command -v psql &>/dev/null; then
    current_pg=$(psql --version 2>/dev/null | awk '{print $3}' || echo "not found")
    major_pg=$(echo "$current_pg" | cut -d. -f1)
    latest_pg=$(curl -sf --max-time 10 "https://www.postgresql.org/versions.json" | \
        python3 -c "import sys,json; versions=json.load(sys.stdin); v=[v for v in versions if v['major']==$major_pg]; print(v[0]['latestMinor']) if v else print('unknown')" 2>/dev/null || echo "unknown")
    if [[ "$latest_pg" != "unknown" && "$current_pg" != *"$latest_pg"* ]]; then
        add_section "🐘 PostgreSQL: $current_pg → ${major_pg}.$latest_pg available"
    else
        add_section "🐘 PostgreSQL: $current_pg (latest)"
    fi
fi

# --- MySQL/MariaDB ---
if command -v mysql &>/dev/null && ! command -v psql &>/dev/null; then
    current_mysql=$(mysql --version 2>/dev/null | awk '{print $3}' || echo "not found")
    add_section "🗄️ MySQL/MariaDB: $current_mysql"
fi

# --- Redis ---
if command -v redis-server &>/dev/null; then
    current_redis=$(redis-server --version 2>/dev/null | awk '{print $3}' | sed 's/v=//' || echo "not found")
    add_section "🔴 Redis: $current_redis"
fi

# --- Docker ---
if command -v docker &>/dev/null; then
    current_docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "not found")
    add_section "🐳 Docker: $current_docker"

    # Check running containers for image updates
    outdated_containers=0
    while IFS=$'\t' read -r cname cimage; do
        [[ -z "$cname" ]] && continue
        local_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$cimage" 2>/dev/null | awk -F@ '{print $2}' || echo "")
        if [[ -n "$local_digest" ]]; then
            # Try pulling to check for updates (dry-run style)
            remote_digest=$(docker pull -q "$cimage" 2>/dev/null | tail -1 || echo "")
            if [[ -n "$remote_digest" && "$remote_digest" != "$local_digest" ]]; then
                add_item "$cname ($cimage): newer image available"
                ((outdated_containers++))
            fi
        fi
    done < <(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true)
    if (( outdated_containers == 0 )); then
        add_item "All container images up to date"
    fi
fi

# --- Python ---
if command -v python3 &>/dev/null; then
    current_python=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "not found")
    add_section "🐍 Python: $current_python"
fi

# --- Go ---
if command -v go &>/dev/null; then
    current_go=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || echo "not found")
    add_section "🔵 Go: $current_go"
fi

# --- Fail2ban ---
if command -v fail2ban-client &>/dev/null; then
    f2b_version=$(fail2ban-client version 2>/dev/null || echo "unknown")
    add_section "🛡️ Fail2ban: $f2b_version"
fi

# --- Determine priority ---
priority=2
if [[ -n "${security_updates:-}" ]] && (( security_updates > 0 )); then
    priority=6
elif [[ -n "${apt_updates:-}" ]] && (( apt_updates > 5 )); then
    priority=4
fi

# --- Send notification ---
TITLE="$PREFIX Software Update Check"
send_notification "$TITLE" "$UPDATES" "$priority"

echo "Update check complete. Notification sent."
