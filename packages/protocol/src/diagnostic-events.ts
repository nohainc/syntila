import { z } from "zod";

export const DIAGNOSTIC_EVENT_SCHEMA_VERSION = 1 as const;

/** Shared trace stages used to follow one assignment across Cloud and Service. */
export const EXECUTION_TRACE_STAGES = [
  "dispatch",
  "accepted",
  "slot_reservation",
  "engine_startup",
  "provider_execution",
  "activity_forwarding",
  "terminal_recorded",
  "terminal_acknowledgement",
] as const;
export type ExecutionTraceStage = (typeof EXECUTION_TRACE_STAGES)[number];

/**
 * Ordered latency stages from Web submission to Web receipt of the outcome.
 * `TRACE_STAGE_NUMBERS` maps the first twelve to the T1-T12 labels used in
 * the latency baseline. Auxiliary stages are not numbered: they measure
 * delivery acknowledgement and Workflow outcome observation lag.
 */
export const TRACE_STAGES = [
  "web_submitted",
  "cloud_accepted",
  "workflow_dispatch_started",
  "gateway_queued",
  "service_received",
  "service_accepted",
  "profile_resolved",
  "slot_reserved",
  "engine_process_created",
  "provider_started",
  "terminal_persisted",
  "web_received",
] as const;
export type TraceStage = (typeof TRACE_STAGES)[number];

export const AUXILIARY_TRACE_STAGES = [
  "workflow_completed",
  "provider_first_output",
  "provider_last_output_reported",
  "provider_process_exited",
  "engine_result_received",
  "service_result_persisted",
  "service_result_sending",
  "cloud_ack_received",
  "workflow_observed_terminal",
  "probe_sent",
  "probe_acknowledged",
  // Local startup milestones between Service admission and provider start.
  // Auxiliary so the T1-T12 numbering is unchanged.
  "worker_resolved",
  "profile_ready",
  "waiting_for_space",
  "queued_for_slot",
  "engine_initialized",
] as const;
export type AuxiliaryTraceStage = (typeof AUXILIARY_TRACE_STAGES)[number];

export const ALL_TRACE_STAGES = [
  ...TRACE_STAGES,
  ...AUXILIARY_TRACE_STAGES,
] as const;

/** T1..T12 label for a numbered stage; undefined for auxiliary stages. */
export function traceStageNumber(stage: string): number | undefined {
  const index = (TRACE_STAGES as readonly string[]).indexOf(stage);
  return index < 0 ? undefined : index + 1;
}

const boundedToken = z
  .string()
  .min(1)
  .max(128)
  .regex(/^[A-Za-z0-9._:-]+$/);

/** Closed diagnostic context: values are bounded scalars only. */
export const DiagnosticContextSchema = z
  .object({
    workspaceVersion: boundedToken.optional(),
    engineVersion: boundedToken.optional(),
    profileDefinitionId: boundedToken.optional(),
    profileReleaseVersion: z.number().int().positive().optional(),
    profileResolutionSource: boundedToken.optional(),
    profileDigest: z
      .string()
      .regex(/^[a-f0-9]{64}$/)
      .optional(),
    providerToolName: z.string().min(1).max(128).optional(),
    providerToolVersion: boundedToken.optional(),
    protocolStage: boundedToken.optional(),
    failureLayer: boundedToken.optional(),
    processExitCode: z.number().int().optional(),
    durationMs: z.number().int().nonnegative().max(2_147_483_647).optional(),
    connectionState: boundedToken.optional(),
    transport: boundedToken.optional(),
    status: boundedToken.optional(),
    modelId: boundedToken.optional(),
    effort: boundedToken.optional(),
    catalogRevision: z
      .string()
      .regex(/^[a-f0-9]{64}$/)
      .optional(),
    selectionSource: boundedToken.optional(),
    lineBytes: z.number().int().nonnegative().max(4_194_304).optional(),
    httpStatusCode: z.number().int().min(100).max(599).optional(),
    recovered: z.boolean().optional(),
    /** Latency stage; see TRACE_STAGES. */
    traceStage: z.enum(ALL_TRACE_STAGES).optional(),
    /** Emitter-local monotonic milliseconds (not comparable across hosts). */
    monotonicMs: z.number().int().nonnegative().max(2_147_483_647).optional(),
    /** Process epoch owning the monotonic clock; changes on Service restart. */
    traceEpochId: boundedToken.optional(),
    /** Estimated (Cloud clock - emitter clock) in ms, from heartbeat samples. */
    clockOffsetMs: z.number().int().min(-86_400_000).max(86_400_000).optional(),
    /** Round-trip time of the heartbeat sample behind clockOffsetMs. */
    clockRttMs: z.number().int().nonnegative().max(600_000).optional(),
    /** Service connection stage, e.g. ready or synchronizing. */
    syncState: boundedToken.optional(),
    /** Service-local admission timings, measured independently of host clocks. */
    receiveToAckMs: z.number().int().nonnegative().max(600_000).optional(),
    journalLookupUs: z.number().int().nonnegative().max(600_000_000).optional(),
    receivedJournalUs: z.number().int().nonnegative().max(600_000_000).optional(),
    acceptedJournalUs: z.number().int().nonnegative().max(600_000_000).optional(),
    localQueueLength: z.number().int().nonnegative().max(100_000).optional(),
    activeAssignments: z.number().int().nonnegative().max(100_000).optional(),
    probeId: boundedToken.optional(),
    /** One-based position in the Worker's local queue. */
    queuePosition: z.number().int().min(1).max(100_000).optional(),
    /** Effective local concurrency limit of the Worker. */
    slotLimit: z.number().int().min(1).max(100_000).optional(),
    /** The local queue allowance granted to the assignment. */
    queueWaitTimeoutMs: z
      .number()
      .int()
      .nonnegative()
      .max(2_147_483_647)
      .optional(),
    /** Whether a busy native provider session is also holding it back. */
    waitingForSession: z.boolean().optional(),
  })
  .strict();

export const DiagnosticEventSchema = z
  .object({
    schemaVersion: z.literal(DIAGNOSTIC_EVENT_SCHEMA_VERSION),
    eventId: boundedToken,
    timestamp: z.string().datetime({ offset: true }),
    requestId: boundedToken.optional(),
    assignmentId: boundedToken.optional(),
    workspaceId: boundedToken.optional(),
    workspaceRuntimeId: boundedToken.optional(),
    workerId: boundedToken.optional(),
    workerTypeId: boundedToken.optional(),
    runId: boundedToken.optional(),
    taskId: boundedToken.optional(),
    attemptId: boundedToken.optional(),
    component: boundedToken,
    operation: boundedToken,
    stage: boundedToken,
    severity: z.enum(["debug", "info", "warning", "error"]),
    errorCode: boundedToken.optional(),
    retryable: z.boolean(),
    context: DiagnosticContextSchema.optional(),
  })
  .strict();

export type DiagnosticEvent = z.infer<typeof DiagnosticEventSchema>;
export type DiagnosticContext = z.infer<typeof DiagnosticContextSchema>;

export function createDiagnosticEvent(
  input: Omit<DiagnosticEvent, "schemaVersion" | "eventId" | "timestamp"> &
    Partial<Pick<DiagnosticEvent, "eventId" | "timestamp">>,
): DiagnosticEvent {
  return DiagnosticEventSchema.parse({
    ...input,
    schemaVersion: DIAGNOSTIC_EVENT_SCHEMA_VERSION,
    eventId: input.eventId ?? `diag-${crypto.randomUUID()}`,
    timestamp: input.timestamp ?? new Date().toISOString(),
  });
}

/** Fails closed when a provider or Workspace sends an unexpected shape. */
export function parseDiagnosticEvent(input: unknown): DiagnosticEvent {
  return DiagnosticEventSchema.parse(input);
}
