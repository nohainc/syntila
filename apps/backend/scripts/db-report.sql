-- Database health report (read-only). Run on the VPS:
--   bash apps/backend/scripts/db-report.sh            (from the Mac)
--   sudo -u postgres psql -d syntila -f db-report.sql (on the server)
-- Every section says what a worrying result looks like.
\set QUIET on
\pset border 1
\pset null '-'
\pset footer off

\echo
\echo '== 1. Connections by state (idle in transaction should be 0 or tiny; the API ends such sessions after 30 s)'
SELECT application_name AS app, state, count(*) AS sessions,
       max(now() - state_change)::interval(0) AS oldest_in_state
  FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()
 GROUP BY 1, 2 ORDER BY 3 DESC;

\echo
\echo '== 2. Open transactions older than 5 s (long ones hold locks and block vacuum)'
SELECT pid, application_name AS app, state, (now() - xact_start)::interval(0) AS open_for,
       left(regexp_replace(query, '\s+', ' ', 'g'), 90) AS last_query
  FROM pg_stat_activity
 WHERE datname = current_database() AND xact_start < now() - interval '5 seconds' AND pid <> pg_backend_pid()
 ORDER BY xact_start;

\echo
\echo '== 3. Who is blocked by whom right now (should be empty)'
SELECT blocked.pid AS blocked_pid, left(regexp_replace(blocked.query, '\s+', ' ', 'g'), 60) AS blocked_query,
       blocking.pid AS blocking_pid, left(regexp_replace(blocking.query, '\s+', ' ', 'g'), 60) AS blocking_query,
       (now() - blocked.query_start)::interval(0) AS waiting
  FROM pg_stat_activity blocked
  JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid) ON true
  JOIN pg_stat_activity blocking ON blocking.pid = b.pid
 WHERE blocked.datname = current_database();

\echo
\echo '== 4. Cache hit ratio (below 0.99 on a warm server means shared_buffers or RAM is short)'
SELECT round(sum(heap_blks_hit)::numeric / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 4) AS table_hit_ratio,
       (SELECT round(sum(idx_blks_hit)::numeric / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0), 4) FROM pg_statio_user_indexes) AS index_hit_ratio,
       pg_size_pretty(pg_database_size(current_database())) AS database_size
  FROM pg_statio_user_tables;

\echo
\echo '== 5. Largest tables, with dead rows (dead_pct above ~20 means vacuum is behind)'
SELECT relname AS "table", pg_size_pretty(pg_total_relation_size(relid)) AS total, n_live_tup AS live_rows, n_dead_tup AS dead_rows,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       coalesce(to_char(greatest(last_autovacuum, last_vacuum), 'MM-DD HH24:MI'), 'never') AS last_vacuum
  FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 12;

\echo
\echo '== 6. Possible missing indexes: tables read mostly by sequential scan (only tables over 1000 rows count)'
SELECT relname AS "table", n_live_tup AS rows, seq_scan, coalesce(idx_scan, 0) AS idx_scan,
       round(seq_tup_read::numeric / nullif(seq_scan, 0)) AS rows_per_seq_scan
  FROM pg_stat_user_tables
 WHERE n_live_tup > 1000 AND seq_scan > 100 AND seq_scan > coalesce(idx_scan, 0)
 ORDER BY seq_tup_read DESC LIMIT 10;

\echo
\echo '== 7. Unused indexes (never scanned since statistics reset; unique and primary keys excluded; each costs every write)'
SELECT s.relname AS "table", s.indexrelname AS "index", pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
  FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
 WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
   AND pg_relation_size(s.indexrelid) > 64 * 1024
 ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT 10;
SELECT 'statistics since' AS note, coalesce(stats_reset::text, 'server start') AS value FROM pg_stat_database WHERE datname = current_database();

\echo
\echo '== 8. Deadlocks, conflicts and temp files since statistics reset (deadlocks should be 0)'
SELECT deadlocks, conflicts, temp_files, pg_size_pretty(temp_bytes) AS temp_size, xact_commit, xact_rollback
  FROM pg_stat_database WHERE datname = current_database();

\echo
\echo '== 9. Sequences close to their limit (int4 sequences over 50% used; should be empty)'
SELECT schemaname || '.' || sequencename AS sequence, last_value,
       round(100.0 * last_value / nullif(max_value, 0), 1) AS pct_used
  FROM pg_sequences WHERE last_value IS NOT NULL AND last_value > max_value / 2;

SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS has_pss \gset
\if :has_pss
\echo
\echo '== 10. Statements using the most total time (the first place to look when it feels slow)'
SELECT left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS query, calls,
       round(total_exec_time::numeric / 1000, 1) AS total_s, round(mean_exec_time::numeric, 2) AS mean_ms,
       round(max_exec_time::numeric) AS max_ms, rows
  FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
 ORDER BY total_exec_time DESC LIMIT 12;

\echo
\echo '== 11. Slowest single statements by mean time (calls above 20)'
SELECT left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS query, calls,
       round(mean_exec_time::numeric, 1) AS mean_ms, round(max_exec_time::numeric) AS max_ms
  FROM pg_stat_statements WHERE calls > 20 AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
 ORDER BY mean_exec_time DESC LIMIT 8;
\else
\echo
\echo '== 10-11. pg_stat_statements is not installed: run infra/vps/deploy-backend.sh to enable it'
\endif
\echo
