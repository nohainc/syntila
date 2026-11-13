#!/usr/bin/env bash
# Nightly logical dump of the Syntila database to local disk. Hetzner Backups
# then capture a consistent copy (a raw image of a live PostgreSQL data dir
# is not guaranteed to be). Keeps the last KEEP_DAYS dumps.
set -Eeuo pipefail
dir=/var/backups/syntila
keep_days=${KEEP_DAYS:-7}
install -d -m 0700 -o postgres -g postgres "$dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
tmp="$dir/.syntila-$stamp.dump.partial"
sudo -u postgres pg_dump --format=custom --compress=6 --no-owner --file="$tmp" syntila
sudo -u postgres pg_restore --list "$tmp" >/dev/null          # verify the archive is readable
mv "$tmp" "$dir/syntila-$stamp.dump"
sudo -u postgres pg_dumpall --globals-only --no-role-passwords > "$dir/globals-$stamp.sql"
chown postgres:postgres "$dir/globals-$stamp.sql"; chmod 0600 "$dir/globals-$stamp.sql"
find "$dir" -maxdepth 1 \( -name 'syntila-*.dump' -o -name 'globals-*.sql' \) -mtime +"$keep_days" -delete
echo "dump ok: $dir/syntila-$stamp.dump ($(du -h "$dir/syntila-$stamp.dump" | cut -f1))"
