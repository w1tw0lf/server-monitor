#!/bin/bash
# Install server monitoring suite.
# Run with: sudo bash install.sh
# Idempotent — safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/server-monitor"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi

echo "=== Server Monitoring Installer ==="

# --- Step 1: Copy scripts ---
echo "Installing scripts to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/notify.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/check-resources.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/check-services.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/ssh-notify.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/daily-summary.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/check-updates.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/discover.sh" "$INSTALL_DIR/"
chmod 755 "$INSTALL_DIR"/*.sh

# --- Step 2: Configure .env ---
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
    echo ""
    echo "=== Configuration ==="
    echo ""

    # Server name
    default_name=$(hostname)
    read -rp "Server name [$default_name]: " input_name
    server_name="${input_name:-$default_name}"

    # Gotify server address
    echo ""
    read -rp "Gotify server address (e.g. gotify.example.com): " gotify_host
    gotify_host="${gotify_host#http://}"
    gotify_host="${gotify_host#https://}"
    gotify_host="${gotify_host%/}"

    # Protocol
    echo ""
    read -rp "Use HTTPS? [Y/n]: " use_https
    if [[ "${use_https,,}" == "n" ]]; then
        gotify_url="http://$gotify_host"
    else
        gotify_url="https://$gotify_host"
    fi

    # API token
    echo ""
    read -rp "Gotify app token: " gotify_token

    cat > "$INSTALL_DIR/.env" << EOF
# Server identity (used as notification prefix)
SERVER_NAME="$server_name"

# Gotify notification server
GOTIFY_URL=$gotify_url
GOTIFY_TOKEN=$gotify_token

# Daily summary sections (comma-separated)
# Core: uptime,load,ram,swap,disk,ssh,alerts
# Optional (auto-detected): pm2,docker,systemd,nginx,caddy,postgres
SUMMARY_SECTIONS="uptime,load,ram,swap,disk,ssh,alerts"
EOF
    chmod 600 "$INSTALL_DIR/.env"
    echo ""
    echo "Configuration saved to $INSTALL_DIR/.env"
    echo "  Server name: $server_name"
    echo "  Gotify URL:  $gotify_url"
    echo ""
else
    # Ensure SERVER_NAME exists in older .env files
    if ! grep -q "SERVER_NAME" "$INSTALL_DIR/.env"; then
        default_name=$(hostname)
        read -rp "Server name [$default_name]: " input_name
        server_name="${input_name:-$default_name}"
        echo "SERVER_NAME=\"$server_name\"" >> "$INSTALL_DIR/.env"
        echo "Added SERVER_NAME=$server_name to existing .env"
    fi
    echo ".env already exists, skipping."
fi

# --- Step 3: Run discovery ---
echo ""
echo "Running service discovery..."
bash "$INSTALL_DIR/discover.sh" "$INSTALL_DIR/services.conf"
echo ""

if [[ -f "$INSTALL_DIR/services.conf" ]]; then
    echo "Generated services.conf:"
    echo "---"
    cat "$INSTALL_DIR/services.conf"
    echo "---"
    echo ""
    echo "Edit $INSTALL_DIR/services.conf to add/remove services."
elif [[ -f "$SCRIPT_DIR/services.conf.example" ]]; then
    cp "$SCRIPT_DIR/services.conf.example" "$INSTALL_DIR/services.conf"
    echo "No services discovered. Copied services.conf.example — edit it manually."
fi

# --- Step 4: Systemd units ---
echo "Creating systemd units..."

# Resource checks (every 5 min)
cat > /etc/systemd/system/server-monitor-resources.service << EOF
[Unit]
Description=Server resource monitoring
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/check-resources.sh
Nice=19
EOF

cat > /etc/systemd/system/server-monitor-resources.timer << 'EOF'
[Unit]
Description=Run server resource checks every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s

[Install]
WantedBy=timers.target
EOF

# Service checks (every 2 min)
cat > /etc/systemd/system/server-monitor-services.service << EOF
[Unit]
Description=Server service health monitoring
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/check-services.sh
Nice=19
EOF

cat > /etc/systemd/system/server-monitor-services.timer << 'EOF'
[Unit]
Description=Run server service checks every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
RandomizedDelaySec=15s

[Install]
WantedBy=timers.target
EOF

# Daily summary (07:00 SAST = 05:00 UTC)
cat > /etc/systemd/system/server-monitor-summary.service << EOF
[Unit]
Description=Server daily summary

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/daily-summary.sh
Nice=19
EOF

cat > /etc/systemd/system/server-monitor-summary.timer << 'EOF'
[Unit]
Description=Send server daily summary at 07:00 SAST

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Weekly update check (Mondays 08:00 SAST = 06:00 UTC)
cat > /etc/systemd/system/server-monitor-updates.service << EOF
[Unit]
Description=Server software update checker
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/check-updates.sh
Nice=19
EOF

cat > /etc/systemd/system/server-monitor-updates.timer << 'EOF'
[Unit]
Description=Check for software updates weekly (Monday 08:00 SAST)

[Timer]
OnCalendar=Mon *-*-* 06:00:00
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF

# --- Step 5: Enable and start timers ---
echo "Enabling systemd timers..."
systemctl daemon-reload
systemctl enable --now server-monitor-resources.timer
systemctl enable --now server-monitor-services.timer
systemctl enable --now server-monitor-summary.timer
systemctl enable --now server-monitor-updates.timer

# --- Step 6: PAM SSH notification ---
PAM_LINE="session optional pam_exec.so $INSTALL_DIR/ssh-notify.sh"
if ! grep -qF "ssh-notify.sh" /etc/pam.d/sshd; then
    echo "$PAM_LINE" >> /etc/pam.d/sshd
    echo "PAM SSH notification hook installed."
else
    echo "PAM SSH hook already configured."
fi

# --- Step 7: Create state directory ---
mkdir -p /tmp/server-monitor

# --- Step 8: Verify ---
echo ""
echo "=== Installation Complete ==="
echo ""
echo "Timers:"
systemctl list-timers server-monitor-* --no-pager
echo ""

# Test notification if .env is configured
if grep -q "your-app-token-here" "$INSTALL_DIR/.env" 2>/dev/null; then
    echo "Skipping test notification — edit $INSTALL_DIR/.env first, then run:"
    echo '  source '"$INSTALL_DIR"'/notify.sh && send_notification "$PREFIX Test" "Monitoring is working!" 2'
else
    echo "Sending test notification..."
    source "$INSTALL_DIR/notify.sh"
    send_notification "$PREFIX Monitoring Installed" "All monitoring scripts deployed and timers activated." 2
    echo "Test notification sent. Check your Gotify app!"
fi
