#!/bin/bash
# System resource monitoring — runs every 5 minutes via systemd timer.
# Checks CPU, RAM, disk, and swap usage against thresholds.

set -euo pipefail
source "$(dirname "$0")/notify.sh"

# --- CPU (sustained: must fail 2 consecutive checks = 10 min) ---
# Use vmstat 1 2: first line is since-boot average, second is the 1-second sample
cpu_idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')
cpu_usage=$((100 - ${cpu_idle:-0}))

if (( cpu_usage > 90 )); then
    increment_fail_count "cpu"
    count=$(get_fail_count "cpu")
    if (( count >= 2 )) && ! is_alerting "cpu"; then
        send_notification "$PREFIX High CPU Usage" "CPU at ${cpu_usage}% for 10+ minutes. Threshold: 90%" 8
        set_alerting "cpu"
    fi
else
    reset_fail_count "cpu"
    if clear_alerting "cpu"; then
        send_notification "$PREFIX CPU Recovered" "CPU back to normal at ${cpu_usage}%" 2
    fi
fi

# --- RAM ---
read -r total available <<< "$(free -m | awk '/^Mem:/ {print $2, $7}')"
if (( total > 0 )); then
    ram_used=$((total - available))
    ram_pct=$((ram_used * 100 / total))

    if (( ram_pct > 85 )); then
        if ! is_alerting "ram"; then
            send_notification "$PREFIX High RAM Usage" "RAM at ${ram_pct}% (${ram_used}/${total} MB). Threshold: 85%" 8
            set_alerting "ram"
        fi
    else
        if clear_alerting "ram"; then
            send_notification "$PREFIX RAM Recovered" "RAM back to normal at ${ram_pct}% (${ram_used}/${total} MB)" 2
        fi
    fi
fi

# --- Disk ---
disk_pct=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
disk_used=$(df -h / | awk 'NR==2 {print $3}')
disk_total=$(df -h / | awk 'NR==2 {print $2}')

if (( disk_pct > 80 )); then
    if ! is_alerting "disk"; then
        send_notification "$PREFIX High Disk Usage" "Disk at ${disk_pct}% (${disk_used}/${disk_total}). Threshold: 80%" 6
        set_alerting "disk"
    fi
else
    if clear_alerting "disk"; then
        send_notification "$PREFIX Disk Recovered" "Disk back to normal at ${disk_pct}% (${disk_used}/${disk_total})" 2
    fi
fi

# --- Swap ---
read -r swap_total swap_used <<< "$(free -m | awk '/^Swap:/ {print $2, $3}')"
if (( swap_total > 0 )); then
    swap_pct=$((swap_used * 100 / swap_total))

    if (( swap_pct > 50 )); then
        if ! is_alerting "swap"; then
            send_notification "$PREFIX High Swap Usage" "Swap at ${swap_pct}% (${swap_used}/${swap_total} MB). Threshold: 50%" 6
            set_alerting "swap"
        fi
    else
        if clear_alerting "swap"; then
            send_notification "$PREFIX Swap Recovered" "Swap back to normal at ${swap_pct}% (${swap_used}/${swap_total} MB)" 2
        fi
    fi
fi
