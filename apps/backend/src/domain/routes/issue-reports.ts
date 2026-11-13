import { createHash } from "node:crypto";
import type { SecurityContext } from "@syntila/security";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./handlers.js";
import { authorizeThreadAccess } from "./thread-policy.js";

const MAX_REPORT_BODY_BYTES = 4096;
const MAX_SUPPORT_NOTE_LENGTH = 1000;
const REPORT_RATE_LIMIT_PER_HOUR = 20;
const SAFE_TOKEN = /^[A-Za-z0-9._:-]+$/;
const MAX_FAILURE_DIAGNOSTIC_LENGTH = 2048;

type ReportStatus = "open" | "investigating" | "resolved" | "dismissed";
type DiagnosticState = "complete" | "partial" | "unavailable";

interface ExecutionEvidence {
  requestId: string;
  threadId: string;
  requestedByUserId: string;
  requestStatus: string;
  runId: string | null;
  taskId: string | null;
  attemptId: string | null;
  assignmentId: string | null;
  workspaceId: string | null;
  workerId: string | null;
  workerTypeId: string | null;
  assignmentStatus: string | null;
  engineVersion: string | null;
  modelId: string | null;
  effort: string | null;
  profileDefinitionId: string | null;
  profileReleaseVersion: number | null;
  providerToolVersion: string | null;
  applicationVersion: string | null;
  errorCode: string;
  retryable: boolean;
  failureStage: string;
  component: string;
  failureDetail: string | null;
  updatedAt: string;
}

interface FailureDiagnosticMetadata {
  component: string | null;
  stage: string | null;
}

interface ReportRow {
  id: string;
  publicReference: string;
  reporterUserId: string | null;
  workspaceId: string | null;
  requestId: string;
  assignmentId: string | null;
  component: string;
  errorCode: string;
  failureStage: string;
  fingerprint: string;
  status: ReportStatus;
  diagnosticState: DiagnosticState;
  createdAt: string;
  updatedAt: string;
  workerTypeId: string | null;
  modelId: string | null;
  effort: string | null;
  engineVersion: string | null;
  profileDefinitionId: string | null;
  profileReleaseVersion: number | null;
  providerToolVersion: string | null;
  applicationVersion: string | null;
  incidentGroupId: string | null;
  incidentGroup: {
    id: string;
    publicReference: string;
    label: string;
    count: number;
    firstOccurrence: string | null;
    lastOccurrence: string | null;
  } | null;
  fingerprintGroup: {
    fingerprint: string;
    count: number;
    firstOccurrence: string | null;
    lastOccurrence: string | null;
  };
}

const REPORT_COLUMNS = `
  ir.id, ir.public_reference AS publicReference,
  ir.reporter_user_id AS reporterUserId, ir.workspace_id AS workspaceId,
  ir.request_id AS requestId, ir.assignment_id AS assignmentId,
  ir.component, ir.error_code AS errorCode, ir.failure_stage AS failureStage,
  ir.fingerprint, ir.status, ir.diagnostic_state AS diagnosticState,
  ir.created_at AS createdAt, ir.updated_at AS updatedAt,
  ir.worker_type_id AS workerTypeId, ir.model_id AS modelId,
  ir.effort, ir.engine_version AS engineVersion,
  ir.profile_definition_id AS profileDefinitionId,
  ir.profile_release_version AS profileReleaseVersion,
  ir.provider_tool_version AS providerToolVersion,
  ir.application_version AS applicationVersion,
  ir.incident_group_id AS incidentGroupId,
  ig.id AS groupId, ig.public_reference AS groupPublicReference,
  ig.label AS groupLabel,
  (SELECT COUNT(*) FROM issue_reports gm WHERE gm.incident_group_id = ir.incident_group_id) AS groupCount,
  (SELECT MIN(gm.created_at) FROM issue_reports gm WHERE gm.incident_group_id = ir.incident_group_id) AS groupFirstOccurrence,
  (SELECT MAX(gm.created_at) FROM issue_reports gm WHERE gm.incident_group_id = ir.incident_group_id) AS groupLastOccurrence,
  (SELECT COUNT(*) FROM issue_reports fp WHERE fp.fingerprint = ir.fingerprint) AS fingerprintCount,
  (SELECT MIN(fp.created_at) FROM issue_reports fp WHERE fp.fingerprint = ir.fingerprint) AS fingerprintFirstOccurrence,
  (SELECT MAX(fp.created_at) FROM issue_reports fp WHERE fp.fingerprint = ir.fingerprint) AS fingerprintLastOccurrence`;

function reportSelect(): string {
  return `SELECT ${REPORT_COLUMNS} FROM issue_reports ir
    LEFT JOIN issue_report_groups ig ON ig.id = ir.incident_group_id`;
}

function boundedToken(value: unknown, max = 128): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return normalized.length > 0 &&
    normalized.length <= max &&
    SAFE_TOKEN.test(normalized)
    ? normalized
    : null;
}

function parseJsonRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "string" || value.length === 0) return {};
  try {
    const parsed: unknown = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

function normalizedError(value: unknown): {
  code: string;
  retryable: boolean;
  diagnostic: string | null;
} {
  const parsed = parseJsonRecord(value);
  const nested =
    parsed.error &&
    typeof parsed.error === "object" &&
    !Array.isArray(parsed.error)
      ? (parsed.error as Record<string, unknown>)
      : parsed;
  const diagnosticValue =
    nested.details &&
    typeof nested.details === "object" &&
    !Array.isArray(nested.details)
      ? (nested.details as Record<string, unknown>).diagnostic
      : null;
  return {
    code: boundedToken(nested.code, 64) ?? "execution_failed",
    retryable: nested.retryable === true,
    diagnostic:
      typeof diagnosticValue === "string"
        ? sanitizeFailureDiagnostic(diagnosticValue)
        : null,
  };
}

function sanitizeFailureDiagnostic(value: string): string | null {
  const normalized = value
    .replace(/(bearer\s+)[a-z0-9._~+/-]+=*/gi, "$1[REDACTED]")
    .replace(
      /((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)\s*[:=]\s*)[^\s,;]+/gi,
      "$1[REDACTED]",
    )
    // eslint-disable-next-line no-control-regex -- Remove control bytes from diagnostic text.
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(
      /(?<![A-Za-z0-9])(?:\/Users|\/home|\/private\/var|\/tmp)\/[^\s,;]+/g,
      "[PATH]",
    )
    .replace(/(?<![A-Za-z0-9])[A-Za-z]:[\\/][^\s,;]+/g, "[PATH]")
    .trim();
  if (!normalized) return null;
  return normalized.length > MAX_FAILURE_DIAGNOSTIC_LENGTH
    ? `${normalized.slice(0, MAX_FAILURE_DIAGNOSTIC_LENGTH)}…`
    : normalized;
}

function failureDiagnosticMetadata(
  value: string | null,
): FailureDiagnosticMetadata {
  if (!value) return { component: null, stage: null };
  const parsed = parseJsonRecord(value);
  return {
    component: boundedToken(parsed.component, 64),
    stage: boundedToken(parsed.stage, 64),
  };
}

function failureClassification(
  errorCode: string,
  assignmentStatus: string | null,
): { component: string; stage: string } {
  if (
    errorCode.includes("profile") ||
    errorCode.includes("engine_incompatible")
  )
    return { component: "tool_profile", stage: "profile_resolution" };
  if (
    errorCode === "provider_authentication_required" ||
    errorCode.includes("provider")
  )
    return { component: "provider_cli", stage: "provider_execution" };
  if (errorCode === "worker_not_ready" || errorCode === "provider_unavailable")
    return { component: "workspace_service", stage: "transport" };
  if (assignmentStatus === "failed")
    return { component: "cli_worker_engine", stage: "provider_execution" };
  return { component: "cloud", stage: "admission" };
}

function reportRow(row: Record<string, unknown>): ReportRow {
  return {
    id: String(row.id),
    publicReference: String(row.publicReference),
    reporterUserId:
      row.reporterUserId == null ? null : String(row.reporterUserId),
    workspaceId: row.workspaceId == null ? null : String(row.workspaceId),
    requestId: String(row.requestId),
    assignmentId: row.assignmentId == null ? null : String(row.assignmentId),
    component: String(row.component),
    errorCode: String(row.errorCode),
    failureStage: String(row.failureStage),
    fingerprint: String(row.fingerprint),
    status: String(row.status) as ReportStatus,
    diagnosticState: String(row.diagnosticState) as DiagnosticState,
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
    workerTypeId: row.workerTypeId == null ? null : String(row.workerTypeId),
    modelId: row.modelId == null ? null : String(row.modelId),
    effort: row.effort == null ? null : String(row.effort),
    engineVersion: row.engineVersion == null ? null : String(row.engineVersion),
    profileDefinitionId:
      row.profileDefinitionId == null ? null : String(row.profileDefinitionId),
    profileReleaseVersion:
      row.profileReleaseVersion == null
        ? null
        : Number(row.profileReleaseVersion),
    providerToolVersion:
      row.providerToolVersion == null ? null : String(row.providerToolVersion),
    applicationVersion:
      row.applicationVersion == null ? null : String(row.applicationVersion),
    incidentGroupId:
      row.incidentGroupId == null ? null : String(row.incidentGroupId),
    incidentGroup:
      row.groupId == null
        ? null
        : {
            id: String(row.groupId),
            publicReference: String(row.groupPublicReference),
            label: String(row.groupLabel),
            count: Number(row.groupCount ?? 0),
            firstOccurrence:
              row.groupFirstOccurrence == null
                ? null
                : String(row.groupFirstOccurrence),
            lastOccurrence:
              row.groupLastOccurrence == null
                ? null
                : String(row.groupLastOccurrence),
          },
    fingerprintGroup: {
      fingerprint: String(row.fingerprint),
      count: Number(row.fingerprintCount ?? 1),
      firstOccurrence:
        row.fingerprintFirstOccurrence == null
          ? null
          : String(row.fingerprintFirstOccurrence),
      lastOccurrence:
        row.fingerprintLastOccurrence == null
          ? null
          : String(row.fingerprintLastOccurrence),
    },
  };
}

function userReportResponse(row: ReportRow): Record<string, unknown> {
  return {
    report: {
      id: row.id,
      publicReference: row.publicReference,
      status: row.status,
      diagnosticState: row.diagnosticState,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    },
  };
}

async function readReportBody(request: Request): Promise<string> {
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (contentLength > MAX_REPORT_BODY_BYTES)
    throw new HttpError(413, "Report request is too large");
  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_REPORT_BODY_BYTES)
    throw new HttpError(413, "Report request is too large");
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    throw new HttpError(400, "Report request must be valid JSON");
  }
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "Report request must be an object");
  const keys = Object.keys(value);
  if (keys.some((key) => key !== "requestId"))
    throw new HttpError(400, "Only requestId may be supplied");
  const requestId = boundedToken((value as Record<string, unknown>).requestId);
  if (!requestId) throw new HttpError(400, "requestId is required");
  return requestId;
}

async function loadExecutionEvidence(
  env: SecurityEnv,
  requestId: string,
): Promise<ExecutionEvidence> {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT wr.id AS requestId, wr.thread_id AS threadId,
            wr.requested_by_user_id AS requestedByUserId, wr.status AS requestStatus,
            wr.updated_at AS requestUpdatedAt,
            r.id AS runId,
            wa.id AS assignmentId, wa.task_id AS taskId, wa.attempt_id AS attemptId,
            wa.execution_workspace_id AS workspaceId, wa.workspace_worker_id AS workerId,
            wa.worker_type_id AS workerTypeId, wa.status AS assignmentStatus,
            wa.engine_version AS engineVersion, wa.model AS modelId,
            wa.error_json AS assignmentErrorJson,
            wa.permission_snapshot_json AS permissionSnapshotJson,
            wa.updated_at AS assignmentUpdatedAt,
            wt.error AS taskError,
            wrf.app_version AS applicationVersion
       FROM work_requests wr
       LEFT JOIN runs r ON r.work_request_id = wr.id
       LEFT JOIN worker_assignments wa ON wa.id = (
         SELECT candidate.id FROM worker_assignments candidate
          WHERE candidate.work_request_id = wr.id
             OR (r.id IS NOT NULL AND candidate.run_id = r.id)
          ORDER BY candidate.created_at DESC, candidate.id DESC LIMIT 1
       )
       LEFT JOIN workflow_tasks wt ON wt.id = wa.task_id
       LEFT JOIN workspace_runtime_facts wrf ON wrf.workspace_id = wa.execution_workspace_id
      WHERE wr.id = ?1
      ORDER BY r.updated_at DESC NULLS LAST
      LIMIT 1`,
  )
    .bind(requestId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Work Request not found");
  if (row.requestStatus !== "failed")
    throw new HttpError(409, "Only a failed Work Request can be reported");

  const assignmentError = normalizedError(row.assignmentErrorJson);
  const taskError = normalizedError(row.taskError);
  const errorCode =
    assignmentError.code !== "execution_failed"
      ? assignmentError.code
      : taskError.code;
  const failureDetail = assignmentError.diagnostic ?? taskError.diagnostic;
  const diagnosticMetadata = failureDiagnosticMetadata(failureDetail);
  const snapshot = parseJsonRecord(row.permissionSnapshotJson);
  const classification = failureClassification(
    errorCode,
    row.assignmentStatus == null ? null : String(row.assignmentStatus),
  );
  return {
    requestId: String(row.requestId),
    threadId: String(row.threadId),
    requestedByUserId: String(row.requestedByUserId),
    requestStatus: String(row.requestStatus),
    runId: row.runId == null ? null : String(row.runId),
    taskId: row.taskId == null ? null : String(row.taskId),
    attemptId: row.attemptId == null ? null : String(row.attemptId),
    assignmentId: row.assignmentId == null ? null : String(row.assignmentId),
    workspaceId: row.workspaceId == null ? null : String(row.workspaceId),
    workerId: row.workerId == null ? null : String(row.workerId),
    workerTypeId: row.workerTypeId == null ? null : String(row.workerTypeId),
    assignmentStatus:
      row.assignmentStatus == null ? null : String(row.assignmentStatus),
    engineVersion:
      row.engineVersion == null ? null : boundedToken(row.engineVersion),
    modelId: row.modelId == null ? null : boundedToken(row.modelId),
    effort: boundedToken(snapshot.reasoningEffort ?? snapshot.effort),
    profileDefinitionId: boundedToken(snapshot.profileDefinitionId),
    profileReleaseVersion:
      typeof snapshot.profileReleaseVersion === "number" &&
      Number.isInteger(snapshot.profileReleaseVersion) &&
      snapshot.profileReleaseVersion > 0
        ? snapshot.profileReleaseVersion
        : null,
    providerToolVersion: null,
    applicationVersion:
      row.applicationVersion == null
        ? null
        : boundedToken(row.applicationVersion),
    errorCode,
    retryable: assignmentError.retryable || taskError.retryable,
    failureStage: diagnosticMetadata.stage ?? classification.stage,
    component: diagnosticMetadata.component ?? classification.component,
    failureDetail,
    updatedAt: String(row.assignmentUpdatedAt ?? row.requestUpdatedAt),
  };
}

async function enrichProviderVersion(
  env: SecurityEnv,
  evidence: ExecutionEvidence,
): Promise<ExecutionEvidence> {
  if (!evidence.workspaceId || !evidence.workerId) return evidence;
  const row = await env.SYNTILA_DB.prepare(
    `SELECT provider_tool_version AS providerToolVersion
       FROM workspace_worker_inventory
      WHERE workspace_id = ?1 AND worker_id = ?2
      ORDER BY last_seen_at DESC LIMIT 1`,
  )
    .bind(evidence.workspaceId, evidence.workerId)
    .first<{ providerToolVersion?: string | null }>();
  return {
    ...evidence,
    providerToolVersion: boundedToken(row?.providerToolVersion),
  };
}

function fingerprintFor(evidence: ExecutionEvidence): string {
  const values = [
    evidence.component,
    evidence.errorCode,
    evidence.failureStage,
    evidence.engineVersion ?? "unknown",
    evidence.profileDefinitionId ?? "unknown",
    evidence.profileReleaseVersion?.toString() ?? "unknown",
    evidence.providerToolVersion ?? "unknown",
  ];
  return createHash("sha256").update(values.join("\u001f")).digest("hex");
}

function diagnosticFor(
  evidence: ExecutionEvidence,
  createdAt: string,
): Record<string, unknown> {
  const eventId = `diag-report-${evidence.requestId}`;
  return {
    schemaVersion: 1,
    generatedAt: createdAt,
    diagnosticState: "partial",
    events: [
      {
        schemaVersion: 1,
        eventId,
        timestamp: createdAt,
        requestId: evidence.requestId,
        assignmentId: evidence.assignmentId,
        workspaceId: evidence.workspaceId,
        workerId: evidence.workerId,
        workerTypeId: evidence.workerTypeId,
        runId: evidence.runId,
        taskId: evidence.taskId,
        attemptId: evidence.attemptId,
        component: "cloud",
        operation: "issue_report",
        stage: "report_assembly",
        severity: "error",
        errorCode: evidence.errorCode,
        retryable: evidence.retryable,
        context: {
          status: evidence.requestStatus,
          engineVersion: evidence.engineVersion,
          profileDefinitionId: evidence.profileDefinitionId,
          profileReleaseVersion: evidence.profileReleaseVersion,
          providerToolVersion: evidence.providerToolVersion,
          applicationVersion: evidence.applicationVersion,
          modelId: evidence.modelId,
          effort: evidence.effort,
          failureLayer: evidence.component,
        },
      },
    ],
    execution: {
      requestId: evidence.requestId,
      runId: evidence.runId,
      taskId: evidence.taskId,
      attemptId: evidence.attemptId,
      assignmentId: evidence.assignmentId,
      workspaceId: evidence.workspaceId,
      workerId: evidence.workerId,
      workerTypeId: evidence.workerTypeId,
      assignmentStatus: evidence.assignmentStatus,
      updatedAt: evidence.updatedAt,
      ...(evidence.failureDetail
        ? { failureDetail: evidence.failureDetail }
        : {}),
    },
    workspace: workspaceEvidenceFor(evidence),
  };
}

function workspaceEvidenceFor(
  evidence: ExecutionEvidence,
): Record<string, string> {
  const diagnosticComponent = failureDiagnosticMetadata(
    evidence.failureDetail,
  ).component;
  if (
    !evidence.assignmentId ||
    !evidence.assignmentStatus ||
    diagnosticComponent === "cloud"
  ) {
    return {
      state: "disconnected",
      reason:
        diagnosticComponent === "cloud"
          ? "workspace_not_reached"
          : "assignment_not_observed",
    };
  }
  if (evidence.failureDetail) {
    return {
      state: "diagnostics_unavailable",
      reason: "assignment_error_only",
    };
  }
  return {
    state: "diagnostics_unavailable",
    reason: "local_diagnostics_not_attached",
  };
}

function publicReference(): string {
  return `ISS-${Date.now().toString(36).toUpperCase()}-${crypto
    .randomUUID()
    .slice(0, 8)
    .toUpperCase()}`;
}

async function issueSupportContext(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<SecurityContext> {
  const actor = await securityContext(request, env, ctx);
  const allowed = (env.SYNTILA_ISSUE_SUPPORT_USER_IDS ?? "")
    .split(",")
    .map((id) => id.trim())
    .filter(Boolean);
  if (!allowed.includes(actor.userId))
    throw new HttpError(403, "Issue support authorization is required");
  return actor;
}

async function recordEvent(
  env: SecurityEnv,
  reportId: string,
  actorUserId: string | null,
  eventType: string,
  details: Record<string, unknown> = {},
  status: { from?: string; to?: string } = {},
): Promise<void> {
  try {
    await env.SYNTILA_DB.prepare(
      `INSERT INTO issue_report_events
         (id, report_id, actor_user_id, event_type, from_status, to_status, details_json, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
      .bind(
        `ire-${crypto.randomUUID()}`,
        reportId,
        actorUserId,
        eventType,
        status.from ?? null,
        status.to ?? null,
        JSON.stringify(details),
        new Date().toISOString(),
      )
      .run();
  } catch {
    // Report reads remain available if an audit write is temporarily degraded.
  }
}

async function existingReport(
  env: SecurityEnv,
  reporterUserId: string,
  attemptKey: string,
): Promise<ReportRow | null> {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT id, public_reference AS publicReference,
            reporter_user_id AS reporterUserId, workspace_id AS workspaceId,
            request_id AS requestId, assignment_id AS assignmentId,
            component, error_code AS errorCode, failure_stage AS failureStage,
            fingerprint, status, diagnostic_state AS diagnosticState,
            created_at AS createdAt, updated_at AS updatedAt
       FROM issue_reports WHERE reporter_user_id = ?1 AND attempt_key = ?2
       LIMIT 1`,
  )
    .bind(reporterUserId, attemptKey)
    .first<Record<string, unknown>>();
  return row ? reportRow(row) : null;
}

export async function handleCreateIssueReport(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const requestId = await readReportBody(request);
  const actor = await securityContext(request, env, ctx);
  const preliminary = await loadExecutionEvidence(env, requestId);
  if (preliminary.requestedByUserId !== actor.userId) {
    await authorizeThreadAccess(
      request,
      env,
      preliminary.threadId,
      "view",
      ctx,
    );
  }
  const evidence = await enrichProviderVersion(env, preliminary);
  const attemptKey = evidence.assignmentId ?? `request:${evidence.requestId}`;
  const existing = await existingReport(env, actor.userId, attemptKey);
  if (existing) return json(userReportResponse(existing), { status: 200 });

  const recent = await env.SYNTILA_DB.prepare(
    `SELECT COUNT(*) AS count FROM issue_reports
      WHERE reporter_user_id = ?1 AND created_at >= ?2`,
  )
    .bind(actor.userId, new Date(Date.now() - 60 * 60 * 1000).toISOString())
    .first<{ count: number }>();
  if (Number(recent?.count ?? 0) >= REPORT_RATE_LIMIT_PER_HOUR)
    throw new HttpError(429, "Issue report rate limit reached");

  const now = new Date().toISOString();
  const reportId = `issue-${crypto.randomUUID()}`;
  const reference = publicReference();
  const fingerprint = fingerprintFor(evidence);
  const diagnostic = diagnosticFor(evidence, now);
  const diagnosticState: DiagnosticState = "partial";
  const statements = [
    env.SYNTILA_DB.prepare(
      `INSERT INTO issue_reports
         (id, public_reference, reporter_user_id, workspace_id, request_id,
          assignment_id, attempt_key, component, error_code, failure_stage, fingerprint,
          status, diagnostic_state, created_at, updated_at,
          worker_type_id, model_id, effort, engine_version,
          profile_definition_id, profile_release_version, provider_tool_version,
          application_version)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'open', ?12, ?13, ?13,
          ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)`,
    ).bind(
      reportId,
      reference,
      actor.userId,
      evidence.workspaceId,
      evidence.requestId,
      evidence.assignmentId,
      attemptKey,
      evidence.component,
      evidence.errorCode,
      evidence.failureStage,
      fingerprint,
      diagnosticState,
      now,
      evidence.workerTypeId,
      evidence.modelId,
      evidence.effort,
      evidence.engineVersion,
      evidence.profileDefinitionId,
      evidence.profileReleaseVersion,
      evidence.providerToolVersion,
      evidence.applicationVersion,
    ),
    env.SYNTILA_DB.prepare(
      `INSERT INTO issue_report_diagnostics
         (report_id, schema_version, diagnostic_json, created_at)
       VALUES (?1, 1, ?2, ?3)`,
    ).bind(reportId, JSON.stringify(diagnostic), now),
    env.SYNTILA_DB.prepare(
      `INSERT INTO issue_report_events
         (id, report_id, actor_user_id, event_type, to_status, details_json, created_at)
       VALUES (?1, ?2, ?3, 'report.created', 'open', ?4, ?5)`,
    ).bind(
      `ire-${crypto.randomUUID()}`,
      reportId,
      actor.userId,
      JSON.stringify({ diagnosticState }),
      now,
    ),
  ];
  try {
    await env.SYNTILA_DB.batch(statements);
  } catch {
    const duplicate = await existingReport(env, actor.userId, attemptKey);
    if (duplicate) return json(userReportResponse(duplicate), { status: 200 });
    throw new HttpError(503, "Issue report could not be stored");
  }

  const bucket = env.SYNTILA_ARTIFACTS;
  if (bucket) {
    const key = `issue-reports/${reportId}/diagnostics.json`;
    const body = JSON.stringify(diagnostic);
    try {
      await bucket.put(key, body, {
        httpMetadata: { contentType: "application/json" },
      });
      const digest = createHash("sha256").update(body).digest("hex");
      try {
        await env.SYNTILA_DB.prepare(
          `UPDATE issue_report_diagnostics
              SET bundle_key = ?1, bundle_sha256 = ?2 WHERE report_id = ?3`,
        )
          .bind(key, digest, reportId)
          .run();
      } catch {
        await bucket.delete(key).catch(() => {});
      }
    } catch {
      // D1 already contains the durable sanitized report; keep it partial.
    }
  }
  const row: ReportRow = {
    id: reportId,
    publicReference: reference,
    reporterUserId: actor.userId,
    workspaceId: evidence.workspaceId,
    requestId: evidence.requestId,
    assignmentId: evidence.assignmentId,
    component: evidence.component,
    errorCode: evidence.errorCode,
    failureStage: evidence.failureStage,
    fingerprint,
    status: "open",
    diagnosticState,
    createdAt: now,
    updatedAt: now,
    workerTypeId: evidence.workerTypeId,
    modelId: evidence.modelId,
    effort: evidence.effort,
    engineVersion: evidence.engineVersion,
    profileDefinitionId: evidence.profileDefinitionId,
    profileReleaseVersion: evidence.profileReleaseVersion,
    providerToolVersion: evidence.providerToolVersion,
    applicationVersion: evidence.applicationVersion,
    incidentGroupId: null,
    incidentGroup: null,
    fingerprintGroup: {
      fingerprint,
      count: 1,
      firstOccurrence: now,
      lastOccurrence: now,
    },
  };
  return json(userReportResponse(row), { status: 201 });
}

export async function handleGetIssueReport(
  request: Request,
  env: SecurityEnv,
  reportId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await securityContext(request, env, ctx);
  const row = await env.SYNTILA_DB.prepare(
    `SELECT id, public_reference AS publicReference,
            reporter_user_id AS reporterUserId, workspace_id AS workspaceId,
            request_id AS requestId, assignment_id AS assignmentId,
            component, error_code AS errorCode, failure_stage AS failureStage,
            fingerprint, status, diagnostic_state AS diagnosticState,
            created_at AS createdAt, updated_at AS updatedAt
       FROM issue_reports WHERE id = ?1`,
  )
    .bind(reportId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Issue report not found");
  const report = reportRow(row);
  if (report.reporterUserId !== actor.userId) {
    const requestRow = await env.SYNTILA_DB.prepare(
      "SELECT thread_id AS threadId FROM work_requests WHERE id = ?1",
    )
      .bind(report.requestId)
      .first<{ threadId: string }>();
    if (!requestRow) throw new HttpError(404, "Issue report not found");
    await authorizeThreadAccess(request, env, requestRow.threadId, "view", ctx);
  }
  await recordEvent(env, report.id, actor.userId, "report.viewed");
  return json(userReportResponse(report));
}

/** Returns the reporter's latest report for a Work request, if one exists. */
export async function handleGetIssueReportForRequest(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await securityContext(request, env, ctx);
  const url = new URL(request.url);
  const requestId = boundedToken(url.searchParams.get("requestId"));
  const assignmentId = boundedToken(url.searchParams.get("assignmentId"));
  if (!requestId) throw new HttpError(400, "requestId is required");
  const row = await env.SYNTILA_DB.prepare(
    `SELECT id, public_reference AS publicReference,
            reporter_user_id AS reporterUserId, workspace_id AS workspaceId,
            request_id AS requestId, assignment_id AS assignmentId,
            component, error_code AS errorCode, failure_stage AS failureStage,
            fingerprint, status, diagnostic_state AS diagnosticState,
            created_at AS createdAt, updated_at AS updatedAt
       FROM issue_reports
      WHERE reporter_user_id = ?1 AND request_id = ?2
        AND (?3::text IS NULL OR assignment_id = ?3)
      ORDER BY created_at DESC, id DESC LIMIT 1`,
  )
    .bind(actor.userId, requestId, assignmentId)
    .first<Record<string, unknown>>();
  return row
    ? json(userReportResponse(reportRow(row)))
    : json({ report: null });
}

export async function handleListAdminIssueReports(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await issueSupportContext(request, env, ctx);
  const url = new URL(request.url);
  const limit = Math.min(
    Math.max(Number(url.searchParams.get("limit") ?? 50), 1),
    100,
  );
  const allowedStatuses = new Set<ReportStatus>([
    "open",
    "investigating",
    "resolved",
    "dismissed",
  ]);
  const filters: string[] = [];
  const params: Array<string | number> = [];
  const status = url.searchParams.get("status");
  if (status) {
    if (!allowedStatuses.has(status as ReportStatus))
      throw new HttpError(400, "Invalid issue report status filter");
    filters.push("ir.status = ?");
    params.push(status);
  }
  for (const [name, column, message] of [
    ["component", "ir.component", "Invalid component filter"],
    ["errorCode", "ir.error_code", "Invalid error code filter"],
    ["workerTypeId", "ir.worker_type_id", "Invalid worker filter"],
  ] as const) {
    const value = url.searchParams.get(name);
    if (value != null) {
      const token = boundedToken(value, 128);
      if (!token) throw new HttpError(400, message);
      filters.push(`${column} = ?`);
      params.push(token);
    }
  }
  for (const [name, operator] of [
    ["createdAfter", ">="],
    ["createdBefore", "<"],
  ] as const) {
    const value = url.searchParams.get(name);
    if (value != null) {
      const parsed = new Date(value);
      if (Number.isNaN(parsed.valueOf()))
        throw new HttpError(400, `Invalid ${name} date`);
      filters.push(`ir.created_at ${operator} ?`);
      params.push(parsed.toISOString());
    }
  }
  params.push(limit);
  const rows = await env.SYNTILA_DB.prepare(
    `${reportSelect()}${filters.length ? ` WHERE ${filters.join(" AND ")}` : ""}
       ORDER BY ir.created_at DESC, ir.id DESC LIMIT ?`,
  )
    .bind(...params)
    .all<Record<string, unknown>>();
  const listedReports = (rows.results ?? []).map(reportRow);
  const audit = Promise.all(
    listedReports.map((report) =>
      recordEvent(env, report.id, actor.userId, "report.admin_listed"),
    ),
  );
  if (ctx) ctx.waitUntil(audit);
  else await audit;
  return json({
    reports: listedReports.map(adminReportResponse),
    filters: {
      status: status ?? null,
      component: url.searchParams.get("component"),
      errorCode: url.searchParams.get("errorCode"),
      workerTypeId: url.searchParams.get("workerTypeId"),
      createdAfter: url.searchParams.get("createdAfter"),
      createdBefore: url.searchParams.get("createdBefore"),
    },
  });
}

function adminReportResponse(report: ReportRow): Record<string, unknown> {
  return {
    id: report.id,
    publicReference: report.publicReference,
    requestId: report.requestId,
    assignmentId: report.assignmentId,
    workspaceId: report.workspaceId,
    component: report.component,
    errorCode: report.errorCode,
    failureStage: report.failureStage,
    fingerprint: report.fingerprint,
    status: report.status,
    diagnosticState: report.diagnosticState,
    createdAt: report.createdAt,
    updatedAt: report.updatedAt,
    workerTypeId: report.workerTypeId,
    modelId: report.modelId,
    effort: report.effort,
    versions: {
      application: report.applicationVersion,
      engine: report.engineVersion,
      profileDefinition: report.profileDefinitionId,
      profileRelease: report.profileReleaseVersion,
      providerTool: report.providerToolVersion,
    },
    incidentGroup: report.incidentGroup,
    fingerprintGroup: report.fingerprintGroup,
  };
}

export async function handleGetAdminIssueReport(
  request: Request,
  env: SecurityEnv,
  reportId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await issueSupportContext(request, env, ctx);
  const row = await env.SYNTILA_DB.prepare(`${reportSelect()} WHERE ir.id = ?1`)
    .bind(reportId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Issue report not found");
  const report = reportRow(row);
  const diagnostic = await env.SYNTILA_DB.prepare(
    `SELECT schema_version AS schemaVersion, diagnostic_json AS diagnosticJson,
            bundle_key AS bundleKey, bundle_sha256 AS bundleSha256,
            created_at AS createdAt
       FROM issue_report_diagnostics WHERE report_id = ?1`,
  )
    .bind(report.id)
    .first<Record<string, unknown>>();
  const events = await env.SYNTILA_DB.prepare(
    `SELECT id, actor_user_id AS actorUserId, event_type AS eventType,
            from_status AS fromStatus, to_status AS toStatus,
            details_json AS detailsJson, created_at AS createdAt
       FROM issue_report_events WHERE report_id = ?1 ORDER BY created_at, id`,
  )
    .bind(report.id)
    .all<Record<string, unknown>>();
  await recordEvent(env, report.id, actor.userId, "report.admin_viewed");
  const diagnosticData = diagnostic
    ? parseJsonRecord(diagnostic.diagnosticJson)
    : null;
  const diagnosticEvents = Array.isArray(diagnosticData?.events)
    ? diagnosticData!.events.filter(
        (event): event is Record<string, unknown> =>
          !!event && typeof event === "object" && !Array.isArray(event),
      )
    : [];
  const reportEvents = (events.results ?? []).map((event) => ({
    id: String(event.id),
    actorUserId: event.actorUserId == null ? null : String(event.actorUserId),
    eventType: String(event.eventType),
    fromStatus: event.fromStatus == null ? null : String(event.fromStatus),
    toStatus: event.toStatus == null ? null : String(event.toStatus),
    details: parseJsonRecord(event.detailsJson),
    createdAt: String(event.createdAt),
  }));
  const timeline = [
    ...diagnosticEvents.map((event) => ({
      timestamp: String(
        event.timestamp ?? diagnostic?.createdAt ?? report.createdAt,
      ),
      source: "diagnostic",
      eventType: "diagnostic.event",
      component: event.component ?? null,
      stage: event.stage ?? null,
      severity: event.severity ?? null,
      errorCode: event.errorCode ?? null,
      retryable: event.retryable === true,
      details: event.context ?? {},
    })),
    ...reportEvents.map((event) => ({
      timestamp: event.createdAt,
      source: "report",
      eventType: event.eventType,
      component: null,
      stage: null,
      severity: null,
      errorCode: null,
      retryable: false,
      details: {
        fromStatus: event.fromStatus,
        toStatus: event.toStatus,
        actorUserId: event.actorUserId,
        ...event.details,
      },
    })),
  ].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  const firstError =
    diagnosticEvents.find((event) => event.severity === "error") ?? null;
  const workspaceEvidence = diagnosticData?.workspace;
  const missingEvidence: string[] = [];
  if (!diagnostic) missingEvidence.push("diagnostic_record");
  if (!diagnosticEvents.length) missingEvidence.push("execution_timeline");
  if (
    !workspaceEvidence ||
    (typeof workspaceEvidence === "object" &&
      (workspaceEvidence as Record<string, unknown>).state !== "connected")
  ) {
    missingEvidence.push("workspace_diagnostics");
  }
  if (!report.providerToolVersion) missingEvidence.push("provider_version");
  if (!report.applicationVersion) missingEvidence.push("application_version");
  return json({
    report: adminReportResponse(report),
    diagnostics: diagnostic
      ? {
          schemaVersion: diagnostic.schemaVersion,
          data: diagnosticData,
          bundleKey: diagnostic.bundleKey ?? null,
          bundleSha256: diagnostic.bundleSha256 ?? null,
          createdAt: diagnostic.createdAt,
        }
      : null,
    events: reportEvents,
    timeline,
    investigation: {
      execution: diagnosticData?.execution ?? {
        requestId: report.requestId,
        assignmentId: report.assignmentId,
      },
      worker: {
        workerTypeId: report.workerTypeId,
        modelId: report.modelId,
        effort: report.effort,
      },
      versions: {
        application: report.applicationVersion,
        engine: report.engineVersion,
        profileDefinition: report.profileDefinitionId,
        profileRelease: report.profileReleaseVersion,
        providerTool: report.providerToolVersion,
      },
      workspace: workspaceEvidence ?? { state: "unavailable" },
      failure: {
        component: report.component,
        stage: report.failureStage,
        errorCode: report.errorCode,
        firstSignificantError: firstError,
      },
      missingEvidence: [...new Set(missingEvidence)],
    },
  });
}

export async function handlePatchAdminIssueReport(
  request: Request,
  env: SecurityEnv,
  reportId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await issueSupportContext(request, env, ctx);
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (contentLength > MAX_SUPPORT_NOTE_LENGTH + 512)
    throw new HttpError(413, "Issue update is too large");
  let body: unknown;
  try {
    body = JSON.parse(await request.text());
  } catch {
    throw new HttpError(400, "Issue update must be valid JSON");
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    throw new HttpError(400, "Issue update must be an object");
  const value = body as Record<string, unknown>;
  if (
    Object.keys(value).some(
      (key) => !["status", "note", "groupId"].includes(key),
    )
  )
    throw new HttpError(400, "Only status, note and groupId may be supplied");
  const status = value.status;
  if (
    status != null &&
    !["open", "investigating", "resolved", "dismissed"].includes(String(status))
  )
    throw new HttpError(400, "Invalid issue report status");
  const note = value.note == null ? null : String(value.note).trim();
  if (note != null && note.length > MAX_SUPPORT_NOTE_LENGTH)
    throw new HttpError(413, "Issue note is too large");
  const groupWasSupplied = Object.prototype.hasOwnProperty.call(
    value,
    "groupId",
  );
  const requestedGroupId = !groupWasSupplied
    ? undefined
    : value.groupId == null
      ? null
      : boundedToken(value.groupId, 128);
  if (groupWasSupplied && !requestedGroupId)
    throw new HttpError(400, "Invalid incident group");
  const existing = await env.SYNTILA_DB.prepare(
    "SELECT status, incident_group_id AS incidentGroupId FROM issue_reports WHERE id = ?1",
  )
    .bind(reportId)
    .first<{ status: ReportStatus; incidentGroupId: string | null }>();
  if (!existing) throw new HttpError(404, "Issue report not found");
  const currentStatus = existing.status as ReportStatus;
  const nextStatus = (
    status == null ? currentStatus : String(status)
  ) as ReportStatus;
  const allowedNext: Record<ReportStatus, ReportStatus[]> = {
    open: ["open", "investigating"],
    investigating: ["investigating", "resolved", "dismissed"],
    resolved: ["resolved"],
    dismissed: ["dismissed"],
  };
  if (!allowedNext[currentStatus]?.includes(nextStatus))
    throw new HttpError(
      409,
      `Cannot change issue status from ${currentStatus} to ${nextStatus}`,
    );
  if (requestedGroupId != null) {
    const group = await env.SYNTILA_DB.prepare(
      "SELECT id FROM issue_report_groups WHERE id = ?1",
    )
      .bind(requestedGroupId)
      .first<{ id: string }>();
    if (!group) throw new HttpError(404, "Incident group not found");
  }
  const now = new Date().toISOString();
  const statements = [
    env.SYNTILA_DB.prepare(
      "UPDATE issue_reports SET status = ?1, incident_group_id = ?2, updated_at = ?3 WHERE id = ?4",
    ).bind(
      nextStatus,
      requestedGroupId === undefined
        ? existing.incidentGroupId
        : requestedGroupId,
      now,
      reportId,
    ),
    env.SYNTILA_DB.prepare(
      `INSERT INTO issue_report_events
         (id, report_id, actor_user_id, event_type, from_status, to_status, details_json, created_at)
       VALUES (?1, ?2, ?3, 'report.status_changed', ?4, ?5, ?6, ?7)`,
    ).bind(
      `ire-${crypto.randomUUID()}`,
      reportId,
      actor.userId,
      existing.status,
      nextStatus,
      JSON.stringify(note ? { note } : {}),
      now,
    ),
  ];
  const nextGroupId =
    requestedGroupId === undefined
      ? existing.incidentGroupId
      : requestedGroupId;
  if (existing.incidentGroupId !== nextGroupId) {
    statements.push(
      env.SYNTILA_DB.prepare(
        `INSERT INTO issue_report_events
           (id, report_id, actor_user_id, event_type, details_json, created_at)
         VALUES (?1, ?2, ?3, 'report.group_changed', ?4, ?5)`,
      ).bind(
        `ire-${crypto.randomUUID()}`,
        reportId,
        actor.userId,
        JSON.stringify({
          fromGroupId: existing.incidentGroupId ?? null,
          toGroupId: nextGroupId,
        }),
        now,
      ),
    );
    for (const groupId of [existing.incidentGroupId, nextGroupId]) {
      if (groupId != null) {
        statements.push(
          env.SYNTILA_DB.prepare(
            "UPDATE issue_report_groups SET updated_at = ?1 WHERE id = ?2",
          ).bind(now, groupId),
        );
      }
    }
  }
  await env.SYNTILA_DB.batch(statements);
  const updated = await env.SYNTILA_DB.prepare(
    `${reportSelect()} WHERE ir.id = ?1`,
  )
    .bind(reportId)
    .first<Record<string, unknown>>();
  return json({ report: adminReportResponse(reportRow(updated!)) });
}

function groupReference(): string {
  return `INC-${Date.now().toString(36).toUpperCase()}-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
}

export async function handleListAdminIssueReportGroups(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  await issueSupportContext(request, env, ctx);
  const limit = Math.min(
    Math.max(Number(new URL(request.url).searchParams.get("limit") ?? 100), 1),
    200,
  );
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT g.id, g.public_reference AS publicReference, g.label, g.fingerprint,
            g.created_at AS createdAt, g.updated_at AS updatedAt,
            COUNT(r.id) AS reportCount, MIN(r.created_at) AS firstOccurrence,
            MAX(r.created_at) AS lastOccurrence,
            string_agg(DISTINCT r.worker_type_id, ',') AS workerTypes,
            string_agg(DISTINCT r.provider_tool_version, ',') AS providerVersions,
            string_agg(DISTINCT r.engine_version, ',') AS engineVersions,
            string_agg(DISTINCT r.profile_definition_id || '@' || r.profile_release_version, ',') AS profileVersions
       FROM issue_report_groups g
       LEFT JOIN issue_reports r ON r.incident_group_id = g.id
      GROUP BY g.id ORDER BY g.updated_at DESC, g.id DESC LIMIT ?1`,
  )
    .bind(limit)
    .all<Record<string, unknown>>();
  return json({
    groups: (rows.results ?? []).map((row) => ({
      id: String(row.id),
      publicReference: String(row.publicReference),
      label: String(row.label),
      fingerprint: row.fingerprint == null ? null : String(row.fingerprint),
      reportCount: Number(row.reportCount ?? 0),
      firstOccurrence:
        row.firstOccurrence == null ? null : String(row.firstOccurrence),
      lastOccurrence:
        row.lastOccurrence == null ? null : String(row.lastOccurrence),
      affectedWorkerTypes: row.workerTypes
        ? String(row.workerTypes).split(",")
        : [],
      affectedProviderVersions: row.providerVersions
        ? String(row.providerVersions).split(",")
        : [],
      affectedEngineVersions: row.engineVersions
        ? String(row.engineVersions).split(",")
        : [],
      affectedProfileVersions: row.profileVersions
        ? String(row.profileVersions).split(",")
        : [],
      createdAt: String(row.createdAt),
      updatedAt: String(row.updatedAt),
    })),
  });
}

export async function handleCreateAdminIssueReportGroup(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const actor = await issueSupportContext(request, env, ctx);
  let body: unknown;
  try {
    body = JSON.parse(await request.text());
  } catch {
    throw new HttpError(400, "Incident group must be valid JSON");
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    throw new HttpError(400, "Incident group must be an object");
  const value = body as Record<string, unknown>;
  if (Object.keys(value).some((key) => !["label", "fingerprint"].includes(key)))
    throw new HttpError(400, "Only label and fingerprint may be supplied");
  const label = typeof value.label === "string" ? value.label.trim() : "";
  if (!label || label.length > 160)
    throw new HttpError(400, "A group label is required");
  const fingerprint =
    value.fingerprint == null ? null : boundedToken(value.fingerprint, 128);
  if (value.fingerprint != null && !fingerprint)
    throw new HttpError(400, "Invalid fingerprint");
  const id = `issue-group-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  const reference = groupReference();
  await env.SYNTILA_DB.prepare(
    `INSERT INTO issue_report_groups (id, public_reference, label, fingerprint, created_by_user_id, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)`,
  )
    .bind(id, reference, label, fingerprint, actor.userId, now)
    .run();
  return json(
    {
      group: {
        id,
        publicReference: reference,
        label,
        fingerprint,
        reportCount: 0,
        createdAt: now,
        updatedAt: now,
      },
    },
    { status: 201 },
  );
}

export async function handleGetAdminIssueReportGroup(
  request: Request,
  env: SecurityEnv,
  groupId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await issueSupportContext(request, env, ctx);
  const group = await env.SYNTILA_DB.prepare(
    `SELECT id, public_reference AS publicReference, label, fingerprint,
            created_at AS createdAt, updated_at AS updatedAt
       FROM issue_report_groups WHERE id = ?1`,
  )
    .bind(groupId)
    .first<Record<string, unknown>>();
  if (!group) throw new HttpError(404, "Incident group not found");
  const reports = await env.SYNTILA_DB.prepare(
    `${reportSelect()} WHERE ir.incident_group_id = ?1 ORDER BY ir.created_at DESC, ir.id DESC`,
  )
    .bind(groupId)
    .all<Record<string, unknown>>();
  return json({
    group: {
      id: String(group.id),
      publicReference: String(group.publicReference),
      label: String(group.label),
      fingerprint: group.fingerprint == null ? null : String(group.fingerprint),
      createdAt: String(group.createdAt),
      updatedAt: String(group.updatedAt),
      reports: (reports.results ?? []).map(reportRow).map(adminReportResponse),
    },
  });
}
