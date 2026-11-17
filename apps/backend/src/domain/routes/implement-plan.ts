import { queryOf } from "../../platform/data.js";
import { ApprovePlanSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { appendToQueue, lockQueue, prependToQueue } from "./queue-positions.js";
import { HttpError, json, type SecurityEnv } from "./http-security.js";
import { authorizeThreadAccess } from "./thread-policy.js";
import { advanceThreadQueueSafely } from "./thread-request-queue.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import {
  BUILTIN_WORKFLOWS,
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
} from "@syntila/core";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import { parseWorkflowExecutionSelection } from "./workflow-execution-configuration.js";

export type VerificationMode = "none" | "per_phase" | "final";

export interface ParsedPhase {
  id: number | string;
  title: string;
  description: string;
  files?: string[];
  criteria?: string;
}

function unquote(value: string): string {
  const v = value.trim();
  const q = v[0];
  if ((q === '"' || q === "'") && v.length >= 2 && v.endsWith(q)) {
    return v.slice(1, -1).replace(/\\(["'\\])/g, "$1");
  }
  return v;
}

/**
 * Line-based parser for the constrained phases YAML: a `- ` item list whose
 * scalar values may be quoted, continued on indented lines, or (for `files`)
 * written as an inline `[a, b]` list or a nested `- path` list.
 */
function parseYamlPhases(raw: string): ParsedPhase[] {
  const items: Array<Record<string, string | string[]>> = [];
  let current: Record<string, string | string[]> | null = null;
  let lastKey: string | null = null;
  let itemIndent = -1;

  for (const line of raw.split("\n")) {
    if (!line.trim() || /^\s*phases:\s*$/i.test(line)) continue;
    const indent = line.length - line.trimStart().length;
    const trimmed = line.trim();
    const keyMatch = trimmed.match(/^(?:-\s+)?([A-Za-z_]+):\s*(.*)$/);
    const isItemStart =
      trimmed.startsWith("- ") &&
      keyMatch !== null &&
      (itemIndent < 0 || indent <= itemIndent);
    if (isItemStart) {
      itemIndent = itemIndent < 0 ? indent : itemIndent;
      current = {};
      items.push(current);
    }
    if (!current) continue;
    if (keyMatch && (isItemStart || !trimmed.startsWith("- "))) {
      lastKey = keyMatch[1]!.toLowerCase();
      const value = keyMatch[2]!;
      if (lastKey === "files") {
        const inline = value.match(/^\[(.*)\]$/);
        current.files = inline
          ? inline[1]!
              .split(",")
              .map((f) => unquote(f))
              .filter(Boolean)
          : [];
      } else {
        current[lastKey] = unquote(value);
      }
    } else if (trimmed.startsWith("- ") && lastKey === "files") {
      (current.files as string[]).push(unquote(trimmed.slice(2)));
    } else if (
      lastKey &&
      lastKey !== "files" &&
      typeof current[lastKey] === "string"
    ) {
      current[lastKey] = `${current[lastKey]} ${unquote(trimmed)}`.trim();
    }
  }

  return items
    .filter((item) => typeof item.title === "string" && item.title !== "")
    .map((item, idx) => ({
      id: idx + 1,
      title: item.title as string,
      description: typeof item.description === "string" ? item.description : "",
      files: Array.isArray(item.files) ? item.files : [],
      criteria:
        typeof item.criteria === "string" && item.criteria
          ? item.criteria
          : undefined,
    }));
}

/**
 * Extracts structured implementation phases from a planning worker's output text.
 * Prioritizes ```yaml:phases or ```json:phases blocks; falls back to Markdown
 * section headers (e.g. `### Phase 1: Title`).
 */
export function parseImplementationPhases(planText: string): ParsedPhase[] {
  if (!planText || !planText.trim()) return [];

  // 1. Try yaml:phases or yaml fence with "phases:"
  const yamlMatch = planText.match(
    /```(?:yaml:phases|yaml|json:phases|json)\s*\n([\s\S]*?)```/i,
  );
  if (yamlMatch) {
    const rawContent = yamlMatch[1]!.trim();
    if (rawContent.startsWith("{") || rawContent.startsWith("[")) {
      try {
        const parsed = JSON.parse(rawContent);
        const list = Array.isArray(parsed) ? parsed : parsed.phases;
        if (Array.isArray(list) && list.length > 0) {
          return list.map((item, idx) => ({
            id: item.id ?? idx + 1,
            title: String(item.title ?? `Phase ${idx + 1}`),
            description: String(item.description ?? ""),
            files: Array.isArray(item.files) ? item.files.map(String) : [],
            criteria: item.criteria ? String(item.criteria) : undefined,
          }));
        }
      } catch {
        // Fall back to line/markdown parser
      }
    } else {
      const phases = parseYamlPhases(rawContent);
      if (phases.length > 0) return phases;
    }
  }

  // 2. Fall back to parsing Markdown headers: `### Phase 1: <Title>` or `## Phase 1: <Title>`
  const phaseHeaderRegex = /(?:^|\n)#{2,4}\s*Phase\s*(\d+)[:\s-]*([^\n]+)/gi;
  const matches: Array<{ id: number; title: string; startIndex: number }> = [];
  let match: RegExpExecArray | null;
  while ((match = phaseHeaderRegex.exec(planText)) !== null) {
    matches.push({
      id: parseInt(match[1]!, 10),
      title: match[2]!.trim(),
      startIndex: match.index,
    });
  }

  if (matches.length > 0) {
    return matches.map((item, i) => {
      const nextIndex = matches[i + 1]?.startIndex ?? planText.length;
      const sectionBody = planText.slice(item.startIndex, nextIndex);
      const descMatch = sectionBody.match(
        /(?:Goal|Description|Purpose)[:\s]*([^\n]+)/i,
      );
      const criteriaMatch = sectionBody.match(
        /(?:Completion Criteria|Criteria)[:\s]*([^\n]+)/i,
      );
      return {
        id: item.id || i + 1,
        title: item.title,
        description: descMatch ? descMatch[1]!.trim() : item.title,
        criteria: criteriaMatch ? criteriaMatch[1]!.trim() : undefined,
      };
    });
  }

  // 3. Fallback: single phase containing the whole plan
  return [
    {
      id: 1,
      title: "Implementation Phase",
      description: "Execute the approved implementation plan",
    },
  ];
}

interface ApprovePlanBody {
  verificationMode?: VerificationMode;
  customPhases?: ParsedPhase[];
  implementer?: unknown;
  verifier?: unknown;
}

/**
 * POST /api/work-requests/:id/approve-plan
 *
 * Approves a generated implementation plan and enqueues the individual
 * implementation phases (and optional verification steps) into the
 * Thread Request Queue as special locked items.
 */
export async function handleApprovePlan(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (request.method !== "POST") throw new HttpError(405, "Method not allowed");

  const db = env.SYNTILA_DB;
  const workRequest = await queryOf(db).row<{
      id: string;
      threadId: string;
      requestedByUserId: string;
      workflowId: string;
      status: string;
      spaceId: string;
    }>`SELECT wr.id, wr.thread_id AS "threadId", wr.requested_by_user_id AS "requestedByUserId",
              wr.workflow_id AS "workflowId", wr.status, t.space_id AS "spaceId"
         FROM work_requests wr
         JOIN threads t ON t.id = wr.thread_id
        WHERE wr.id = ${workRequestId}`;

  if (!workRequest) throw new HttpError(404, "Work request not found");
  if (workRequest.workflowId !== "plan_implement") {
    throw new HttpError(400, "Only Implement workflow plans can be approved");
  }

  const { context } = await authorizeThreadAccess(
    request,
    env,
    workRequest.threadId,
    "execute",
    ctx,
  );

  const planTask = await queryOf(db).row<{ outputJson: string | null; status: string }>`SELECT output_json AS "outputJson", status
         FROM workflow_tasks
        WHERE work_request_id = ${workRequestId} AND step_kind = 'plan'
        ORDER BY attempt DESC LIMIT 1`;

  if (!planTask || planTask.status !== "completed" || !planTask.outputJson) {
    throw new HttpError(
      400,
      "The implementation plan has not completed successfully yet",
    );
  }

  let planText = "";
  try {
    const parsedOutput = JSON.parse(planTask.outputJson);
    planText =
      typeof parsedOutput === "string"
        ? parsedOutput
        : (parsedOutput.text ?? JSON.stringify(parsedOutput));
  } catch {
    planText = planTask.outputJson;
  }

  // An empty body takes the defaults; a malformed one is a 400.
  const body = (await readBody(request, ApprovePlanSchema)) as ApprovePlanBody;

  const verificationMode: VerificationMode = body.verificationMode ?? "none";
  if (body.customPhases !== undefined) {
    const valid =
      Array.isArray(body.customPhases) &&
      body.customPhases.every(
        (p) =>
          p &&
          typeof p.title === "string" &&
          p.title.trim() !== "" &&
          typeof p.description === "string",
      );
    if (!valid) throw new HttpError(400, "Invalid customPhases");
  }
  const phases =
    body.customPhases && body.customPhases.length > 0
      ? body.customPhases
      : parseImplementationPhases(planText);

  // Friendly early refusal; the claim inserted with the phases below is the
  // guarantee (plan_approvals_pkey).
  const alreadyApproved = await queryOf(db).row`SELECT 1 AS found FROM plan_approvals WHERE plan_work_request_id = ${workRequestId}`;
  if (alreadyApproved)
    throw new HttpError(409, "This plan was already approved");

  if (phases.length === 0) {
    throw new HttpError(
      400,
      "Could not identify any implementation phases in the plan",
    );
  }

  // Resolve workflow configuration for plan_implement to get default implementer and verifier selections
  const spaceWorkflowConfig = await loadSpaceWorkflowConfigurations(
    env,
    workRequest.spaceId,
    "plan_implement",
  );
  const planImplementDef = BUILTIN_WORKFLOWS.plan_implement;
  const parsedConfig = spaceWorkflowConfig.configurations[0]
    ? parseUserWorkflowConfiguration(
        planImplementDef,
        spaceWorkflowConfig.configurations[0],
      )
    : undefined;
  const effective = resolveUserWorkflowConfiguration(
    planImplementDef,
    parsedConfig,
  );

  const implementerOverride = body.implementer
    ? parseWorkflowExecutionSelection(body.implementer)
    : undefined;
  const verifierOverride = body.verifier
    ? parseWorkflowExecutionSelection(body.verifier)
    : undefined;

  const cleanSelection = (sel: {
    workerId?: string | null;
    model?: string | null;
    reasoningEffort?: string | null;
  }) => {
    const res: Record<string, string> = {};
    if (sel.workerId) res.workerId = sel.workerId;
    if (sel.model) res.model = sel.model;
    if (sel.reasoningEffort) res.reasoningEffort = sel.reasoningEffort;
    return Object.keys(res).length > 0 ? res : undefined;
  };

  const implementSelection = cleanSelection({
    workerId:
      implementerOverride?.workerId ?? effective.steps.implement?.worker,
    model: implementerOverride?.model ?? effective.steps.implement?.model,
    reasoningEffort:
      implementerOverride?.reasoningEffort ?? effective.steps.implement?.effort,
  });

  const verifySelection = cleanSelection({
    workerId: verifierOverride?.workerId ?? effective.steps.verify?.worker,
    model: verifierOverride?.model ?? effective.steps.verify?.model,
    reasoningEffort:
      verifierOverride?.reasoningEffort ?? effective.steps.verify?.effort,
  });

  // Order of the phases; the positions themselves are taken at insert time.
  let currentPosition = 1;
  const now = new Date().toISOString();
  const queueInserts: Array<{
    id: string;
    threadId: string;
    userId: string;
    requestJson: string;
    position: number;
  }> = [];

  const totalPhases = phases.length;

  for (let idx = 0; idx < phases.length; idx++) {
    const phase = phases[idx]!;
    const phaseNum = idx + 1;

    // Enqueue Implementation Phase
    const implementPrompt = [
      `Phase ${phaseNum}/${totalPhases}: ${phase.title}`,
      "",
      `Goal: ${phase.description}`,
      phase.files && phase.files.length > 0
        ? `Target files: ${phase.files.join(", ")}`
        : "",
      phase.criteria ? `Completion criteria: ${phase.criteria}` : "",
      "",
      "Carry out this phase according to the approved plan. Follow the implementation criteria.",
    ]
      .filter(Boolean)
      .join("\n");

    const implementRequest = {
      workflowId: "direct",
      ...(implementSelection ? { executionSelection: implementSelection } : {}),
      input: {
        originalRequest: implementPrompt,
        isPhased: true,
        planWorkRequestId: workRequestId,
        phaseIndex: phaseNum,
        totalPhases,
        phaseTitle: phase.title,
        isVerification: false,
      },
      isPhased: true,
      planWorkRequestId: workRequestId,
      phaseIndex: phaseNum,
      totalPhases,
      phaseTitle: phase.title,
      isVerification: false,
    };

    queueInserts.push({
      id: `trq-phase-${crypto.randomUUID()}`,
      threadId: workRequest.threadId,
      userId: context.userId,
      requestJson: JSON.stringify(implementRequest),
      position: currentPosition++,
    });

    // Enqueue Per-Phase Verification if requested
    if (verificationMode === "per_phase") {
      const verifyPrompt = [
        `Verify Phase ${phaseNum}/${totalPhases}: ${phase.title}`,
        "",
        `Completion criteria: ${phase.criteria ?? "Ensure all phase tasks completed without regressions."}`,
        "",
        "Independently inspect the changes made in this phase and report whether criteria are satisfied.",
      ]
        .filter(Boolean)
        .join("\n");

      const verifyRequest = {
        workflowId: "direct",
        ...(verifySelection ? { executionSelection: verifySelection } : {}),
        input: {
          originalRequest: verifyPrompt,
          isPhased: true,
          planWorkRequestId: workRequestId,
          phaseIndex: phaseNum,
          totalPhases,
          phaseTitle: `Verify Phase ${phaseNum}: ${phase.title}`,
          isVerification: true,
        },
        isPhased: true,
        planWorkRequestId: workRequestId,
        phaseIndex: phaseNum,
        totalPhases,
        phaseTitle: `Verify Phase ${phaseNum}: ${phase.title}`,
        isVerification: true,
      };

      queueInserts.push({
        id: `trq-verify-${crypto.randomUUID()}`,
        threadId: workRequest.threadId,
        userId: context.userId,
        requestJson: JSON.stringify(verifyRequest),
        position: currentPosition++,
      });
    }
  }

  // Enqueue Final Verification if requested
  if (verificationMode === "final") {
    const finalVerifyPrompt = [
      "Final Verification of Implementation Plan",
      "",
      "Review the completed implementation across all phases and verify against the original requirements and test suite.",
    ].join("\n");

    const finalVerifyRequest = {
      workflowId: "direct",
      ...(verifySelection ? { executionSelection: verifySelection } : {}),
      input: {
        originalRequest: finalVerifyPrompt,
        isPhased: true,
        planWorkRequestId: workRequestId,
        phaseIndex: totalPhases,
        totalPhases,
        phaseTitle: "Final Verification",
        isVerification: true,
        isFinalVerification: true,
      },
      isPhased: true,
      planWorkRequestId: workRequestId,
      phaseIndex: totalPhases,
      totalPhases,
      phaseTitle: "Final Verification",
      isVerification: true,
      isFinalVerification: true,
    };

    queueInserts.push({
      id: `trq-final-verify-${crypto.randomUUID()}`,
      threadId: workRequest.threadId,
      userId: context.userId,
      requestJson: JSON.stringify(finalVerifyRequest),
      position: currentPosition++,
    });
  }

  // All phases at the end of the queue, in order, in one transaction.
  await db.batch([
    lockQueue(db, workRequest.threadId),
    // The claim comes first: a second approval fails here and rolls back the
    // whole batch, so no phase of the loser is ever queued.
    db
      .prepare(
        "INSERT INTO plan_approvals (plan_work_request_id, thread_id, approved_by_user_id, created_at) VALUES (?1, ?2, ?3, ?4)",
      )
      .bind(workRequestId, workRequest.threadId, context.userId, now),
    ...[...queueInserts]
      .sort((a, b) => a.position - b.position)
      .map((item) =>
        appendToQueue(db, {
          id: item.id,
          threadId: item.threadId,
          authorUserId: item.userId,
          requestJson: item.requestJson,
          now,
        }),
      ),
  ]);

  // Trigger safe advance so Phase 1 starts immediately if nothing is running
  await advanceThreadQueueSafely(env, workRequest.threadId);
  await publishCollaborationEvent(
    env,
    "thread.queue_updated",
    workRequest.spaceId,
    workRequest.threadId,
    { threadId: workRequest.threadId },
  );

  return json({
    approved: true,
    workRequestId,
    enqueuedCount: queueInserts.length,
    phasesCount: totalPhases,
    verificationMode,
  });
}

/**
 * Evaluates whether a completed or failed work request is part of a phased
 * implementation workflow, inspects output markers (`STATUS: COMPLETED` vs
 * `STATUS: NEEDS_INPUT` or `STATUS: FAILED`), and either advances the thread
 * request queue or pauses it awaiting user intervention.
 */
export async function evaluatePhaseCompletionAndAdvanceQueue(
  env: SecurityEnv,
  threadId: string,
  workRequestId: string,
  type:
    "work_request.completed" | "work_request.failed" | "work_request.cancelled",
): Promise<{ paused: boolean; reason?: string }> {
  const db = env.SYNTILA_DB;
  if (!db || !workRequestId) {
    await advanceThreadQueueSafely(env, threadId, {
      failedRequest: type === "work_request.failed",
    });
    return { paused: type === "work_request.failed" };
  }

  try {
    const wr = await queryOf(db).row<{ inputJson: string | null }>`SELECT input_json AS "inputJson" FROM work_requests WHERE id = ${workRequestId}`;

    let inputData: Record<string, unknown> | null = null;
    try {
      inputData = wr?.inputJson ? JSON.parse(wr.inputJson) : null;
    } catch {
      // ignore JSON parse error
    }

    const isPhased = Boolean(inputData?.isPhased);
    const phaseTitle = String(
      inputData?.phaseTitle ??
        (inputData?.phaseIndex
          ? `Phase ${inputData.phaseIndex}`
          : "Implementation step"),
    );
    const isVerification = Boolean(inputData?.isVerification);

    if (type === "work_request.failed" || type === "work_request.cancelled") {
      const pauseMsg = isPhased
        ? `${phaseTitle} ${type === "work_request.cancelled" ? "was cancelled" : "failed to execute"}. Review and resume the queue when ready.`
        : undefined;
      await advanceThreadQueueSafely(env, threadId, {
        failedRequest: true,
        pauseMessage: pauseMsg,
      });
      return { paused: true, reason: pauseMsg };
    }

    if (type === "work_request.completed" && isPhased) {
      // Inspect task output to verify whether the phase completed cleanly
      const taskRow = await queryOf(db).row<{ outputJson: string | null }>`SELECT output_json AS "outputJson" FROM workflow_tasks
            WHERE work_request_id = ${workRequestId} AND step_kind IN ('implement', 'verify')
            ORDER BY attempt DESC, finished_at DESC LIMIT 1`;

      let outputText = "";
      try {
        const parsed = taskRow?.outputJson
          ? JSON.parse(taskRow.outputJson)
          : null;
        outputText =
          typeof parsed === "string"
            ? parsed
            : (parsed?.text ?? parsed?.output ?? JSON.stringify(parsed ?? ""));
      } catch {
        outputText = taskRow?.outputJson ?? "";
      }

      // Check if worker needs user input or is blocked
      const needsInputMatch = outputText.match(
        /STATUS:\s*(NEEDS_INPUT|BLOCKED)/i,
      );
      if (needsInputMatch) {
        const reasonMatch = outputText.match(/REASON:\s*([^\n`]+)/i);
        const reason = reasonMatch
          ? reasonMatch[1]!.trim()
          : "worker requested input or is blocked";

        // The phase itself is finished: its answer is the question. Only the
        // remaining phases pause, so a reply runs as a normal request and
        // nothing stays half-open for Cancel or Stop to get stuck on.
        const pauseMsg = `${phaseTitle} needs your input: ${reason}. Reply in the Thread, then resume the queue to continue with the next phase.`;
        await advanceThreadQueueSafely(env, threadId, {
          failedRequest: true,
          pauseMessage: pauseMsg,
        });
        return { paused: true, reason: pauseMsg };
      }

      // A phase must positively report completion; silence means we cannot tell.
      if (!isVerification && !/STATUS:\s*COMPLETED/i.test(outputText)) {
        const pauseMsg = `${phaseTitle} paused: worker did not report STATUS: COMPLETED. Review the output and resume the queue.`;
        await advanceThreadQueueSafely(env, threadId, {
          failedRequest: true,
          pauseMessage: pauseMsg,
        });
        return { paused: true, reason: pauseMsg };
      }

      // Check if verification step failed
      if (isVerification) {
        const reportedFailed = /STATUS:\s*FAILED/i.test(outputText);
        const reportedPassed = /STATUS:\s*PASSED/i.test(outputText);
        // A verifier that wrote its report but left out the status block is
        // asked once, by the same Worker, for the verdict on that report.
        if (
          !reportedFailed &&
          !reportedPassed &&
          !inputData?.isStatusFollowUp &&
          outputText.trim().length > 0
        ) {
          const queued = await enqueueVerificationStatusFollowUp(
            env,
            threadId,
            workRequestId,
            inputData ?? {},
            outputText,
          );
          if (queued) {
            await advanceThreadQueueSafely(env, threadId, {
              failedRequest: false,
            });
            return { paused: false };
          }
        }
        const failedMatch = reportedFailed
          ? [""]
          : reportedPassed
            ? null
            : [""];
        if (failedMatch) {
          const reasonMatch = outputText.match(/REASON:\s*([^\n`]+)/i);
          const reason = reasonMatch
            ? reasonMatch[1]!.trim()
            : /STATUS:\s*FAILED/i.test(outputText)
              ? "verification criteria were not satisfied"
              : "verifier did not report STATUS: PASSED";

          await queryOf(db).run`UPDATE work_requests SET status = 'failed', updated_at = ${new Date().toISOString()} WHERE id = ${workRequestId}`;

          const verifiedPhase = inputData?.isFinalVerification
            ? null
            : inputData?.phaseIndex;
          if (verifiedPhase && inputData?.planWorkRequestId) {
            await queryOf(db).run`UPDATE work_requests SET status = 'failed', updated_at = ${new Date().toISOString()}
                  WHERE thread_id = ${threadId}
                    AND (input_json::jsonb #>> '{planWorkRequestId}') = ${String(inputData.planWorkRequestId)}
                    AND (input_json::jsonb #>> '{phaseIndex}')::bigint = ${Number(verifiedPhase)}
                    AND COALESCE(input_json::jsonb #>> '{isVerification}', 'false') NOT IN ('true', '1')`;
          }

          const pauseMsg = `${phaseTitle} failed: ${reason}. Review findings in the Thread and resume or adjust the queue.`;
          await advanceThreadQueueSafely(env, threadId, {
            failedRequest: true,
            pauseMessage: pauseMsg,
          });
          return { paused: true, reason: pauseMsg };
        }
      }
    }

    // Normal completion: advance queue
    await advanceThreadQueueSafely(env, threadId, {
      failedRequest: false,
    });
    return { paused: false };
  } catch (err) {
    console.error("Failed to evaluate work completion for thread queue", err);
    await advanceThreadQueueSafely(env, threadId, {
      failedRequest: type === "work_request.failed",
    });
    return { paused: type === "work_request.failed" };
  }
}

const STATUS_FOLLOW_UP_REPORT_CHARS = 16_000;

/**
 * Queues, at the front of the Thread queue, a short request that asks the
 * verifying Worker for the missing `STATUS: PASSED|FAILED` block of its own
 * report. Returns false when the request cannot be built, so the caller falls
 * back to failing the verification.
 */
async function enqueueVerificationStatusFollowUp(
  env: SecurityEnv,
  threadId: string,
  workRequestId: string,
  inputData: Record<string, unknown>,
  report: string,
): Promise<boolean> {
  const db = env.SYNTILA_DB;
  if (!db) return false;
  const row = await queryOf(db).row<{ userId: string | null; snapshotJson: string | null }>`SELECT requested_by_user_id AS "userId", snapshot_json AS "snapshotJson"
         FROM work_requests WHERE id = ${workRequestId}`;
  if (!row?.userId) return false;
  let selection: Record<string, string> | undefined;
  try {
    const snapshot = row.snapshotJson ? JSON.parse(row.snapshotJson) : null;
    const config = snapshot?.turnExecutionConfig;
    if (config && typeof config.workerId === "string") {
      selection = { workerId: config.workerId };
      if (typeof config.modelId === "string") selection.model = config.modelId;
      if (typeof config.effort === "string")
        selection.reasoningEffort = config.effort;
    }
  } catch {
    // Without the original selection the Thread default Worker answers.
  }
  const phaseTitle = String(inputData.phaseTitle ?? "Verification");
  const boundedReport =
    report.length > STATUS_FOLLOW_UP_REPORT_CHARS
      ? `${report.slice(0, STATUS_FOLLOW_UP_REPORT_CHARS)}\n[Report truncated.]`
      : report;
  const prompt = [
    `${phaseTitle}: status block missing`,
    "",
    "Your verification report below did not end with the required status block, so Syntila cannot tell whether verification passed.",
    "Do not inspect the repository again and do not change anything. Decide only from the report.",
    "Reply with only the status block: STATUS: PASSED with a one-line SUMMARY, or STATUS: FAILED with a one-line REASON.",
    "",
    "Your report:",
    boundedReport,
  ].join("\n");
  const input = {
    originalRequest: prompt,
    isPhased: true,
    planWorkRequestId: inputData.planWorkRequestId,
    phaseIndex: inputData.phaseIndex,
    totalPhases: inputData.totalPhases,
    phaseTitle,
    isVerification: true,
    ...(inputData.isFinalVerification ? { isFinalVerification: true } : {}),
    isStatusFollowUp: true,
    statusFollowUpFor: workRequestId,
  };
  const request = {
    workflowId: "direct",
    ...(selection ? { executionSelection: selection } : {}),
    input,
    isPhased: true,
    planWorkRequestId: inputData.planWorkRequestId,
    phaseIndex: inputData.phaseIndex,
    totalPhases: inputData.totalPhases,
    phaseTitle,
    isVerification: true,
    ...(inputData.isFinalVerification ? { isFinalVerification: true } : {}),
  };
  await db.batch([
    lockQueue(db, threadId),
    prependToQueue(db, {
      id: `trq-verify-status-${crypto.randomUUID()}`,
      threadId,
      authorUserId: row.userId,
      requestJson: JSON.stringify(request),
      now: new Date().toISOString(),
    }),
  ]);
  return true;
}
