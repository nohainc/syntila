#!/usr/bin/env bash
# Deploys a built backend (apps/backend/dist + migrations) as a new release.
# Usage (on the VPS): sudo bash ~/phase3-stage/vps/deploy-backend.sh
# Stage layout: ~/phase3-stage/backend/{dist,migrations}, ~/phase3-stage/vps/*
set -Eeuo pipefail
export LC_ALL=C.UTF-8 LANG=C.UTF-8
if [ "$(id -u)" -ne 0 ]; then echo 'Run with sudo.' >&2; exit 1; fi
stage=/home/syntila/phase3-stage
bun=/home/syntila/.bun/bin/bun
for path in "$stage/backend/dist/server.js" "$stage/backend/dist/migrate.js" "$stage/backend/migrations/0001_initial.sql" "$stage/vps/syntila-backend.service" /etc/syntila/postgres-password /etc/syntila/auth-public-keys; do
  [ -e "$path" ] || { echo "Missing $path (build first: pnpm --dir apps/backend build)" >&2; exit 1; }
done

psql_pg() { sudo -u postgres psql -v ON_ERROR_STOP=1 -XAtq -d syntila "$@"; }
psql_pg -c "ALTER DATABASE syntila OWNER TO syntila_app; ALTER SCHEMA public OWNER TO syntila_app; REVOKE CREATE ON SCHEMA public FROM PUBLIC;"

# One-time pre-production reset: the Phase 3 prototype schema (0001_core.sql)
# is replaced by the ported schema (0001_initial.sql). No production data exists.
# Migration 0006 uses IS JSON, which needs PostgreSQL 16. Refuse early rather
# than fail half-way through the pending migrations.
pg_version=$(psql_pg -c "SHOW server_version_num")
if [ "$pg_version" -lt 160000 ]; then
  echo "PostgreSQL $pg_version is too old: the backend migrations need version 16 or newer. Not deploying." >&2; exit 1
fi

# A schema change cannot be undone by switching the code back, so take a
# verified dump before any release that carries new migrations.
applied=$(psql_pg -c "SELECT CASE WHEN to_regclass('schema_migrations') IS NULL THEN '' ELSE (SELECT COALESCE(string_agg(version, ' '), '') FROM schema_migrations) END")
pending=
for file in "$stage"/backend/migrations/[0-9][0-9][0-9][0-9]_*.sql; do
  name=$(basename "$file")
  case " $applied " in *" $name "*) ;; *) pending="$pending $name";; esac
done
if [ -n "$pending" ]; then
  echo "== Pending migrations:$pending"
  if [ -n "$applied" ]; then
    if [ -x /usr/local/lib/syntila/syntila-dump.sh ]; then
      echo '== Pre-migration dump'
      /usr/local/lib/syntila/syntila-dump.sh || { echo 'Pre-migration dump failed; not deploying.' >&2; exit 1; }
      echo "   Restore with: sudo -u postgres pg_restore --clean --if-exists -d syntila $(ls -1t /var/backups/syntila/syntila-*.dump | head -1)"
    elif [ "${ALLOW_MIGRATION_WITHOUT_DUMP:-}" = 1 ]; then
      echo 'WARNING: migrating without a dump (ALLOW_MIGRATION_WITHOUT_DUMP=1).' >&2
    else
      echo 'The dump tool is not installed (infra/vps/phase5). Install it, or set ALLOW_MIGRATION_WITHOUT_DUMP=1.' >&2; exit 1
    fi
  fi
fi

echo '== Environment'
while IFS= read -r line; do
  key=${line%%=*}
  case "$line" in ''|\#*) continue;; esac
  grep -q "^$key=" /etc/syntila/backend.env || printf '%s\n' "$line" >> /etc/syntila/backend.env
done < "$stage/vps/backend.env.example"

echo '== Release'
release=/opt/syntila/releases/$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 0755 "$release"
cp -r "$stage/backend/dist" "$stage/backend/migrations" "$release/"
chown -R root:root "$release"; chmod -R a+rX,go-w "$release"
previous=$(readlink -f /opt/syntila/current 2>/dev/null || true)
ln -sfn "$release" /opt/syntila/current.new && mv -T /opt/syntila/current.new /opt/syntila/current
install -m 0644 "$stage/vps/syntila-backend.service" /etc/systemd/system/syntila-backend.service
systemctl daemon-reload
systemctl enable syntila-backend.service >/dev/null
systemctl restart syntila-backend.service

ready=
for attempt in $(seq 1 40); do
  curl -fsS --max-time 2 http://127.0.0.1:3000/health/ready >/dev/null 2>&1 && { ready=1; break; }
  sleep 1
done
if [ -z "$ready" ]; then
  echo 'Backend did not become ready. Recent logs:' >&2
  journalctl -u syntila-backend -n 60 --no-pager >&2
  if [ -n "$previous" ] && [ -f "$previous/dist/server.js" ]; then
    echo "Rolling back to $previous" >&2
    ln -sfn "$previous" /opt/syntila/current && systemctl restart syntila-backend.service
  fi
  exit 1
fi
echo "Ready: $(curl -fsS http://127.0.0.1:3000/health/ready)"
if sudo -u syntila env $(grep -E '^(PGHOST|PGPORT|PGUSER|PGDATABASE)=' /etc/syntila/backend.env | xargs) PGPASSWORD="$(cat /etc/syntila/postgres-password)" \
     "$bun" "$release/dist/migrate.js" --verify; then :; else
  echo 'WARNING: the live schema differs from migrations/schema.lock (see above). The release is running; investigate the drift.' >&2
fi
echo "Unauthenticated API check: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/session) (expected 401)"
ls -1dt /opt/syntila/releases/* | tail -n +6 | xargs -r rm -rf
echo "Deployed $release"
