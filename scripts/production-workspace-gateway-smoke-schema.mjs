import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));

export const requiredProductionSmokeColumns = Object.freeze({
  workflow_tasks: [
    "id",
    "work_request_id",
    "step_kind",
    "execution_mode",
    "timeout_ms",
    "prompt_profile_version",
    "status",
    "attempt",
    "output_json",
    "error",
    "created_at",
    "updated_at",
    "started_at",
    "finished_at",
  ],
  conversation_workflow_step_runs: [
    "id",
    "workflow_run_id",
    "task_id",
    "step_id",
    "role",
    "created_at",
  ],
  conversation_workflow_runs: [
    "started_at",
    "completed_at",
    "id",
    "conversation_id",
    "user_message_id",
    "work_request_id",
    "workflow_id",
    "workflow_version",
    "created_at",
  ],
  conversation_history_entries: [
    "id",
    "conversation_id",
    "sequence",
    "schema_version",
    "kind",
    "event_type",
    "actor_type",
    "actor_id",
    "work_request_id",
    "turn_id",
    "artifact_id",
    "source_id",
    "text",
    "metadata_json",
    "deduplication_key",
    "occurred_at",
    "recorded_at",
  ],
  conversation_user_messages: [
    "id",
    "conversation_id",
    "work_request_id",
    "author_user_id",
    "text",
    "created_at",
  ],
  conversation_turns: [
    "workflow_step_run_id",
    "workflow_run_id",
    "id",
    "conversation_id",
    "user_message_id",
    "work_request_id",
    "assignment_id",
    "task_id",
    "step_kind",
    "workflow_id",
    "workflow_version",
    "worker_id",
    "worker_type_id",
    "worker_display_name",
    "profile_id",
    "profile_version",
    "model_id",
    "effort",
    "worker_session_id",
    "base_context_revision",
    "status",
    "started_at",
    "completed_at",
    "result_text",
    "created_at",
  ],
  conversations: [
    "id",
    "thread_id",
    "workflow_id",
    "workflow_version",
    "conversation_revision",
    "context_revision",
    "created_at",
    "updated_at",
    "context_floor_sequence",
  ],
  conversation_work_requests: [
    "conversation_id",
    "work_request_id",
    "conversation_revision",
  ],
  mutation_receipts: [
    "user_id",
    "scope",
    "idempotency_key",
    "request_hash",
    "response_json",
    "response_status",
    "created_at",
  ],
  users: [
    "id",
    "email",
    "display_name",
    "status",
    "created_at",
    "updated_at",
    "avatar_url",
    "email_verified",
    "share_read_receipts",
  ],
  execution_workspaces: [
    "id",
    "owner_user_id",
    "name",
    "status",
    "created_at",
    "updated_at",
    "parallel_slots",
  ],
  workspace_installations: [
    "installation_id",
    "owner_user_id",
    "workspace_id",
    "status",
    "created_at",
    "updated_at",
    "released_at",
  ],
  workspace_runtime_identities: [
    "id",
    "workspace_id",
    "credential_token_hash",
    "installation_id",
    "created_at",
    "revoked_at",
  ],
  workspace_runtime_facts: [
    "workspace_id",
    "platform",
    "architecture",
    "hostname",
    "app_version",
    "runtime_capabilities_json",
    "updated_at",
  ],
  workspace_sessions: [
    "id",
    "workspace_id",
    "runtime_identity_id",
    "client_version",
    "protocol_version",
    "ip_address",
    "connected_at",
    "last_heartbeat_at",
    "disconnected_at",
  ],
  desktop_auth_intents: [
    "id",
    "poll_token_hash",
    "client_name",
    "audience",
    "created_at",
    "expires_at",
    "approved_at",
    "approved_user_id",
    "claimed_at",
    "claimed_session_id",
    "denied_at",
  ],
  desktop_human_sessions: [
    "id",
    "user_id",
    "token_hash",
    "audience",
    "created_at",
    "last_used_at",
    "expires_at",
    "revoked_at",
    "device_id",
  ],
});

const tableDefinitionSources = Object.freeze({
  workflow_tasks: [
    "apps/cloud/migrations-v8/0006_chat_workflow_admission.sql",
    "workflow_tasks",
  ],
  conversation_workflow_step_runs: [
    "apps/cloud/migrations-v8/0016_workflow_step_runs.sql",
    "conversation_workflow_step_runs",
  ],
  conversation_workflow_runs: [
    "apps/cloud/migrations-v8/0015_conversation_workflow_runs.sql",
    "conversation_workflow_runs",
  ],
  conversation_history_entries: [
    "apps/cloud/migrations-v8/0012_canonical_conversation_history.sql",
    "conversation_history_entries",
  ],
  conversation_user_messages: [
    "apps/cloud/migrations-v8/0011_conversation_turns.sql",
    "conversation_user_messages",
  ],
  conversation_turns: [
    "apps/cloud/migrations-v8/0011_conversation_turns.sql",
    "conversation_turns",
  ],
  conversations: [
    "apps/cloud/migrations-v8/0010_conversation_workflows.sql",
    "conversations",
  ],
  conversation_work_requests: [
    "apps/cloud/migrations-v8/0010_conversation_workflows.sql",
    "conversation_work_requests",
  ],
  mutation_receipts: [
    "apps/cloud/migrations-v8/0001_syntila_v8.sql",
    "mutation_receipts",
  ],
  execution_workspaces: [
    "apps/cloud/migrations-v8/0001_syntila_v8.sql",
    "execution_workspaces",
  ],
  workspace_installations: [
    "apps/cloud/migrations-v8/0003_workspace_installations.sql",
    "workspace_installations",
  ],
  workspace_runtime_identities: [
    "apps/cloud/migrations-v8/0001_syntila_v8.sql",
    "workspace_runtime_identities",
  ],
  desktop_auth_intents: [
    "apps/cloud/migrations-v8/0002_desktop_auth_multi_audience.sql",
    "desktop_auth_intents__multi_audience",
  ],
  desktop_human_sessions: [
    "apps/cloud/migrations-v8/0002_desktop_auth_multi_audience.sql",
    "desktop_human_sessions__multi_audience",
  ],
});

const indexDefinitionSources = Object.freeze({
  idx_conversation_history_request: [
    "apps/cloud/migrations-v8/0012_canonical_conversation_history.sql",
    "conversation_history_entries",
  ],
  idx_conversation_history_turn: [
    "apps/cloud/migrations-v8/0012_canonical_conversation_history.sql",
    "conversation_history_entries",
  ],
  idx_conversation_turns_request: [
    "apps/cloud/migrations-v8/0011_conversation_turns.sql",
    "conversation_turns",
  ],
  idx_conversation_turns_history: [
    "apps/cloud/migrations-v8/0011_conversation_turns.sql",
    "conversation_turns",
  ],
  idx_runtime_installation_active: [
    "apps/cloud/migrations-v8/0001_syntila_v8.sql",
    "workspace_runtime_identities",
  ],
  idx_workspace_installations_active_workspace: [
    "apps/cloud/migrations-v8/0003_workspace_installations.sql",
    "workspace_installations",
  ],
  idx_workspace_runtime_identities_active_workspace: [
    "apps/cloud/migrations-v8/0004_workspace_runtime_identity_uniqueness.sql",
    "workspace_runtime_identities",
  ],
});

function extractCreateTableDefinition(sql, tableName) {
  const escapedTableName = tableName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = sql.match(
    new RegExp(
      `CREATE TABLE\\s+${escapedTableName}\\s*\\([\\s\\S]*?\\n\\);`,
      "i",
    ),
  );
  if (!match) {
    throw new Error(
      `Missing canonical CREATE TABLE definition for ${tableName}`,
    );
  }
  return match[0].replace(/;\s*$/, "");
}

function extractCreateIndexDefinition(sql, indexName) {
  const escapedIndexName = indexName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = sql.match(
    new RegExp(
      `CREATE(?: UNIQUE)? INDEX\\s+${escapedIndexName}\\s+ON\\s+[\\w]+\\s*\\([\\s\\S]*?\\)(?:\\s+WHERE\\s+[\\s\\S]*?)?\\s*;`,
      "i",
    ),
  );
  if (!match) {
    throw new Error(`Missing canonical CREATE INDEX for ${indexName}`);
  }
  return match[0].replace(/;\s*$/, "");
}

export const requiredProductionSmokeTableDefinitions = Object.freeze(
  Object.fromEntries(
    Object.entries(tableDefinitionSources).map(
      ([tableName, [migrationPath, sourceTableName]]) => {
        const migrationSql = readFileSync(
          join(repositoryRoot, migrationPath),
          "utf8",
        );
        let sourceDefinition = extractCreateTableDefinition(
          migrationSql,
          sourceTableName,
        );
        if (
          tableName === "conversation_turns" ||
          tableName === "conversation_workflow_runs"
        ) {
          const columns = [
            "0015_conversation_workflow_runs.sql",
            "0016_workflow_step_runs.sql",
          ].flatMap((path) => {
            const evolution = readFileSync(
              join(repositoryRoot, "apps/cloud/migrations-v8", path),
              "utf8",
            );
            return [
              ...evolution.matchAll(
                new RegExp(`ALTER TABLE ${tableName} ADD COLUMN ([^;]+);`, "g"),
              ),
            ].map((match) => match[1]);
          });
          sourceDefinition = sourceDefinition.replace(
            "created_at TEXT NOT NULL,",
            `created_at TEXT NOT NULL, ${columns.join(", ")},`,
          );
        }
        if (
          tableName === "conversations" ||
          tableName === "execution_workspaces"
        ) {
          const evolutionPaths =
            tableName === "execution_workspaces"
              ? ["0070_workspace_parallel_slots.sql"]
              : ["0079_ai_history_cutoff.sql"];
          const columns = evolutionPaths.flatMap((path) => {
            const evolution = readFileSync(
              join(repositoryRoot, "apps/cloud/migrations-v8", path),
              "utf8",
            );
            return [
              ...evolution.matchAll(
                new RegExp(
                  `ALTER TABLE ${tableName}\\s+ADD COLUMN ([^;]+);`,
                  "g",
                ),
              ),
            ].map((match) => match[1]);
          });
          sourceDefinition = sourceDefinition.replace(
            "updated_at TEXT NOT NULL,",
            `updated_at TEXT NOT NULL, ${columns.join(", ")},`,
          );
        }
        if (tableName === "desktop_human_sessions") {
          const evolution = readFileSync(
            join(
              repositoryRoot,
              "apps/cloud/migrations-v8/0095_desktop_session_device.sql",
            ),
            "utf8",
          );
          const columns = [
            ...evolution.matchAll(
              new RegExp(
                `ALTER TABLE ${tableName}\\s+ADD COLUMN ([^;]+);`,
                "g",
              ),
            ),
          ].map((match) => match[1]);
          sourceDefinition = sourceDefinition.replace(
            "revoked_at TEXT",
            `revoked_at TEXT, ${columns.join(", ")}`,
          );
        }
        const definition = sourceDefinition.replace(
          new RegExp(`^(CREATE TABLE\\s+)${sourceTableName}\\b`, "i"),
          `$1${tableName}`,
        );
        return [tableName, definition];
      },
    ),
  ),
);

export const requiredProductionSmokeIndexes = Object.freeze(
  Object.fromEntries(
    Object.entries(indexDefinitionSources).map(
      ([indexName, [migrationPath, tableName]]) => {
        const migrationSql = readFileSync(
          join(repositoryRoot, migrationPath),
          "utf8",
        );
        return [
          indexName,
          {
            tableName,
            sql: extractCreateIndexDefinition(migrationSql, indexName),
          },
        ];
      },
    ),
  ),
);

function normalizeTableDefinition(definition) {
  return definition
    .replace(/--[^\n\r]*/g, "")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replaceAll('"', "")
    .replaceAll("`", "")
    .replaceAll("[", "")
    .replaceAll("]", "")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/;$/, "")
    .toLowerCase();
}

function hasBothDesktopAuthAudiences(definition) {
  const normalized = normalizeTableDefinition(definition);
  return /check\s*\(\s*audience\s+in\s*\(\s*'syntila\.desktop\.management'\s*,\s*'syntila\.profile-lab\.management'\s*\)\s*\)/.test(
    normalized,
  );
}

export function productionSmokeSchemaIssues(
  tableNames,
  columnsByTable,
  definitionsByTable = {},
  indexesByName = {},
) {
  const tables = new Set(tableNames);
  const issues = [];

  for (const [table, requiredColumns] of Object.entries(
    requiredProductionSmokeColumns,
  )) {
    if (!tables.has(table)) {
      issues.push(
        table === "workspace_installations"
          ? "Production D1 workspace_installations is missing. Apply pending migration before deployment."
          : `missing table ${table}`,
      );
      continue;
    }

    const actualColumns = new Set(columnsByTable[table] ?? []);
    const missing = requiredColumns.filter(
      (column) => !actualColumns.has(column),
    );
    const unexpected = [...actualColumns].filter(
      (column) => !requiredColumns.includes(column),
    );
    if (missing.length > 0) {
      issues.push(`${table} is missing columns: ${missing.join(", ")}`);
    }
    if (unexpected.length > 0) {
      issues.push(`${table} has unexpected columns: ${unexpected.join(", ")}`);
    }
  }

  for (const [table, expectedDefinition] of Object.entries(
    requiredProductionSmokeTableDefinitions,
  )) {
    const actualDefinition = definitionsByTable[table];
    if (typeof actualDefinition !== "string") {
      issues.push(`missing CREATE TABLE definition for ${table}`);
      continue;
    }

    if (
      (table === "desktop_auth_intents" ||
        table === "desktop_human_sessions") &&
      !hasBothDesktopAuthAudiences(actualDefinition)
    ) {
      issues.push(
        `Production D1 ${table} has legacy single-audience constraint. Apply pending migration before deployment.`,
      );
      continue;
    }

    const normalize = (definition) => {
      const normalized = normalizeTableDefinition(definition);
      return table === "mutation_receipts" ||
        table === "execution_workspaces" ||
        table === "desktop_auth_intents" ||
        table === "desktop_human_sessions"
        ? normalized.replace(/\s*([(),])\s*/g, "$1")
        : normalized;
    };
    const normalizedActual = normalize(actualDefinition);
    const normalizedExpected = normalize(expectedDefinition);

    if (table === "execution_workspaces") {
      const isClean = normalizedActual === normalizedExpected;
      const isProductionBaseline =
        normalizedActual.includes("status text not null default 'enrolled'") &&
        normalizedActual.includes(
          "check (status in ('enrolled', 'online', 'offline', 'busy', 'draining', 'revoked'))",
        );
      if (!isClean && !isProductionBaseline) {
        issues.push(
          `Production D1 ${table} table definition differs from the v8 contract. Apply a forward migration before deployment.`,
        );
      }
      continue;
    }

    if (table === "workspace_runtime_identities") {
      const isClean = normalizedActual === normalizedExpected;
      const isProductionBaseline =
        normalizedActual.includes(
          "workspace_id text not null references execution_workspaces(id) on delete cascade",
        ) &&
        normalizedActual.includes("credential_token_hash text") &&
        normalizedActual.includes("installation_id text");
      if (!isClean && !isProductionBaseline) {
        issues.push(
          `Production D1 ${table} table definition differs from the v8 contract. Apply a forward migration before deployment.`,
        );
      }
      continue;
    }

    if (normalizedActual !== normalizedExpected) {
      issues.push(
        `Production D1 ${table} table definition differs from the v8 contract. Apply a forward migration before deployment.`,
      );
    }
  }

  for (const [indexName, expectedIndex] of Object.entries(
    requiredProductionSmokeIndexes,
  )) {
    const actualIndex = indexesByName[indexName];
    if (!actualIndex) {
      issues.push(
        `Production D1 is missing required unique partial index ${indexName}. Apply pending migration before deployment.`,
      );
      continue;
    }
    if (
      actualIndex.tbl_name !== expectedIndex.tableName ||
      normalizeTableDefinition(actualIndex.sql) !==
        normalizeTableDefinition(expectedIndex.sql)
    ) {
      issues.push(
        `Production D1 index ${indexName} differs from the v8 contract. Apply pending migration before deployment.`,
      );
    }
  }

  return issues;
}
