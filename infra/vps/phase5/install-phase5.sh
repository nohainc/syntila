#!/usr/bin/env bash
# Phase 5: reliability — nightly local dump (for consistent Hetzner Backups),
# restore test, log rotation, swap, monitoring/alerts, resilience tests.
# Usage (on the VPS):  sudo bash ~/phase3-stage/vps/phase5/install-phase5.sh [--skip-resilience]
set -Eeuo pipefail
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if [ "$(id -u)" -ne 0 ]; then echo 'Run with sudo.' >&2; exit 1; fi
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ ! -f /opt/syntila/current/scripts/resilience.ts ]; then
  echo '== Deploying latest backend release (adds the resilience test script)'
  bash "$here/../install-phase3.sh"
fi

echo '== Scripts and units'
install -d -m 0755 /usr/local/lib/syntila
install -m 0755 "$here/syntila-monitor.py" "$here/syntila-dump.sh" "$here/restore-test.sh" "$here/run-resilience-test.sh" /usr/local/lib/syntila/
for unit in syntila-monitor.service syntila-monitor.timer syntila-dump.service syntila-dump.timer; do
  install -m 0644 "$here/$unit" /etc/systemd/system/
done
if [ ! -f /etc/syntila/monitor.env ]; then
  install -m 0600 "$here/monitor.env.example" /etc/syntila/monitor.env
  echo 'Created /etc/syntila/monitor.env — add an alert channel (see below).'
fi

echo '== Log rotation'
install -d /etc/systemd/journald.conf.d
install -m 0644 "$here/journald-syntila.conf" /etc/systemd/journald.conf.d/syntila.conf
systemctl restart systemd-journald
journalctl --disk-usage
# Caddy rolls its own access log (Caddyfile); PostgreSQL logs use Ubuntu's logrotate.
[ -f /etc/logrotate.d/postgresql-common ] && echo 'PostgreSQL logrotate: present'

echo '== Swap (protects PostgreSQL/Bun from the OOM killer during spikes)'
if [ "$(swapon --noheadings | wc -l)" -eq 0 ]; then
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  size=$(( mem_gb >= 8 ? 4 : 2 ))G
  fallocate -l "$size" /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  printf 'vm.swappiness=10\n' > /etc/sysctl.d/90-syntila-swap.conf && sysctl -q -p /etc/sysctl.d/90-syntila-swap.conf
  echo "Swap enabled: $size"
else
  swapon --show
fi

echo '== Timers'
systemctl daemon-reload
systemctl enable --now syntila-dump.timer syntila-monitor.timer >/dev/null
systemctl list-timers 'syntila-*' --no-pager

echo '== First dump + restore test'
systemctl start syntila-dump.service
journalctl -u syntila-dump -n 3 --no-pager -o cat
bash /usr/local/lib/syntila/restore-test.sh

echo '== Monitor (first run)'
python3 /usr/local/lib/syntila/syntila-monitor.py --verbose || true

if [ "${1:-}" != "--skip-resilience" ]; then
  echo '== Resilience tests (restarts the backend and PostgreSQL several times)'
  bash /usr/local/lib/syntila/run-resilience-test.sh
fi

cat <<'TXT'

Next:
  1. Add an alert channel to /etc/syntila/monitor.env (sudo nano /etc/syntila/monitor.env),
     then: sudo python3 /usr/local/lib/syntila/syntila-monitor.py --test-alert
  2. External uptime check of https://api.syntila.app/health/ready (UptimeRobot / Better Stack),
     and optionally HEARTBEAT_URL (healthchecks.io) to detect a dead VPS.
  3. Hetzner Console: enable Backups. Each daily image will contain the latest
     nightly dump (01:15 UTC) in /var/backups/syntila.
TXT
