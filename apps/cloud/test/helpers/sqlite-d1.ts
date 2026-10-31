import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync } from "node:fs";

class Statement {
  constructor(
    readonly db: DatabaseSync,
    readonly sql: string,
    readonly values: SQLInputValue[] = [],
  ) {}
  bind(...values: SQLInputValue[]) {
    return new Statement(this.db, this.sql, values);
  }
  async first<T>() {
    return (this.db.prepare(this.sql).get(...this.values) ?? null) as T | null;
  }
  async all<T>() {
    const statement = this.db.prepare(this.sql);
    if (statement.columns().length > 0)
      return {
        success: true,
        results: statement.all(...this.values) as T[],
        meta: { changes: 0 },
      };
    const result = statement.run(...this.values);
    return {
      success: true,
      results: [] as T[],
      meta: { changes: Number(result.changes) },
    };
  }
  run() {
    return this.all();
  }
}

export function sqliteD1(
  options: { beforeTurnLifecycleRepair?: boolean } = {},
) {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec(
    readFileSync(
      new URL("../../migrations-v8/0001_syntila_v8.sql", import.meta.url),
      "utf8",
    ),
  );
  sqlite.exec("PRAGMA foreign_keys = ON");
  for (const migration of [
    "0006_chat_workflow_admission.sql",
    "0009_realtime_stream_alignment.sql",
    "0010_conversation_workflows.sql",
    "0011_conversation_turns.sql",
    "0012_canonical_conversation_history.sql",
    "0013_worker_session_context.sql",
    "0014_exact_history_context.sql",
    "0015_conversation_workflow_runs.sql",
    "0016_workflow_step_runs.sql",
    "0018_user_workflow_configurations.sql",
    "0020_space_workflow_configurations.sql",
    "0022_workflow_workspace_selection.sql",
    "0023_people_relationships.sql",
    "0024_space_invitation_identity.sql",
    "0025_remove_invite_members_permission.sql",
    "0026_remove_attach_workspace_permission.sql",
    "0027_enable_workflow_workspace_workers.sql",
    "0028_workflow_default_selection.sql",
    "0037_immutable_execution_selection.sql",
    "0039_issue_reports.sql",
    "0040_issue_report_investigation.sql",
    "0041_full_local_access_profile_mappings.sql",
    "0042_codex_full_access_approval_conflict.sql",
    "0045_worker_activity_history.sql",
    "0046_worker_activity_metadata.sql",
    "0046_worker_catalog_profile_identity.sql",
    "0055_assignment_queue_deadline.sql",
    "0057_assignment_start_permit.sql",
    "0058_assignment_phase_timestamps.sql",
    "0059_service_readiness.sql",
    "0060_assignment_startup_progress.sql",
    "0061_assignment_workflow_signal.sql",
    ...(options.beforeTurnLifecycleRepair
      ? []
      : ["0062_conversation_turn_lifecycle.sql"]),
    "0064_thread_read_states.sql",
    "0065_thread_fencing_counter.sql",
    "0066_thread_metadata.sql",
    "0067_notification_reads.sql",
    "0068_user_pins.sql",
    "0069_user_pin_position.sql",
    "0070_workspace_parallel_slots.sql",
    "0071_assignment_engine_liveness.sql",
    "0072_workspace_scoped_workflow_configurations.sql",
    "0073_workspace_member_access.sql",
    "0074_workspace_member_overrides.sql",
    "0075_workspace_invitations.sql",
    "0076_person_grant_quota.sql",
    "0077_person_grant_run_time_quota.sql",
    "0078_discussion_ai_entries.sql",
    "0079_ai_history_cutoff.sql",
    "0080_discussion_attachments.sql",
    "0081_user_notes.sql",
    "0082_user_note_space_title.sql",
    "0083_copilot_worker.sql",
    "0084_grok_worker.sql",
    "0085_workspace_allowed_folders.sql",
    "0087_thread_history_permissions.sql",
    "0088_work_request_inputs.sql",
    "0089_reply_references.sql",
    "0090_released_workspace_cleanup.sql",
    "0091_thread_request_queue.sql",
    "0092_read_receipt_privacy.sql",
    "0094_account_plans.sql",
    "0095_desktop_session_device.sql",
    "0096_shared_workspace_chat_only.sql",
  ]) {
    sqlite.exec(
      readFileSync(
        new URL(`../../migrations-v8/${migration}`, import.meta.url),
        "utf8",
      ),
    );
  }
  let pendingBatch: Promise<unknown> = Promise.resolve();
  const adapter = {
    prepare(sql: string) {
      return new Statement(sqlite, sql);
    },
    batch(statements: Statement[]) {
      const operation = pendingBatch.then(async () => {
        sqlite.exec("BEGIN");
        try {
          const results = [];
          for (const statement of statements)
            results.push(await statement.all());
          sqlite.exec("COMMIT");
          return results;
        } catch (error) {
          sqlite.exec("ROLLBACK");
          throw error;
        }
      });
      pendingBatch = operation.catch(() => {});
      return operation;
    },
  };
  return { sqlite, db: adapter as unknown as D1Database };
}
