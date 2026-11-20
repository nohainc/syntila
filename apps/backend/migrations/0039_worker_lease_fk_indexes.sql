-- migrate:no-transaction
-- Indexes for the foreign keys added in 0037 (ADR-040).
CREATE INDEX CONCURRENTLY IF NOT EXISTS thread_runtime_leases_worker_instance_id_fkidx ON thread_runtime_leases (worker_instance_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS work_requests_primary_worker_instance_id_fkidx ON work_requests (primary_worker_instance_id);
