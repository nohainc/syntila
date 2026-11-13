# VPS operations and recovery (Phase 5)

Single VPS, single PostgreSQL: every failure of that server is an outage, and
only backups prevent data loss. Recovery layers chosen for now:

| Layer | What | Recovery point | Notes |
| --- | --- | --- | --- |
| Hetzner Backups | daily full-disk image, 7 kept | ≤ 24 h | Restores the whole server. Enable in Hetzner Console → Server → Backups. |
| Nightly `pg_dump` | `/var/backups/syntila/syntila-*.dump`, 7 days | ≤ 24 h | Taken at 01:15 UTC, verified with `pg_restore --list`. Makes the Hetzner image database-consistent. |

**Known gaps (accepted for now):** both copies live at Hetzner, and up to
one day of messages can be lost. Before production cutover, consider off-site
WAL archiving (pgBackRest/WAL-G → R2) for point-in-time recovery.

## Installed by `infra/vps/phase5/install-phase5.sh`

- `syntila-dump.timer` → `/usr/local/lib/syntila/syntila-dump.sh` (also dumps roles without passwords).
- `restore-test.sh` → restores the latest dump into `syntila_restore_test`,
  checks migrations, row counts, gap-free thread event logs and references,
  then drops it. Run monthly: `sudo /usr/local/lib/syntila/restore-test.sh`.
- `syntila-monitor.timer` (every 5 min) → `syntila-monitor.py`: disk and inodes
  (80 %/90 %), memory, postgresql/syntila-backend/caddy, failed units,
  backend restart loops, local and public `/health/ready`, TLS expiry
  (< 14 days), PostgreSQL connections, dump freshness (< 26 h). Alerts once
  on failure, reminds every 6 h, sends a recovery notice. Channels: ntfy,
  Slack, Telegram (`/etc/syntila/monitor.env`). Optional `HEARTBEAT_URL`
  dead-man's switch (healthchecks.io).
- journald capped at 2 GB / 30 days; Caddy rolls its access log (50 MB × 5);
  PostgreSQL logs use Ubuntu's logrotate.
- Swap file (2–4 GB, swappiness 10) if none existed.
- `run-resilience-test.sh`: with a temporary signing key (removed afterwards),
  runs `apps/backend/scripts/resilience.ts` for a graceful restart and a
  SIGKILL crash — user and Workspace sockets must be closed, reconnect,
  the user must resync events committed while offline, the in-flight AI task
  must be redelivered and its result stored exactly once — and checks that the
  backend survives a PostgreSQL restart without restarting itself.

External uptime: monitor `https://api.syntila.app/health/ready` from outside
(UptimeRobot, Better Stack). An on-server monitor cannot report its own death.

## Runbooks

**Restore the database from the nightly dump (same server):**

```sh
sudo systemctl stop syntila-backend
sudo -u postgres psql -c "ALTER DATABASE syntila RENAME TO syntila_broken"
sudo -u postgres psql -c "CREATE DATABASE syntila OWNER syntila_app"
sudo -u postgres pg_restore --no-owner --role=syntila_app -d syntila /var/backups/syntila/syntila-<stamp>.dump
sudo systemctl start syntila-backend      # migrations run in ExecStartPre
curl -fsS http://127.0.0.1:3000/health/ready
# keep syntila_broken until verified, then: DROP DATABASE syntila_broken
```

**Server lost:** Hetzner Console → Backups → *Create server from backup* (or
restore onto the existing server), point the `api` DNS record at the new IP if
it changed, then check `systemctl status postgresql syntila-backend caddy`
and `/health/ready`. Restore from the dump above if the database in the image
is inconsistent.

**Restore drill to a separate environment (quarterly):** create a temporary
server from the latest Hetzner backup, run
`sudo /usr/local/lib/syntila/restore-test.sh` there, then delete the server.
Do not change DNS for the drill; Caddy will fail to obtain a certificate,
which is expected.

**Client behaviour on restarts:** a deploy closes sockets with code 1012 and
the API is back within about a second; clients reconnect with backoff and
resync from their last `seq`. Workspace Services receive all open tasks again
on reconnect; results are idempotent by `resultId`.
