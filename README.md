# Server Monitor

A lightweight, dependency-free server monitoring suite for Linux. Watches system
resources, service health, SSH logins, and software updates, and pushes
notifications to either [Gotify](https://gotify.net/) or
[Slack](https://api.slack.com/messaging/webhooks) — your choice.

Everything runs as systemd timers — no daemons, no databases, no agents. Just
bash, `curl`, and a handful of common utilities (`vmstat`, `free`, `df`, `ss`).

## Features

- **Resource monitoring** — CPU, RAM, disk, and swap thresholds with recovery
  notifications. CPU is sustained (two consecutive failures over ~10 min) to
  avoid noise from short spikes.
- **Service health checks** — Configurable per-service checks via
  `services.conf`. Supports systemd units, Docker containers, PM2 processes,
  HTTP endpoints, or any arbitrary command.
- **SSH login alerts** — PAM hook fires a notification on every interactive SSH
  session with the user and source IP.
- **Daily summary** — Single morning digest with uptime, load, memory, disk,
  recent logins, and active alerts. Optional sections for PM2, Docker, systemd
  failures, web servers, and PostgreSQL are auto-included when detected.
- **Weekly update check** — Reports available updates for the system package
  manager (apt / dnf / pacman), Node.js LTS, PM2, Caddy, PostgreSQL, and the
  versions of other common runtimes (Python, Go, Redis, Docker images).
- **Auto-discovery** — `discover.sh` scans systemd, Docker, PM2, and listening
  ports to generate `services.conf` automatically.
- **Alert de-duplication** — State files in `/tmp/server-monitor` prevent alert
  storms. You get one alert when something breaks, one when it recovers.

## Requirements

- Linux with systemd
- bash 4+
- `curl`, `vmstat` (`procps`), `ss` (`iproute2`)
- One of:
  - A reachable Gotify server with an application token, or
  - A Slack incoming webhook URL

## Installation

```bash
git clone https://github.com/<your-user>/server-monitor.git
cd server-monitor
sudo bash install.sh
```

The installer will:

1. Copy scripts to `/opt/server-monitor`
2. Prompt for your server name, your notification provider (Gotify or Slack),
   and the matching credentials, writing them to `/opt/server-monitor/.env`
   (mode `600`)
3. Run `discover.sh` to populate `services.conf`
4. Install and enable four systemd timers
5. Add a PAM hook to `/etc/pam.d/sshd` for SSH login notifications
6. Send a test notification

Re-running `install.sh` is safe — it skips existing `.env` files and won't
duplicate the PAM hook.

## Configuration

### `.env`

```bash
SERVER_NAME="My Server"

# "gotify" or "slack"
NOTIFY_PROVIDER=gotify

# Used when NOTIFY_PROVIDER=gotify
GOTIFY_URL=https://gotify.example.com
GOTIFY_TOKEN=your-app-token-here

# Used when NOTIFY_PROVIDER=slack
# (form: https://hooks.slack.com/services/<workspace>/<channel>/<token>)
SLACK_WEBHOOK_URL=

SUMMARY_SECTIONS="uptime,load,ram,swap,disk,ssh,alerts"
```

- `SERVER_NAME` is prefixed to every notification title.
- `NOTIFY_PROVIDER` chooses where alerts are sent. Only the matching block of
  credentials is required; the other can stay blank.
- `SUMMARY_SECTIONS` controls the daily digest. Core sections are always
  available; optional ones (`pm2`, `docker`, `systemd`, `webserver`, `postgres`)
  only render if the relevant software is installed.

See `.env.example` for the full template.

### Slack setup

1. In Slack, go to **Apps → Build → Create New App → From scratch**, name it
   anything (e.g. *Server Monitor*), and pick a workspace.
2. Open **Incoming Webhooks**, toggle it on, click **Add New Webhook to
   Workspace**, and pick the channel that should receive alerts.
3. Copy the resulting `https://hooks.slack.com/services/...` URL into
   `SLACK_WEBHOOK_URL` and set `NOTIFY_PROVIDER=slack`.

Slack messages are formatted with a severity emoji derived from the alert
priority (red ≥ 8, yellow 5–7, green ≤ 4).

### Switching providers later

Edit `/opt/server-monitor/.env`, change `NOTIFY_PROVIDER`, and make sure the
matching credentials are filled in. No restart required — the next timer tick
picks it up.

### `services.conf`

Pipe-delimited, one service per line:

```
name|check_command|priority|label
```

- `check_command` runs in a shell; exit code 0 = healthy, anything else =
  alert. Anything you can express as a shell one-liner works.
- `priority` is 1–10 and maps to Gotify priority.

Examples:

```
nginx|systemctl is-active --quiet nginx|9|Nginx Web Server
api|curl -sf --max-time 5 -o /dev/null http://localhost:8080/health|8|API
postgres|systemctl is-active --quiet postgresql|8|PostgreSQL
mycontainer|docker inspect -f '{{.State.Running}}' mycontainer 2>/dev/null | grep -q true|7|Docker mycontainer
public|curl -sf --max-time 10 -o /dev/null https://example.com|9|Public Site
```

Re-run `discover.sh` anytime to regenerate the file from your current system
state.

## Timers

| Timer | Schedule | What it does |
| --- | --- | --- |
| `server-monitor-resources.timer` | every 5 min | CPU / RAM / disk / swap thresholds |
| `server-monitor-services.timer` | every 2 min | Reads `services.conf`, alerts on failures |
| `server-monitor-summary.timer` | daily, 05:00 UTC | Sends the morning digest |
| `server-monitor-updates.timer` | weekly, Mon 06:00 UTC | Reports available software updates |

Inspect with:

```bash
systemctl list-timers 'server-monitor-*'
journalctl -u server-monitor-resources.service --since today
```

The summary timer is set to 05:00 UTC (07:00 SAST). Adjust `OnCalendar` in
`/etc/systemd/system/server-monitor-summary.timer` for your timezone.

## Thresholds

Defined inline in `check-resources.sh`. Defaults:

| Metric | Threshold | Notes |
| --- | --- | --- |
| CPU | > 90 % | Must persist across two checks (~10 min) |
| RAM | > 85 % | Single sample |
| Disk (`/`) | > 80 % | Single sample |
| Swap | > 50 % | Single sample (only if swap is configured) |

## Files

```
install.sh             Installer — copies scripts, writes systemd units, adds PAM hook
discover.sh            Scans the system and generates services.conf
notify.sh              Shared library: send_notification + alert state helpers
check-resources.sh     CPU / RAM / disk / swap thresholds
check-services.sh      Health checks driven by services.conf
check-updates.sh       Weekly package and runtime update report
daily-summary.sh       Morning digest
ssh-notify.sh          PAM hook for SSH login alerts
.env.example           Template for /opt/server-monitor/.env
services.conf.example  Template service definitions
```

## Uninstall

```bash
sudo systemctl disable --now server-monitor-{resources,services,summary,updates}.timer
sudo rm /etc/systemd/system/server-monitor-*.{service,timer}
sudo systemctl daemon-reload

# Remove PAM hook
sudo sed -i '/ssh-notify\.sh/d' /etc/pam.d/sshd

sudo rm -rf /opt/server-monitor /tmp/server-monitor
```

## License

MIT
