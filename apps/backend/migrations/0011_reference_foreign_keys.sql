-- References that were plain text columns become foreign keys.
-- Rows that only make sense while their parent exists are removed with it.
ALTER TABLE account_execution_waiters
  ADD CONSTRAINT account_execution_waiters_run_id_fkey FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE NOT VALID;
ALTER TABLE account_execution_waiters
  ADD CONSTRAINT account_execution_waiters_work_request_id_fkey FOREIGN KEY (work_request_id) REFERENCES work_requests(id) ON DELETE CASCADE NOT VALID;
ALTER TABLE work_request_inputs
  ADD CONSTRAINT work_request_inputs_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE NOT VALID;
ALTER TABLE work_request_inputs
  ADD CONSTRAINT work_request_inputs_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES execution_workspaces(id) NOT VALID;
ALTER TABLE workspace_service_readiness
  ADD CONSTRAINT workspace_service_readiness_runtime_identity_id_fkey FOREIGN KEY (runtime_identity_id) REFERENCES workspace_runtime_identities(id) ON DELETE CASCADE NOT VALID;
ALTER TABLE workspace_service_readiness
  ADD CONSTRAINT workspace_service_readiness_session_id_fkey FOREIGN KEY (session_id) REFERENCES workspace_sessions(id) NOT VALID;
ALTER TABLE discussion_messages
  ADD CONSTRAINT discussion_messages_work_request_id_fkey FOREIGN KEY (work_request_id) REFERENCES work_requests(id) ON DELETE SET NULL NOT VALID;
