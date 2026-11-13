#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ]; then echo 'Run with sudo.' >&2; exit 1; fi
stage=/home/syntila/phase2-stage
for path in /opt/syntila /etc/syntila /etc/systemd/system/syntila-backend.service; do
  if [ -e "$path" ]; then echo "Refusing to overwrite existing $path" >&2; exit 1; fi
done
for path in "$stage/src/server.ts" "$stage/src/health.ts" "$stage/backend.env.example" "$stage/syntila-backend.service" /home/syntila/.bun/bin/bun; do
  if [ ! -f "$path" ]; then echo "Missing $path" >&2; exit 1; fi
done
read -r -s -p 'Existing PostgreSQL password for syntila_app: ' db_password < /dev/tty
printf '\n' > /dev/tty
if [ -z "$db_password" ]; then echo 'Password must not be empty.' >&2; exit 1; fi
install -d -m 0755 -o root -g root /opt/syntila /opt/syntila/src
install -m 0644 -o root -g root "$stage/src/"*.ts /opt/syntila/src/
install -d -m 0700 -o root -g root /etc/syntila
install -m 0644 -o root -g root "$stage/backend.env.example" /etc/syntila/backend.env
(umask 077; printf '%s' "$db_password" > /etc/syntila/postgres-password)
unset db_password
install -m 0644 -o root -g root "$stage/syntila-backend.service" /etc/systemd/system/syntila-backend.service
systemd-analyze verify /etc/systemd/system/syntila-backend.service
systemctl daemon-reload
systemctl enable --now syntila-backend.service
systemctl --no-pager --full status syntila-backend.service || true
for attempt in {1..15}; do
  if curl --silent --fail --max-time 1 http://127.0.0.1:3000/health/live >/dev/null; then break; fi
  sleep 1
done
printf '\nLive: '; curl --silent --show-error --max-time 5 http://127.0.0.1:3000/health/live || true
printf '\nReady: '; curl --silent --show-error --max-time 8 http://127.0.0.1:3000/health/ready || true
printf '\n'
