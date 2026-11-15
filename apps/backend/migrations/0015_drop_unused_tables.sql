-- Tables that nothing reads or writes any more.
--  - artifacts: written only by POST /api/workspaces/:id/artifacts, which no
--    client calls (removed with GET /api/artifacts/:id). Worker output files
--    are stored as user files. Its two history triggers go with it.
--  - workspace_service_readiness: written on every readiness change, never
--    read. Readiness is kept in the Workspace gateway and sent over realtime.
--  - worker_scheduling_audit: no code reads or writes it.
DROP TRIGGER trg_history_artifact_created ON artifacts;
DROP TRIGGER trg_history_artifact_removed ON artifacts;
DROP FUNCTION trg_history_artifact_created_fn();
DROP FUNCTION trg_history_artifact_removed_fn();
DROP TABLE artifacts;
DROP TABLE workspace_service_readiness;
DROP TABLE worker_scheduling_audit;
