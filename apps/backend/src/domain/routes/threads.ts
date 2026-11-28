import {
  CreateThreadSchema,
  DiscussionMessageSchema,
  UpdateThreadSchema,
  canonicalExecutionErrorCode,
  executionErrorMessage,
} from "@syntila/protocol";
import { extractProviderFailure } from "../provider-failure-encryption.js";
import { readBody } from "./validation.js";
import { activeWorkCount, directSpaceOfGeneralThread, spaceKind, usersBlocked } from "../queries.js";
import {
  resolveReplyReference,
  storedReplyReference,
} from "./reply-references.js";
import {
  threadNotice,
  destructiveThreadGuard,
  requireDestructiveThreadAccess,
} from "./thread-history-actions.js";
import { normalizeDiscussionAttachments } from "./work-request-files.js";
import {
  loadSpacePermissions,
  requireSpaceRight,
} from "./space-permissions.js";
import { conditionalJson } from "./conditional-read.js";
import {
  activeWorkSql,
  lastThreadActivitySql,
  unreadSql,
} from "./thread-activity.js";
import { MutationIdempotency, NO_RECEIPT, type ReceiptWrite } from "./mutation-idempotency.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import { createEventPublisher } from "../event-publisher.js";
import {
  canExecuteThread,
  canManageThread,
  DEFAULT_THREAD_ACCESS_POLICY,
  type SpaceMembership,
  type Thread,
} from "@syntila/core";
import {
  HttpError,
  authorizeRequest,
  authorizeThreadAccess,
  discussionReferences,
  json,
  mergeMetadata,
  normalizeThreadMetadataPatch,
  normalizeThreadWorkConfig,
  parseJson,
  requiredString,
  sortThreads,
  threadMetadata,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { dataOf, type Tx, type Query } from "../../platform/data.js";
import { isFeatureEnabled } from "../../feature-flags.js";

const selectSpaceMembershipsBySpaceIdUserId = <T = Record<string, unknown>>(q: Query, p1: unknown, p2: unknown) =>
  q.row<T>`SELECT id, space_id AS "spaceId", user_id AS "userId", role,
            created_at AS "createdAt", updated_at AS "updatedAt"
       FROM space_memberships WHERE space_id = ${p1} AND user_id = ${p2}`;

const selectSupportSpacesBySpaceIdJo = (q: Query, spaceId: string) =>
  q.row<{ status: string | null; userLowId: string; userHighId: string; isSupport: boolean }>`SELECT pc.status, ds.user_low_id AS "userLowId", ds.user_high_id AS "userHighId",
            EXISTS (SELECT 1 FROM support_spaces ss WHERE ss.space_id = ds.space_id) AS "isSupport"
     FROM direct_spaces ds
     LEFT JOIN person_connections pc ON pc.user_low_id = ds.user_low_id AND pc.user_high_id = ds.user_high_id
     WHERE ds.space_id = ${spaceId}`;

const selectDiscussionMessagesById = <T = Record<string, unknown>>(q: Query, p1: unknown) =>
  q.row<T>`SELECT dm.id, dm.thread_id AS "threadId", dm.author_user_id AS "authorUserId",
      COALESCE(u.display_name, 'Member') AS "authorName",
      dm.body, dm.attachments_json AS "attachmentsJson", dm.references_json AS "referencesJson", dm.reply_to_json AS "replyToJson", dm.edited_at AS "editedAt", dm.created_at AS "createdAt",
            dm.event_type AS "eventType", dm.kind, dm.work_request_id AS "workRequestId", dm.worker_display_name AS "workerDisplayName"
     FROM discussion_messages dm
     LEFT JOIN users u ON u.id = dm.author_user_id
     WHERE dm.id = ${p1}`;

export async function handleListSpaceThreads(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    spaceId,
    accessContext,
  );
  const read = dataOf(env).read;
  const rows = await read.rows<Record<string, unknown>>`WITH me AS (SELECT ${context.userId}::text AS id)
    SELECT threads.id, threads.space_id AS "spaceId",
            threads.name, threads.status, threads.has_other_contributions AS "hasOtherContributions",
            threads.is_general AS "isGeneral",
            threads.access_policy_json AS "accessPolicyJson",
            usage.config_json AS "workConfigJson",
            threads.metadata_json::text AS "metadataJson",
            threads.lead_user_id AS "leadUserId",
            lead.display_name AS "leadDisplayName",
            creator.email AS "creatorEmail",
            CASE WHEN threads.lead_user_id = space.owner_user_id THEN 1 ELSE 0 END AS "creatorIsOwner",
            threads.created_at AS "createdAt", ${read.raw(lastThreadActivitySql("threads"))} AS "updatedAt",
            COALESCE((SELECT text FROM (SELECT m.body AS text,
                       CASE WHEN m.kind = 'ai_answer' THEN COALESCE(m.worker_display_name, 'AI')
                            ELSE COALESCE(u.display_name, 'Member') END AS author,
                       m.created_at AS "sentAt", 0 AS source
                  FROM discussion_messages m LEFT JOIN users u ON u.id = m.author_user_id
                 WHERE m.thread_id = threads.id AND m.body IS NOT NULL
                UNION ALL
                SELECT h.text,
                       CASE WHEN h.actor_type = 'worker'
                            THEN COALESCE((h.metadata_json::jsonb #>> '{workerDisplayName}'), 'AI')
                            ELSE COALESCE(u.display_name, 'Member') END,
                       h.occurred_at, 1
                  FROM conversation_history_entries h
                  JOIN conversations c ON c.id = h.conversation_id
                  LEFT JOIN users u ON h.actor_type = 'user' AND u.id = h.actor_id
                 WHERE c.thread_id = threads.id AND h.text IS NOT NULL
                   AND h.kind IN ('user_message', 'worker_response')) ORDER BY "sentAt" DESC, source DESC, text DESC, author DESC LIMIT 1), '') AS "brief",
            (SELECT author FROM (SELECT m.body AS text,
                       CASE WHEN m.kind = 'ai_answer' THEN COALESCE(m.worker_display_name, 'AI')
                            ELSE COALESCE(u.display_name, 'Member') END AS author,
                       m.created_at AS "sentAt", 0 AS source
                  FROM discussion_messages m LEFT JOIN users u ON u.id = m.author_user_id
                 WHERE m.thread_id = threads.id AND m.body IS NOT NULL
                UNION ALL
                SELECT h.text,
                       CASE WHEN h.actor_type = 'worker'
                            THEN COALESCE((h.metadata_json::jsonb #>> '{workerDisplayName}'), 'AI')
                            ELSE COALESCE(u.display_name, 'Member') END,
                       h.occurred_at, 1
                  FROM conversation_history_entries h
                  JOIN conversations c ON c.id = h.conversation_id
                  LEFT JOIN users u ON h.actor_type = 'user' AND u.id = h.actor_id
                 WHERE c.thread_id = threads.id AND h.text IS NOT NULL
                   AND h.kind IN ('user_message', 'worker_response')) ORDER BY "sentAt" DESC, source DESC, text DESC, author DESC LIMIT 1) AS "briefAuthorName",
            ${read.raw(activeWorkSql("threads"))} AS "hasActiveWork",
            ${read.raw(unreadSql("threads", "(SELECT id FROM me)", "COALESCE(read_state.read_at, member.created_at)"))} AS "hasUnread",
            (SELECT up.pinned_at FROM user_pins up
              WHERE up.user_id = (SELECT id FROM me) AND up.kind = 'thread'
                AND up.target_id = threads.id) AS "pinnedAt",
            (SELECT up.position FROM user_pins up
              WHERE up.user_id = (SELECT id FROM me) AND up.kind = 'thread'
                AND up.target_id = threads.id) AS "pinPosition"
     FROM threads
     JOIN spaces space ON space.id = threads.space_id
     LEFT JOIN users lead ON lead.id = threads.lead_user_id
     LEFT JOIN users creator ON creator.id = threads.lead_user_id
     LEFT JOIN thread_work_configs usage ON usage.thread_id = threads.id
     LEFT JOIN thread_read_states read_state
       ON read_state.thread_id = threads.id AND read_state.user_id = (SELECT id FROM me)
     LEFT JOIN space_memberships member
       ON member.space_id = threads.space_id AND member.user_id = (SELECT id FROM me)
     WHERE threads.space_id = ${spaceId} ORDER BY "updatedAt" DESC, threads.id DESC`;

  const membership = await selectSpaceMembershipsBySpaceIdUserId<SpaceMembership>(dataOf(env).read, spaceId, context.userId);
  const policy = await loadSpacePermissions(env, context.userId, spaceId);
  const effectiveMembership = membership
    ? { ...membership, permissions: policy.rights }
    : null;
  const raw = rows.map((row) => {
    const leadUserId = String(row.leadUserId ?? "");
    const createdAt = String(row.createdAt ?? "");
    const thread: Thread = {
      id: String(row.id),
      spaceId: String(row.spaceId),
      name: String(row.name),
      status: String(row.status) as Thread["status"],
      accessPolicy: {
        ...DEFAULT_THREAD_ACCESS_POLICY,
        ...parseJson(row.accessPolicyJson, {}),
      },
      lead: {
        userId: leadUserId,
        assignedAt: createdAt,
        assignedByUserId: leadUserId,
      },
      createdAt,
      updatedAt: String(row.updatedAt ?? ""),
    };
    return {
      ...threadMetadata(row, context.userId),
      canDestroy:
        policy.role === "owner" ||
        (leadUserId === context.userId && Number(row.hasOtherContributions) === 0),
      canConfigureWork: canManageThread(
        context.userId,
        effectiveMembership,
        thread,
      ),
      canExecuteWork: canExecuteThread(
        context.userId,
        effectiveMembership,
        thread,
      ),
    };
  });
  const threads = sortThreads(raw);
  return conditionalJson(request, { threads });
}

export async function handleCreateThread(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:write",
    spaceId,
    accessContext,
  );
  const creatorPolicy = await requireSpaceRight(
    env,
    context,
    spaceId,
    "manageOwnThreads",
  );
  const directSpace = await selectSupportSpacesBySpaceIdJo(dataOf(env).read, spaceId).catch(() => null);
  if (directSpace) {
    const isBlocked = await usersBlocked(dataOf(env).read, directSpace.userLowId, directSpace.userHighId);
    if (isBlocked) {
      throw new HttpError(403, "Messaging is blocked between participants");
    }
    if (directSpace.status !== "connected" && !directSpace.isSupport) {
      throw new HttpError(
        403,
        "This personal conversation is disconnected and read-only",
      );
    }
  }
  const body = await readBody(request, CreateThreadSchema);
  const receipt = await MutationIdempotency.from(
    request,
    env.SYNTILA_DB,
    context.userId,
    `space:${spaceId}:create-thread`,
    body,
  );
  const replay = await receipt?.replay();
  if (replay) return replay;
  const name = requiredString(body.name, "name");
  const duplicate = await dataOf(env).read.row<{ id: string }>`SELECT id FROM threads
     WHERE space_id = ${spaceId} AND LOWER(TRIM(name)) = LOWER(TRIM(${name}))
     LIMIT 1`;
  if (duplicate) {
    const concurrentReplay = await receipt?.replay();
    if (concurrentReplay) return concurrentReplay;
    throw new HttpError(409, "This Space already has a Thread with this name");
  }
  const id = `thread-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  const accessPolicy =
    typeof body.accessPolicy === "object" && body.accessPolicy !== null
      ? body.accessPolicy
      : DEFAULT_THREAD_ACCESS_POLICY;
  const insertThread = (tx: Tx) => tx.run`INSERT INTO threads
       (id, space_id, name, status, access_policy_json, lead_user_id, created_at, updated_at)
       VALUES (${id}, ${spaceId}, ${name}, 'active', ${JSON.stringify(accessPolicy)}, ${context.userId}, ${now}, ${now})`;
  const response = {
    thread: {
      canConfigureWork: true,
      canDestroy: true,
      canExecuteWork: true,
      ...threadMetadata(
        {
          id,
          spaceId,
          name,
          status: "active",
          accessPolicyJson: JSON.stringify(accessPolicy),
          leadUserId: context.userId,
          creatorEmail: context.user.email,
          creatorIsOwner: creatorPolicy.role === "owner" ? 1 : 0,
          createdAt: now,
          updatedAt: now,
        },
        context.userId,
      ),
    },
  };
  const write = (receiptWrite: ReceiptWrite) =>
    publishCollaborationEvent(env, "thread.created", spaceId, id, {
      threadId: id,
      mutate: async (tx) => {
        await receiptWrite(tx);
        await insertThread(tx);
      },
    });
  const concurrentReplay = receipt
    ? await receipt.commit(response, 201, write)
    : (await write(NO_RECEIPT), null);
  return concurrentReplay ?? json(response, { status: 201 });
}

export async function handleUpdateThread(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const body = await readBody(request, UpdateThreadSchema);
  const statusOnly =
    Object.keys(body).length === 1 &&
    ["archived", "active"].includes(String(body.status));
  // A view-state patch only writes the caller's own selection (stored per
  // user), so viewing the Thread is enough; managing it is not required.
  const viewStateOnly =
    Object.keys(body).length === 1 && body.metadata !== undefined;
  const { context, thread } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    statusOnly || viewStateOnly ? "view" : "manage",
    accessContext,
  );
  if (
    statusOnly &&
    body.status === "active" &&
    !["archived", "active"].includes(thread.status)
  )
    await authorizeThreadAccess(
      request,
      env,
      threadId,
      "manage",
      accessContext,
    );

  const isDirectGeneral = await directSpaceOfGeneralThread(dataOf(env).read, threadId);
  if (isDirectGeneral) {
    if (body.name !== undefined && body.name !== thread.name) {
      throw new HttpError(
        400,
        "The default General Thread of a Direct Space cannot be renamed",
      );
    }
    if (body.status === "archived") {
      throw new HttpError(
        400,
        "The default General Thread of a Direct Space cannot be archived",
      );
    }
  }

  const space = await spaceKind(dataOf(env).read, thread.spaceId);
  if (space?.kind === "direct" && !isDirectGeneral && !viewStateOnly) {
    if (thread.lead.userId !== context.userId) {
      throw new HttpError(
        403,
        "In a Direct Space, you can only manage Threads you created",
      );
    }
  }
  const name =
    body.name === undefined ? thread.name : requiredString(body.name, "name");
  const status =
    body.status === undefined ? thread.status : String(body.status);
  if (
    !["active", "paused", "blocked", "completed", "archived"].includes(status)
  ) {
    throw new HttpError(400, "Unsupported Thread status");
  }
  const accessPolicy =
    body.accessPolicy === undefined ? thread.accessPolicy : body.accessPolicy;
  if (typeof accessPolicy !== "object" || accessPolicy === null) {
    throw new HttpError(400, "accessPolicy must be an object");
  }
  const rawWorkConfig = body.workConfig;
  let workConfig: Record<string, unknown> | undefined;
  if (rawWorkConfig !== undefined)
    workConfig = normalizeThreadWorkConfig(rawWorkConfig).config;
  const metadataPatch =
    body.metadata === undefined
      ? undefined
      : normalizeThreadMetadataPatch(body.metadata, context.userId);
  // A metadata-only write is presentation state, not Thread activity: it must
  // not reorder the sidebar by bumping updated_at.
  const metadataOnly =
    metadataPatch !== undefined &&
    Object.keys(body).every((key) => key === "metadata");
  if (name.trim().toLowerCase() !== thread.name.trim().toLowerCase()) {
    const duplicate = await dataOf(env).read.row<{ id: string }>`SELECT id FROM threads
       WHERE space_id = ${thread.spaceId} AND id <> ${threadId}
         AND LOWER(TRIM(name)) = LOWER(TRIM(${name}))
       LIMIT 1`;
    if (duplicate) {
      throw new HttpError(
        409,
        "This Space already has a Thread with this name",
      );
    }
  }
  const now = new Date().toISOString();
  const updatedAt = metadataOnly ? thread.updatedAt : now;
  const archiveChanged =
    status !== thread.status &&
    (status === "archived" || thread.status === "archived");
  const mutate = async (tx: Tx) => {
    await tx.run`UPDATE threads
     SET name = ${name}, status = ${status}, access_policy_json = ${JSON.stringify(accessPolicy)}, updated_at = ${updatedAt},
         metadata_json = syntila_json_patch(metadata_json, ${JSON.stringify(metadataPatch ?? {})})
     WHERE id = ${threadId}`;
    if (archiveChanged)
      await threadNotice(
        tx,
        threadId,
        context.userId,
        context.user.displayName || "Member",
        status === "archived" ? "thread.archived" : "thread.restored",
        status === "archived"
          ? "archived this thread."
          : "restored this thread.",
        now,
      );
    if (workConfig !== undefined)
      await tx.run`INSERT INTO thread_work_configs
         (thread_id, config_json, updated_by_user_id, updated_at)
       VALUES (${threadId}, ${JSON.stringify(workConfig)}, ${context.userId}, ${now})
       ON CONFLICT(thread_id) DO UPDATE SET config_json = excluded.config_json,
         updated_by_user_id = excluded.updated_by_user_id, updated_at = excluded.updated_at`;
  };
  const savedWorkConfigJson =
    workConfig === undefined
      ? await dataOf(env).read
          .row<{ configJson: string }>`SELECT config_json AS "configJson" FROM thread_work_configs WHERE thread_id = ${threadId}`
          .then((row) => row?.configJson)
      : JSON.stringify(workConfig);
  const savedMetadataJson = await dataOf(env).read
    .row<{ metadataJson: string }>`SELECT metadata_json::text AS "metadataJson" FROM threads WHERE id = ${threadId}`
    .then((row) => {
      const current = parseJson<Record<string, unknown>>(
        row?.metadataJson,
        {},
      );
      return JSON.stringify(mergeMetadata(current, metadataPatch ?? {}));
    });
  const member = await selectSpaceMembershipsBySpaceIdUserId<SpaceMembership>(dataOf(env).read, thread.spaceId, context.userId);
  const policy = await loadSpacePermissions(
    env,
    context.userId,
    thread.spaceId,
  );
  const creator = await dataOf(env).read.row<{ email: string; ownerUserId: string }>`SELECT u.email, s.owner_user_id AS "ownerUserId" FROM users u JOIN spaces s ON s.id = ${thread.spaceId} WHERE u.id = ${thread.lead.userId}`;
  const updatedThread: Thread = {
    ...thread,
    name,
    status: status as Thread["status"],
    accessPolicy: accessPolicy as Thread["accessPolicy"],
    updatedAt,
  };
  await publishCollaborationEvent(
    env,
    "thread.updated",
    thread.spaceId,
    threadId,
    { threadId, mutate },
  );
  return json({
    thread: {
      ...threadMetadata(
        {
          id: thread.id,
          spaceId: thread.spaceId,
          name,
          status,
          accessPolicyJson: JSON.stringify(accessPolicy),
          workConfigJson: savedWorkConfigJson,
          metadataJson: savedMetadataJson,
          leadUserId: thread.lead.userId,
          creatorEmail: creator?.email,
          creatorIsOwner: creator?.ownerUserId === thread.lead.userId ? 1 : 0,
          createdAt: thread.createdAt,
          updatedAt,
        },
        context.userId,
      ),
      canDestroy:
        policy.role === "owner" ||
        (thread.lead.userId === context.userId &&
          Number(
            (
              await dataOf(env).read.row<{ contributed: number }>`SELECT has_other_contributions AS contributed FROM threads WHERE id = ${threadId}`
            )?.contributed,
          ) === 0),
      canConfigureWork: canManageThread(
        context.userId,
        member ? { ...member, permissions: policy.rights } : null,
        updatedThread,
      ),
      canExecuteWork: canExecuteThread(
        context.userId,
        member ? { ...member, permissions: policy.rights } : null,
        updatedThread,
      ),
    },
    updatedByUserId: context.userId,
  });
}

export async function handleDeleteThread(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "view",
    accessContext,
  );
  await requireDestructiveThreadAccess(env, threadId, context.userId);
  const isDirectGeneral = await directSpaceOfGeneralThread(dataOf(env).read, threadId);
  if (isDirectGeneral) {
    throw new HttpError(
      403,
      "The default General Thread of a Direct Space cannot be deleted",
    );
  }
  const active = await activeWorkCount(dataOf(env).read, threadId);
  if (active && active.count > 0)
    throw new HttpError(
      409,
      "Cancel active requests before deleting this Thread",
    );
  // Everything that belongs to the Thread (Work Requests, tasks, Worker
  // assignments, Runs, conversations, messages) is removed by cascade.
  await publishCollaborationEvent(env, "thread.deleted", spaceId, threadId, {
    threadId,
    mutate: async (tx) => {
      await destructiveThreadGuard(tx, threadId, context.userId);
      await tx.run`DELETE FROM threads WHERE id = ${threadId}`;
    },
  });
  return json({ ok: true, threadId });
}

function discussionMessageView(row: Record<string, unknown>) {
  const { attachmentsJson, replyToJson, ...message } = row;
  return {
    ...message,
    attachments: parseJson(attachmentsJson, []),
    replyTo: storedReplyReference(replyToJson),
  };
}

/** Add authorized, decrypted failure details without writing them to the timeline. */
async function workerFailuresForMessages(env: SecurityEnv, threadId: string, messages: readonly Record<string, unknown>[]) {
  const ids = [...new Set(messages
    .filter((row) => row.eventType === "work_failed" && typeof row.workRequestId === "string")
    .map((row) => String(row.workRequestId)))];
  const result = new Map<string, Record<string, unknown>>();
  if (!ids.length) return result;
  const q = dataOf(env).read;
  const rows = await q.rows<Record<string, unknown>>`SELECT DISTINCT ON (wt.work_request_id)
      wt.work_request_id AS "workRequestId", a.id AS "assignmentId", a.worker_instance_id AS "workerId",
      w.name AS "workerName", w.worker_type_id AS "workerTypeId", a.error_json::text AS "errorJson"
    FROM workflow_tasks wt JOIN work_requests wr ON wr.id = wt.work_request_id
    JOIN worker_assignments a ON a.task_id = wt.id
    JOIN worker_instances w ON w.id = a.worker_instance_id
    WHERE wr.thread_id = ${threadId} AND wt.work_request_id IN ${q.list(ids)}
      AND a.status IN ('failed','timed_out','lost')
    ORDER BY wt.work_request_id, a.updated_at DESC, a.id DESC`;
  for (const row of rows) {
    const error = parseJson<Record<string, unknown>>(row.errorJson, {});
    const raw = error.error && typeof error.error === "object" ? error.error as Record<string, unknown> : {};
    const errorCode = canonicalExecutionErrorCode(raw.code);
    result.set(String(row.workRequestId), {
      kind: "worker_failure", workerId: row.workerId, workerName: row.workerName,
      workerTypeId: row.workerTypeId, errorCode, errorMessage: executionErrorMessage(errorCode),
      ...extractProviderFailure(error, row.assignmentId, env),
    });
  }
  return result;
}

/** One paginated timeline: people and AI items, attributed to their Actor. */
export async function handleListThreadTimeline(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  return handleListDiscussionMessages(request, env, threadId, accessContext, true);
}

export async function handleListDiscussionMessages(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
  timeline = false,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  if (timeline) {
    // Historical Work gets its items on first read; replay-safe.
    await dataOf(env).tx("thread.timeline.backfill", async (tx) => {
      await tx.row`SELECT backfill_ai_timeline(${threadId})`;
    });
  }
  const url = new URL(request.url);
  const rawLimit = url.searchParams.get("limit") ?? "50";
  if (
    !/^\d+$/.test(rawLimit) ||
    Number(rawLimit) < 1 ||
    Number(rawLimit) > 100
  ) {
    throw new HttpError(400, "Discussion limit must be between 1 and 100");
  }
  const limit = Number(rawLimit);
  // `cursor` pages back in time like every list; `after` reads newer messages.
  const before = url.searchParams.get("cursor");
  const after = url.searchParams.get("after");
  if (before !== null && after !== null) {
    throw new HttpError(400, "Choose cursor or after, not both");
  }
  const rawCursor = before ?? after;
  let cursor: { createdAt: string; id: string } | null = null;
  if (rawCursor !== null) {
    try {
      if (rawCursor.length > 2048) throw new HttpError(400, "Oversized cursor");
      const value = JSON.parse(decodeURIComponent(atob(rawCursor))) as Record<
        string,
        unknown
      >;
      if (
        value.version !== 1 ||
        value.threadId !== threadId ||
        typeof value.createdAt !== "string" ||
        !value.createdAt ||
        typeof value.id !== "string" ||
        !value.id
      )
        throw new HttpError(400, "Invalid cursor");
      cursor = { createdAt: value.createdAt, id: value.id };
    } catch {
      throw new HttpError(400, "Invalid Discussion cursor");
    }
  }
  const forward = after !== null;
  const order = forward ? "ASC" : "DESC";
  const read = dataOf(env).read;
  const results = await read.rows<Record<string, unknown>>`SELECT dm.id, dm.thread_id AS "threadId", dm.author_user_id AS "authorUserId",
            CASE WHEN dm.worker_instance_id IS NOT NULL THEN COALESCE(wi.name, dm.author_display_snapshot)
                 WHEN dm.kind = 'ai_answer' THEN COALESCE(dm.author_display_snapshot, dm.worker_display_name, 'AI')
                 ELSE COALESCE(u.display_name, dm.author_display_snapshot, 'Member') END AS "authorName",
            dm.author_actor_id AS "authorActorId", dm.worker_instance_id AS "workerInstanceId",
            dm.body, dm.attachments_json AS "attachmentsJson", dm.references_json AS "referencesJson", dm.reply_to_json AS "replyToJson", dm.edited_at AS "editedAt", dm.created_at AS "createdAt",
            dm.event_type AS "eventType", dm.kind, dm.work_request_id AS "workRequestId", dm.worker_display_name AS "workerDisplayName"
     FROM discussion_messages dm
     LEFT JOIN users u ON u.id = dm.author_user_id
     LEFT JOIN worker_instances wi ON wi.id = dm.worker_instance_id
     WHERE dm.thread_id = ${threadId}
       AND (${cursor?.createdAt ?? null}::timestamptz IS NULL
            OR (${forward} AND (dm.created_at > ${cursor?.createdAt ?? null}::timestamptz OR (dm.created_at = ${cursor?.createdAt ?? null}::timestamptz AND dm.id > ${cursor?.id ?? null})))
            OR (NOT ${forward} AND (dm.created_at < ${cursor?.createdAt ?? null}::timestamptz OR (dm.created_at = ${cursor?.createdAt ?? null}::timestamptz AND dm.id < ${cursor?.id ?? null}))))
     ORDER BY dm.created_at ${read.raw(order)}, dm.id ${read.raw(order)} LIMIT ${limit + 1}`;
  const more = results.length > limit;
  const selected = results.slice(0, limit);
  const encode = (row: Record<string, unknown>) =>
    btoa(
      encodeURIComponent(
        JSON.stringify({
          version: 1,
          threadId,
          createdAt: row.createdAt,
          id: row.id,
        }),
      ),
    );
  const nextCursor =
    more && selected.length ? encode(selected[selected.length - 1]!) : null;
  const messages = forward ? selected : selected.reverse();
  const failures = await workerFailuresForMessages(env, threadId, messages);
  return json({
    schemaVersion: 1,
    messages: messages.map((row) => ({
      ...discussionMessageView(row),
      ...(failures.has(String(row.workRequestId)) && row.eventType === "work_failed"
        ? { workerFailure: failures.get(String(row.workRequestId)) } : {}),
      references: parseJson(row.referencesJson, []),
    })),
    nextCursor,
    newestCursor: messages.length
      ? encode(messages[messages.length - 1]!)
      : rawCursor,
  });
}

export async function handleCreateDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId, thread } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "discuss",
    accessContext,
  );
  const directSpace = await selectSupportSpacesBySpaceIdJo(dataOf(env).read, spaceId).catch(() => null);
  if (directSpace) {
    const isBlocked = await usersBlocked(dataOf(env).read, directSpace.userLowId, directSpace.userHighId);
    if (isBlocked) {
      throw new HttpError(403, "Messaging is blocked between participants");
    }
    if (directSpace.status !== "connected" && !directSpace.isSupport) {
      throw new HttpError(
        403,
        "This personal conversation is disconnected and read-only",
      );
    }
  }
  if (thread?.status === "archived")
    throw new HttpError(
      409,
      "Restore the Thread before sending messages or requests",
    );
  const body = await readBody(request, DiscussionMessageSchema);
  const receipt = await MutationIdempotency.from(
    request,
    env.SYNTILA_DB,
    context.userId,
    `thread:${threadId}:send-discussion`,
    body,
  );
  const replay = await receipt?.replay();
  if (replay) return replay;
  const attachments = await normalizeDiscussionAttachments(
    env,
    body.attachments,
    threadId,
    context.userId,
  );
  const rawContent = body.body ?? body.content;
  const content =
    attachments.length && typeof rawContent === "string" && !rawContent.trim()
      ? ""
      : requiredString(rawContent, "body");
  const references = discussionReferences(body.references);
  const replyTo = await resolveReplyReference(
    env.SYNTILA_DB,
    threadId,
    body.replyTo,
  );
  const now = new Date().toISOString();
  const id = `discussion-${crypto.randomUUID()}`;
  const userRow = await dataOf(env).read.row<{ displayName: string | null }>`SELECT display_name AS "displayName" FROM users WHERE id = ${context.userId}`;
  const authorName = userRow?.displayName || "Member";
  const insertMessage = async (tx: Tx) => {
    await tx.run`INSERT INTO discussion_messages
       (id, thread_id, author_user_id, body, references_json, created_at, attachments_json, reply_to_json)
     VALUES (${id}, ${threadId}, ${context.userId}, ${content}, ${JSON.stringify(references)}, ${now}, ${JSON.stringify(attachments)}, ${replyTo ? JSON.stringify(replyTo) : null})`;
    await tx.run`INSERT INTO space_audit_log
       (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (${`pa-${crypto.randomUUID()}`}, ${spaceId}, 'user', ${context.userId}, 'thread.discussion.created', 'discussion_message', ${id}, ${JSON.stringify({ threadId, references })}::text::jsonb, ${now})`;
    // A support Space's sidebar visibility is the user's own setting; replies never change it.
    if (directSpace && !directSpace.isSupport)
      await tx.run`UPDATE direct_space_user_state SET hidden = FALSE, last_opened_at = ${now}, updated_at = ${now} WHERE space_id = ${spaceId}`;
  };
  const response = {
    message: {
      id,
      threadId,
      authorUserId: context.userId,
      authorName,
      body: content,
      attachments,
      references,
      replyTo,
      editedAt: null,
      createdAt: now,
      kind: "message",
      workRequestId: null,
      workerDisplayName: null,
    },
  };
  const write = (receiptWrite: ReceiptWrite) =>
    publishCollaborationEvent(env, "discussion.created", spaceId, id, {
      threadId,
      mutate: async (tx) => {
        await receiptWrite(tx);
        await insertMessage(tx);
      },
    });
  const concurrentReplay = receipt
    ? await receipt.commit(response, 201, write)
    : (await write(NO_RECEIPT), null);
  return concurrentReplay ?? json(response, { status: 201 });
}

export async function handleGetDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  messageId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const message = await selectDiscussionMessagesById<Record<string, unknown>>(dataOf(env).read, messageId);
  if (!message) throw new HttpError(404, "Discussion message not found");
  await authorizeThreadAccess(
    request,
    env,
    String(message.threadId),
    "view",
    accessContext,
  );
  const failures = await workerFailuresForMessages(env, String(message.threadId), [message]);
  return json({
    message: {
      ...discussionMessageView(message),
      ...(failures.has(String(message.workRequestId)) && message.eventType === "work_failed"
        ? { workerFailure: failures.get(String(message.workRequestId)) } : {}),
      references: parseJson(message.referencesJson, []),
    },
  });
}

export async function handleEditDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  messageId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const message = await selectDiscussionMessagesById<Record<string, unknown>>(dataOf(env).read, messageId);
  if (!message) throw new HttpError(404, "Discussion message not found");
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    String(message.threadId),
    "discuss",
    accessContext,
  );
  if (String(message.authorUserId) !== context.userId)
    throw new HttpError(403, "Only the message author may edit it");
  if (message.eventType || (message.kind ?? "message") !== "message")
    throw new HttpError(409, "Archived AI entries cannot be edited");
  const body = await readBody(request, DiscussionMessageSchema);
  const rawContent = body.body ?? body.content;
  const attachments = parseJson<unknown[]>(message.attachmentsJson, []);
  const content =
    attachments.length && typeof rawContent === "string" && !rawContent.trim()
      ? ""
      : requiredString(rawContent, "body");
  const references = discussionReferences(
    body.references ?? parseJson(message.referencesJson, []),
  );
  const editedAt = new Date().toISOString();
  await publishCollaborationEvent(
    env,
    "discussion.updated",
    spaceId,
    messageId,
    {
      threadId: String(message.threadId),
      mutate: (tx) => tx.run`UPDATE discussion_messages SET body = ${content}, references_json = ${JSON.stringify(references)}, edited_at = ${editedAt} WHERE id = ${messageId}`,
    },
  );
  return json({
    message: {
      ...discussionMessageView(message),
      body: content,
      references,
      editedAt,
    },
  });
}

export async function handleDeleteDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  messageId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const message = await dataOf(env).read.row<Record<string, unknown>>`SELECT id, thread_id AS "threadId", author_user_id AS "authorUserId", event_type AS "eventType", kind
     FROM discussion_messages
     WHERE id = ${messageId}`;
  if (!message) throw new HttpError(404, "Discussion message not found");
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    String(message.threadId),
    "view",
    accessContext,
  );
  const policy = await loadSpacePermissions(env, context.userId, spaceId);
  const space = await spaceKind(dataOf(env).read, spaceId);

  if (space?.kind === "direct") {
    if (String(message.authorUserId) !== context.userId) {
      throw new HttpError(
        403,
        "In a Direct Space, only the message author may delete their message",
      );
    }
  } else if (
    String(message.authorUserId) !== context.userId &&
    policy.role !== "owner"
  )
    throw new HttpError(
      403,
      "Only the message author or Space owner may delete it",
    );
  if (message.eventType || (message.kind ?? "message") !== "message")
    throw new HttpError(
      409,
      "System notices and archived AI entries cannot be deleted",
    );
  const now = new Date().toISOString();
  const text = `Message removed by ${context.user.displayName || "Member"}${policy.role === "owner" && String(message.authorUserId) !== context.userId ? " · Space owner" : ""}`;
  await publishCollaborationEvent(
    env,
    "discussion.updated",
    spaceId,
    messageId,
    {
      threadId: String(message.threadId),
      mutate: (tx) => tx.run`UPDATE discussion_messages SET body = ${text}, attachments_json = '[]', references_json = '[]', reply_to_json = NULL, event_type = 'message.removed', edited_at = ${now} WHERE id = ${messageId} AND event_type IS NULL`,
    },
  );
  return json({ success: true });
}

/** Remove the Thread's Discussion Chat for everyone. Work history is separate. */
export async function handleClearChatHistory(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "view",
    accessContext,
  );
  await requireDestructiveThreadAccess(env, threadId, context.userId);
  const active = await activeWorkCount(dataOf(env).read, threadId);
  if (active && active.count > 0) {
    throw new HttpError(
      409,
      `Cannot clear the Conversation with ${active.count} active Work Request(s). Cancel first.`,
    );
  }
  // Clearing the Conversation is the real deletion: Chat messages, every Work
  // Request with its answers and diagnostics, and Worker session continuity.
  // Deleting the owning Conversations lets canonical history cascade legally.
  const now = new Date().toISOString();
  // The writes and the event are committed together by the publisher, so a
  // successful clear is always announced to other sessions. Deleting the Work
  // Requests removes their tasks, Worker assignments and Runs by cascade.
  await publishCollaborationEvent(
    env,
    "thread.chat_cleared",
    spaceId,
    threadId,
    {
      threadId,
      mutate: async (tx) => {
        await destructiveThreadGuard(tx, threadId, context.userId);
        await tx.run`DELETE FROM discussion_messages WHERE thread_id = ${threadId}`;
        await tx.run`DELETE FROM conversations WHERE thread_id = ${threadId}`;
        await tx.run`DELETE FROM work_requests WHERE thread_id = ${threadId}`;
        await tx.run`UPDATE threads SET ai_history_cleared_at = NULL,
           work_session_generation = work_session_generation + 1, updated_at = ${now}
         WHERE id = ${threadId}`;
        await threadNotice(
          tx,
          threadId,
          context.userId,
          context.user.displayName || "Member",
          "conversation.cleared",
          "cleared the conversation.",
          now,
        );
      },
    },
  );
  return json({ threadId, cleared: true });
}

/** Record that the caller has seen the Thread. Other sessions of the same
 * user are told through a recipient-scoped event so their indicators clear. */
export async function handleMarkThreadRead(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "view",
    accessContext,
  );
  const readAt = new Date().toISOString();
  await publishCollaborationEvent(env, "thread.updated", spaceId, threadId, {
    threadId,
    recipientUserIds: [context.userId],
    mutate: (tx) => tx.run`INSERT INTO thread_read_states (thread_id, user_id, read_at)
     VALUES (${threadId}, ${context.userId}, ${readAt}::timestamptz)
     ON CONFLICT (thread_id, user_id) DO UPDATE SET read_at = excluded.read_at
     WHERE excluded.read_at > thread_read_states.read_at`,
  });
  // Read receipts: other members viewing the Thread refetch who has seen it.
  // Live-only; a reconnecting client simply reloads the read states.
  try {
    await createEventPublisher(env).publish({
      type: "thread.read",
      spaceId,
      threadId,
      stream: { kind: "space", id: spaceId },
      payload: { entityId: threadId, threadId },
      durable: false,
    });
  } catch (error) {
    console.warn("thread.read.signal_failed", {
      message: error instanceof Error ? error.message : String(error),
    });
  }
  return json({ threadId, readAt });
}

/** When each other Space member last read the Thread (read receipts). Only
 * members of the Space are listed; they can already see each other. */
export async function handleListThreadReadStates(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "view",
    accessContext,
  );
  // Reciprocal privacy: only people who share receipts are listed, and only
  // to a viewer who shares theirs.
  const rows = await dataOf(env).read.rows`SELECT r.user_id AS "userId", u.display_name AS "displayName", r.read_at AS "readAt"
       FROM thread_read_states r
       JOIN space_memberships m ON m.space_id = ${spaceId} AND m.user_id = r.user_id
       JOIN users u ON u.id = r.user_id AND u.share_read_receipts
      WHERE r.thread_id = ${threadId} AND r.user_id != ${context.userId}
        AND EXISTS (SELECT 1 FROM users me WHERE me.id = ${context.userId} AND me.share_read_receipts)
      ORDER BY r.read_at DESC`;
  return json({ readStates: rows });
}
