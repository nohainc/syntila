# VPS operations (Phase 5)

Single VPS, single PostgreSQL: every failure of that server is an outage.

No backups; the database can be recreated. A failed deploy rolls back the code;
a bad migration is fixed forward or the database is reset with the reset
command.

## Installed by `infra/vps/phase5/install-phase5.sh`

- `syntila-monitor.timer` (every 5 min) → `syntila-monitor.py`: disk and inodes
  (80 %/90 %), memory, postgresql/syntila-backend/caddy, failed units,
  backend restart loops, local and public `/health/ready`, TLS expiry
  (< 14 days), PostgreSQL connections. Alerts once
  on failure, reminds every 6 h, sends a recovery notice. Channels: ntfy,
  Slack, Telegram (`/etc/syntila/monitor.env`). Optional `HEARTBEAT_URL`
  dead-man's switch (healthchecks.io).
- journald capped at 2 GB / 30 days; Caddy rolls its access log (50 MB × 5);
  PostgreSQL logs use Ubuntu's logrotate.
- Swap file (2–4 GB, swappiness 10) if none existed.
- `run-resilience-test.sh` runs `dist/scripts/resilience.js` against the local
  backend with a live browser realtime socket and a paired Connect Worker
  (`syntila.worker-agent-protocol`), verifying graceful restart, `SIGKILL`
  recovery, session epoch advancement, and PostgreSQL restart recovery.
  The local `worker-agent-live` test additionally verifies an in-flight
  assignment completing across a backend restart with a fake Engine, and the
  two-node test checks database and outbox recovery. Neither replaces a real
  provider CLI run on a production device.

External uptime: monitor `https://api.syntila.app/health/ready` from outside
(UptimeRobot, Better Stack). An on-server monitor cannot report its own death.

## Runbooks

**Retire backups (one-time, on an existing VPS):**

```sh
sudo systemctl disable --now syntila-dump.timer
sudo rm -f /etc/systemd/system/syntila-dump.{service,timer}
sudo systemctl daemon-reload
sudo rm -f /usr/local/lib/syntila/syntila-dump.sh /usr/local/lib/syntila/restore-test.sh
sudo rm -rf /var/backups/syntila
sudo sed -i '/^DUMP_/d' /etc/syntila/monitor.env
```

**Client behaviour on restarts:** a deploy closes sockets with code 1012 and
the API is back within about a second; clients reconnect with backoff and
resync from their last `seq`. Connect Workers receive open assignments again
on reconnect; results are idempotent by assignment attempt.
