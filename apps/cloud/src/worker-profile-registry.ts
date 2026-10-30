import { canonicalJson } from "./canonical-json.js";
import type { ToolProfileV1 } from "@syntila/tool-profile";
import {
  ToolProfileRegistryError,
  parseProfile,
  profileDigest,
  validateId,
  validateWorkerProfilePublicationEvidence,
  type ToolProfileRegistryEnvironment,
  type WorkerProfilePublicationEvidence,
} from "./tool-profile-validation.js";

export {
  ToolProfileRegistryError,
  validateWorkerProfilePublicationEvidence,
} from "./tool-profile-validation.js";
export type {
  ToolProfileRegistryEnvironment,
  WorkerProfilePublicationEvidence,
} from "./tool-profile-validation.js";

// V9 Worker Profile registry
// ---------------------------------------------------------------------------

export interface WorkerProfileSummary {
  workerTypeId: string;
  displayName: string;
  description: string;
  profileDefinitionId: string | null;
  providerToolName: string | null;
  lifecycleState: string;
  engineFamily: string;
  visibilityState: string;
  sortOrder: number;
  currentRevision: number | null;
  currentDigest: string | null;
  currentUpdatedAt: string | null;
}

export interface WorkerProfileSnapshot {
  workerTypeId: string;
  schemaVersion: number;
  profile: ToolProfileV1;
  revision: number;
  digest: string;
  updatedByUserId: string | null;
  updatedAt: string;
}

export interface WorkerProfileHistorySnapshot extends WorkerProfileSnapshot {
  actorUserId: string | null;
  publishedAt: string;
  restorationReason: string | null;
}

interface CurrentWorkerProfileRow {
  worker_type_id: string;
  schema_version: number;
  profile_json: string;
  revision: number;
  digest: string;
  updated_by_user_id: string | null;
  updated_at: string;
}

function requireDigest(value: unknown, label = "candidateDigest"): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new ToolProfileRegistryError(400, `${label} is invalid`);
  }
  return value;
}

function requireRevision(value: unknown, label: string): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > 2_147_483_647
  ) {
    throw new ToolProfileRegistryError(400, `${label} is invalid`);
  }
  return value;
}

function parseCurrentWorkerProfile(
  row: CurrentWorkerProfileRow,
): ToolProfileV1 {
  let input: unknown;
  try {
    input = JSON.parse(row.profile_json);
  } catch {
    throw new ToolProfileRegistryError(
      409,
      "The current Worker Profile contains invalid JSON",
    );
  }
  const parsed = parseProfile(input, undefined);
  if (
    parsed.profile.logicalWorkerTypeId !== row.worker_type_id ||
    parsed.profile.schemaVersion !== row.schema_version
  ) {
    throw new ToolProfileRegistryError(
      409,
      "The current Worker Profile identity is inconsistent with its registry row",
    );
  }
  return parsed.profile;
}

async function assertWorkerProfileDigest(
  row: CurrentWorkerProfileRow,
  profile: ToolProfileV1,
): Promise<void> {
  const actualDigest = await profileDigest(canonicalProfilePayload(profile));
  if (actualDigest !== row.digest) {
    throw new ToolProfileRegistryError(
      409,
      "The current Worker Profile digest does not match its canonical JSON",
    );
  }
}

function canonicalProfilePayload(profile: ToolProfileV1): string {
  return canonicalJson(profile);
}

export async function listWorkerProfiles(
  db: D1Database,
): Promise<{ workers: WorkerProfileSummary[] }> {
  const rows = await db
    .prepare(
      `SELECT worker.worker_type_id, worker.display_name, worker.description,
              worker.lifecycle_state, worker.engine_family,
              worker.visibility_state, worker.sort_order,
              COALESCE(worker.profile_definition_id,
                json_extract(current_profile.profile_json,
                  '$.profileDefinitionId')) AS profile_definition_id,
              COALESCE(worker.provider_tool_name,
                json_extract(current_profile.profile_json,
                  '$.providerTool.name')) AS provider_tool_name,
              current_profile.revision AS current_revision,
              current_profile.digest AS current_digest,
              current_profile.updated_at AS current_updated_at
         FROM worker_catalog worker
         LEFT JOIN worker_profiles current_profile
           ON current_profile.worker_type_id = worker.worker_type_id
        ORDER BY worker.sort_order, worker.worker_type_id
        LIMIT 256`,
    )
    .all<{
      worker_type_id: string;
      display_name: string;
      description: string;
      lifecycle_state: string;
      engine_family: string;
      visibility_state: string;
      sort_order: number;
      profile_definition_id: string | null;
      provider_tool_name: string | null;
      current_revision: number | null;
      current_digest: string | null;
      current_updated_at: string | null;
    }>();
  return {
    workers: (rows.results ?? []).map((row) => ({
      workerTypeId: row.worker_type_id,
      displayName: row.display_name,
      description: row.description,
      profileDefinitionId:
        row.profile_definition_id == null
          ? null
          : String(row.profile_definition_id),
      providerToolName:
        row.provider_tool_name == null ? null : String(row.provider_tool_name),
      lifecycleState: row.lifecycle_state,
      engineFamily: row.engine_family,
      visibilityState: row.visibility_state,
      sortOrder: row.sort_order,
      currentRevision: row.current_revision,
      currentDigest: row.current_digest,
      currentUpdatedAt: row.current_updated_at,
    })),
  };
}

async function loadCurrentWorkerProfileRow(
  db: D1Database,
  workerTypeId: string,
): Promise<CurrentWorkerProfileRow | null> {
  return db
    .prepare(
      `SELECT worker_type_id, schema_version, profile_json, revision,
              digest, updated_by_user_id, updated_at
         FROM worker_profiles
        WHERE worker_type_id = ?1`,
    )
    .bind(workerTypeId)
    .first<CurrentWorkerProfileRow>();
}

/** Whether the Worker's current Profile can compact its native session. */
export async function workerProfileSupportsCompaction(
  db: D1Database,
  workerTypeId: string,
): Promise<boolean> {
  const row = await loadCurrentWorkerProfileRow(db, workerTypeId);
  if (!row) return false;
  try {
    const profile = JSON.parse(row.profile_json) as {
      context?: { compaction?: { prompt?: unknown } };
    };
    return typeof profile.context?.compaction?.prompt === "string";
  } catch {
    return false;
  }
}

async function requireWorkerCatalogRow(
  db: D1Database,
  workerTypeId: string,
): Promise<void> {
  const row = await db
    .prepare(
      "SELECT worker_type_id FROM worker_catalog WHERE worker_type_id = ?1",
    )
    .bind(workerTypeId)
    .first<{ worker_type_id: string }>();
  if (!row) throw new ToolProfileRegistryError(404, "Worker was not found");
}

export async function getCurrentWorkerProfile(
  env: ToolProfileRegistryEnvironment,
  workerTypeId: string,
): Promise<WorkerProfileSnapshot> {
  validateId(workerTypeId, "workerTypeId");
  await requireWorkerCatalogRow(env.SYNTILA_DB, workerTypeId);
  const row = await loadCurrentWorkerProfileRow(env.SYNTILA_DB, workerTypeId);
  if (!row) {
    throw new ToolProfileRegistryError(
      404,
      "The Worker does not have a published Profile",
    );
  }
  const profile = parseCurrentWorkerProfile(row);
  await assertWorkerProfileDigest(row, profile);
  return {
    workerTypeId: row.worker_type_id,
    schemaVersion: row.schema_version,
    profile,
    revision: row.revision,
    digest: row.digest,
    updatedByUserId: row.updated_by_user_id,
    updatedAt: row.updated_at,
  };
}

export async function listWorkerProfileHistory(
  env: ToolProfileRegistryEnvironment,
  workerTypeId: string,
): Promise<{ history: WorkerProfileHistorySnapshot[] }> {
  validateId(workerTypeId, "workerTypeId");
  await requireWorkerCatalogRow(env.SYNTILA_DB, workerTypeId);
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT worker_type_id, schema_version, profile_json, revision,
              digest, actor_user_id,
              published_at, restoration_reason
         FROM worker_profile_history
        WHERE worker_type_id = ?1
        ORDER BY revision DESC
        LIMIT 256`,
  )
    .bind(workerTypeId)
    .all<{
      worker_type_id: string;
      schema_version: number;
      profile_json: string;
      revision: number;
      digest: string;
      actor_user_id: string | null;
      published_at: string;
      restoration_reason: string | null;
    }>();
  return {
    history: await Promise.all(
      (rows.results ?? []).map(async (row) => {
        const profile = parseCurrentWorkerProfile({
          worker_type_id: row.worker_type_id,
          schema_version: row.schema_version,
          profile_json: row.profile_json,
          revision: row.revision,
          digest: row.digest,
          updated_by_user_id: row.actor_user_id,
          updated_at: row.published_at,
        });
        await assertWorkerProfileDigest(
          {
            worker_type_id: row.worker_type_id,
            schema_version: row.schema_version,
            profile_json: row.profile_json,
            revision: row.revision,
            digest: row.digest,
            updated_by_user_id: row.actor_user_id,
            updated_at: row.published_at,
          },
          profile,
        );
        return {
          workerTypeId: row.worker_type_id,
          schemaVersion: row.schema_version,
          profile,
          revision: row.revision,
          digest: row.digest,
          updatedByUserId: row.actor_user_id,
          updatedAt: row.published_at,
          actorUserId: row.actor_user_id,
          publishedAt: row.published_at,
          restorationReason: row.restoration_reason,
        };
      }),
    ),
  };
}

export async function validateWorkerProfileCandidate(
  workerTypeId: string,
  candidate: unknown,
  candidateDigest?: unknown,
  evidence?: unknown,
): Promise<{
  profile: ToolProfileV1;
  canonicalJson: string;
  digest: string;
  evidence: WorkerProfilePublicationEvidence | null;
}> {
  validateId(workerTypeId, "workerTypeId");
  const parsed = parseProfile(candidate);
  if (parsed.profile.logicalWorkerTypeId !== workerTypeId) {
    throw new ToolProfileRegistryError(
      400,
      "Profile logical Worker does not match the requested Worker",
    );
  }
  const digest = await profileDigest(parsed.payload);
  if (
    candidateDigest !== undefined &&
    requireDigest(candidateDigest) !== digest
  ) {
    throw new ToolProfileRegistryError(
      409,
      "candidateDigest does not match the canonical Profile JSON",
    );
  }
  const validatedEvidence =
    evidence === undefined
      ? null
      : validateWorkerProfilePublicationEvidence(evidence, {
          workerTypeId,
          candidateDigest: digest,
          profile: parsed.profile,
        });
  return {
    profile: parsed.profile,
    canonicalJson: parsed.payload,
    digest,
    evidence: validatedEvidence,
  };
}

async function persistWorkerProfileSnapshot(args: {
  env: ToolProfileRegistryEnvironment;
  workerTypeId: string;
  expectedRevision: number;
  current: CurrentWorkerProfileRow | null;
  profile: ToolProfileV1;
  canonicalJson: string;
  digest: string;
  actorUserId: string;
  updatedAt: string;
  restorationReason: string | null;
}): Promise<number> {
  const nextRevision = (args.current?.revision ?? 0) + 1;
  if (nextRevision > 2_147_483_647) {
    throw new ToolProfileRegistryError(
      409,
      "Worker Profile revision limit reached",
    );
  }
  const db = args.env.SYNTILA_DB;
  if (!args.current) {
    if (args.expectedRevision !== 0) {
      throw new ToolProfileRegistryError(
        409,
        "Worker Profile revision is stale",
      );
    }
    const result = await db
      .prepare(
        `INSERT INTO worker_profiles
           (worker_type_id, schema_version, profile_json, revision, digest,
            updated_by_user_id, updated_at)
         VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6)
         ON CONFLICT(worker_type_id) DO NOTHING`,
      )
      .bind(
        args.workerTypeId,
        args.profile.schemaVersion,
        args.canonicalJson,
        args.digest,
        args.actorUserId,
        args.updatedAt,
      )
      .run();
    if (Number(result.meta?.changes ?? 0) !== 1) {
      throw new ToolProfileRegistryError(
        409,
        "Worker Profile revision is stale",
      );
    }
    return 1;
  }

  const results = await db.batch([
    db
      .prepare(
        `INSERT INTO worker_profile_history
           (worker_type_id, revision, schema_version, profile_json, digest,
            actor_user_id, published_at, restoration_reason)
         SELECT worker_type_id, revision, schema_version, profile_json, digest,
                updated_by_user_id, updated_at, ?4
           FROM worker_profiles
          WHERE worker_type_id = ?1 AND revision = ?2 AND digest = ?3`,
      )
      .bind(
        args.workerTypeId,
        args.expectedRevision,
        args.current.digest,
        args.restorationReason,
      ),
    db
      .prepare(
        `UPDATE worker_profiles
            SET schema_version = ?1, profile_json = ?2, revision = ?3,
                digest = ?4, updated_by_user_id = ?5, updated_at = ?6
          WHERE worker_type_id = ?7 AND revision = ?8 AND digest = ?9`,
      )
      .bind(
        args.profile.schemaVersion,
        args.canonicalJson,
        nextRevision,
        args.digest,
        args.actorUserId,
        args.updatedAt,
        args.workerTypeId,
        args.expectedRevision,
        args.current.digest,
      ),
  ]);
  if (Number(results[1]?.meta?.changes ?? 0) !== 1) {
    throw new ToolProfileRegistryError(409, "Worker Profile revision is stale");
  }
  return nextRevision;
}

export async function publishWorkerProfile(args: {
  env: ToolProfileRegistryEnvironment;
  workerTypeId: string;
  expectedRevision: number;
  candidate: unknown;
  candidateDigest: unknown;
  evidence: unknown;
  actorUserId: string;
}): Promise<WorkerProfileSnapshot> {
  validateId(args.workerTypeId, "workerTypeId");
  await requireWorkerCatalogRow(args.env.SYNTILA_DB, args.workerTypeId);
  const candidateDigest = requireDigest(args.candidateDigest);
  const validated = await validateWorkerProfileCandidate(
    args.workerTypeId,
    args.candidate,
    candidateDigest,
    args.evidence,
  );
  if (validated.evidence === null) {
    throw new ToolProfileRegistryError(
      409,
      "Publication requires complete evidence for this exact Profile candidate",
    );
  }
  requireRevision(args.expectedRevision, "expectedRevision");
  const current = await loadCurrentWorkerProfileRow(
    args.env.SYNTILA_DB,
    args.workerTypeId,
  );
  if ((current?.revision ?? 0) !== args.expectedRevision) {
    throw new ToolProfileRegistryError(409, "Worker Profile revision is stale");
  }
  await persistWorkerProfileSnapshot({
    env: args.env,
    workerTypeId: args.workerTypeId,
    expectedRevision: args.expectedRevision,
    current,
    profile: validated.profile,
    canonicalJson: validated.canonicalJson,
    digest: validated.digest,
    actorUserId: args.actorUserId,
    updatedAt: new Date().toISOString(),
    restorationReason: null,
  });
  return getCurrentWorkerProfile(args.env, args.workerTypeId);
}

export async function restoreWorkerProfile(args: {
  env: ToolProfileRegistryEnvironment;
  workerTypeId: string;
  expectedRevision: number;
  targetRevision: number;
  restorationReason: string;
  actorUserId: string;
}): Promise<WorkerProfileSnapshot> {
  validateId(args.workerTypeId, "workerTypeId");
  requireRevision(args.expectedRevision, "expectedRevision");
  requireRevision(args.targetRevision, "targetRevision");
  if (!args.restorationReason.trim() || args.restorationReason.length > 512) {
    throw new ToolProfileRegistryError(400, "restorationReason is invalid");
  }
  await requireWorkerCatalogRow(args.env.SYNTILA_DB, args.workerTypeId);
  const current = await loadCurrentWorkerProfileRow(
    args.env.SYNTILA_DB,
    args.workerTypeId,
  );
  if (!current || current.revision !== args.expectedRevision) {
    throw new ToolProfileRegistryError(409, "Worker Profile revision is stale");
  }
  const history = await args.env.SYNTILA_DB.prepare(
    `SELECT worker_type_id, schema_version, profile_json, revision,
              digest, actor_user_id,
              published_at AS updated_at
         FROM worker_profile_history
        WHERE worker_type_id = ?1 AND revision = ?2`,
  )
    .bind(args.workerTypeId, args.targetRevision)
    .first<CurrentWorkerProfileRow>();
  if (!history)
    throw new ToolProfileRegistryError(404, "Profile revision was not found");
  const profile = parseCurrentWorkerProfile(history);
  await assertWorkerProfileDigest(history, profile);
  const validated = await validateWorkerProfileCandidate(
    args.workerTypeId,
    profile,
    history.digest,
  );
  await persistWorkerProfileSnapshot({
    env: args.env,
    workerTypeId: args.workerTypeId,
    expectedRevision: args.expectedRevision,
    current,
    profile: validated.profile,
    canonicalJson: validated.canonicalJson,
    digest: validated.digest,
    actorUserId: args.actorUserId,
    updatedAt: new Date().toISOString(),
    restorationReason: args.restorationReason,
  });
  return getCurrentWorkerProfile(args.env, args.workerTypeId);
}
