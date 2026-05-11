#!/bin/bash
# System discovery — scans for running services, listening ports, Docker containers,
# and common software. Generates services.conf for check-services.sh.
# Run manually or during install.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/services.conf}"
DISCOVERED=()

echo "=== Server Monitoring Discovery ==="
echo ""

add_service() {
    local name="$1" cmd="$2" priority="$3" label="$4"
    DISCOVERED+=("$name|$cmd|$priority|$label")
    echo "  [+] $label"
}

# --- Systemd services ---
echo "Scanning systemd services..."
declare -A KNOWN_SERVICES=(
    [nginx]="9|Nginx Web Server"
    [apache2]="9|Apache Web Server"
    [httpd]="9|Apache Web Server"
    [caddy]="9|Caddy Web Server"
    [postgresql]="8|PostgreSQL"
    [mysql]="8|MySQL"
    [mariadb]="8|MariaDB"
    [redis-server]="6|Redis"
    [redis]="6|Redis"
    [memcached]="6|Memcached"
    [mongod]="8|MongoDB"
    [docker]="7|Docker Engine"
    [containerd]="6|Containerd"
    [fail2ban]="6|Fail2ban"
    [ufw]="5|UFW Firewall"
    [sshd]="5|SSH Server"
    [postfix]="6|Postfix Mail"
    [dovecot]="6|Dovecot IMAP"
    [named]="7|BIND DNS"
    [unbound]="7|Unbound DNS"
    [haproxy]="9|HAProxy"
    [traefik]="9|Traefik Proxy"
    [grafana-server]="6|Grafana"
    [prometheus]="6|Prometheus"
    [elasticsearch]="7|Elasticsearch"
    [rabbitmq-server]="7|RabbitMQ"
    [cron]="5|Cron Scheduler"
    [crond]="5|Cron Scheduler"
)

for svc in "${!KNOWN_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        IFS='|' read -r priority label <<< "${KNOWN_SERVICES[$svc]}"
        add_service "$svc" "systemctl is-active --quiet $svc" "$priority" "$label"
    fi
done

# --- PM2 processes ---
echo "Scanning PM2 processes..."
if command -v pm2 &>/dev/null; then
    # Current user's PM2 processes
    while read -r pname; do
        [[ -n "$pname" ]] && add_service "pm2-$pname" "pm2 describe $pname >/dev/null 2>&1" 8 "PM2: $pname"
    done < <(pm2 jlist 2>/dev/null | python3 -c "import sys,json; procs=json.load(sys.stdin); [print(p['name']) for p in procs]" 2>/dev/null | head -5 || true)

    # Check for PM2 running under other users via systemd
    for unit in $(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -i pm2); do
        user=$(echo "$unit" | sed 's/pm2-//;s/\.service//')
        if [[ "$user" != "root" ]] && id "$user" &>/dev/null; then
            while read -r pname; do
                [[ -n "$pname" ]] && add_service "pm2-${user}-${pname}" "sudo -u $user pm2 describe $pname >/dev/null 2>&1" 8 "PM2($user): $pname"
            done < <(sudo -u "$user" pm2 jlist 2>/dev/null | python3 -c "import sys,json; procs=json.load(sys.stdin); [print(p['name']) for p in procs]" 2>/dev/null | head -5 || true)
        fi
    done
fi

# --- Docker containers ---
echo "Scanning Docker containers..."
if command -v docker &>/dev/null; then
    # Running containers
    while IFS=$'\t' read -r cname cimage; do
        [[ -n "$cname" ]] && add_service "docker-$cname" "docker inspect -f '{{.State.Running}}' $cname 2>/dev/null | grep -q true" 7 "Docker: $cname ($cimage)"
    done < <(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true)

    # Stopped containers with a restart policy (should be running but aren't)
    while IFS=$'\t' read -r cname cimage crestart; do
        [[ -z "$cname" ]] && continue
        # Skip if already discovered as running
        already=false
        for d in "${DISCOVERED[@]}"; do
            [[ "$d" == "docker-$cname|"* ]] && already=true && break
        done
        if ! $already && [[ "$crestart" != "no" ]]; then
            add_service "docker-$cname" "docker inspect -f '{{.State.Running}}' $cname 2>/dev/null | grep -q true" 8 "Docker: $cname ($cimage) [stopped]"
        fi
    done < <(docker ps -a --filter "status=exited" --filter "status=created" --format '{{.Names}}\t{{.Image}}\t{{.Label "com.docker.compose.service"}}' 2>/dev/null | while IFS=$'\t' read -r n i _; do
        restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2>/dev/null || echo "no")
        printf '%s\t%s\t%s\n' "$n" "$i" "$restart"
    done || true)
fi

# --- Listening TCP ports (detect web apps) ---
echo "Scanning listening ports..."
declare -A PORT_LABELS=(
    [80]="HTTP"
    [443]="HTTPS"
    [3000]="Web App :3000"
    [3001]="Web App :3001"
    [3002]="Web App :3002"
    [4000]="Web App :4000"
    [5000]="Web App :5000"
    [5432]="PostgreSQL"
    [3306]="MySQL"
    [6379]="Redis"
    [27017]="MongoDB"
    [8080]="Web App :8080"
    [8443]="Web App :8443"
    [9090]="Prometheus"
    [9200]="Elasticsearch"
)

while IFS= read -r line; do
    port=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f1 | rev)
    if [[ -n "${PORT_LABELS[$port]:-}" ]]; then
        # Only add HTTP-checkable ports (web apps), skip DB ports already covered by systemd
        case "$port" in
            3000|3001|3002|4000|5000|8080|8443)
                svc_name="http-port-$port"
                # Check if we already discovered something on this port
                already=false
                for d in "${DISCOVERED[@]}"; do
                    if [[ "$d" == *":$port"* ]]; then already=true; break; fi
                done
                if ! $already; then
                    add_service "$svc_name" "curl -sf --max-time 5 -o /dev/null http://localhost:$port" 7 "${PORT_LABELS[$port]}"
                fi
                ;;
        esac
    fi
done < <(ss -tlnp 2>/dev/null | grep LISTEN || true)

# --- Public HTTPS (check if server has a public domain) ---
echo "Checking for public domains..."
if command -v hostname &>/dev/null; then
    fqdn=$(hostname -f 2>/dev/null || true)
    if [[ -n "$fqdn" && "$fqdn" == *.* && "$fqdn" != *.local && "$fqdn" != *.localdomain ]]; then
        add_service "public-https" "curl -sf --max-time 10 -o /dev/null https://$fqdn" 9 "Public HTTPS ($fqdn)"
    fi
fi

# --- Write services.conf ---
echo ""
if [[ ${#DISCOVERED[@]} -eq 0 ]]; then
    echo "No services discovered. Creating empty services.conf."
    cat > "$OUTPUT" << 'EOF'
# Service monitoring configuration
# Format: name|check_command|priority|label
# Priority: 1 (low) to 10 (critical)
#
# Examples:
# nginx|systemctl is-active --quiet nginx|9|Nginx Web Server
# myapp|curl -sf --max-time 5 -o /dev/null http://localhost:3000|8|My Web App
# postgres|systemctl is-active --quiet postgresql|8|PostgreSQL
EOF
else
    echo "Discovered ${#DISCOVERED[@]} service(s). Writing to $OUTPUT"
    {
        echo "# Service monitoring configuration — generated by discover.sh"
        echo "# Format: name|check_command|priority|label"
        echo "# Priority: 1 (low) to 10 (critical)"
        echo "#"
        echo "# Review and edit this file, then restart the monitor."
        echo ""
        for entry in "${DISCOVERED[@]}"; do
            echo "$entry"
        done
    } > "$OUTPUT"
fi

# --- Suggest SUMMARY_SECTIONS ---
sections="uptime,load,ram,swap,disk,ssh,alerts"
command -v pm2 &>/dev/null && sections+=",pm2"
command -v docker &>/dev/null && sections+=",docker"
command -v nginx &>/dev/null || command -v caddy &>/dev/null && sections+=",webserver"
command -v psql &>/dev/null && sections+=",postgres"

echo ""
echo "Suggested SUMMARY_SECTIONS for .env:"
echo "  SUMMARY_SECTIONS=\"$sections\""
echo ""
echo "Discovery complete. Review $OUTPUT and edit as needed."
