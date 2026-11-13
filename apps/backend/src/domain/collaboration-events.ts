import {
  createEventPublisher,
  type EventPublisherEnv,
} from "./event-publisher.js";

import { COLLABORATION_REALTIME_EVENT_TYPES } from "@syntila/protocol";
export type CollaborationEventType =
  (typeof COLLABORATION_REALTIME_EVENT_TYPES)[number];

/** Authenticated routes supply IDs only; collaboration has no execution owner. */
export async function publishCollaborationEvent(
  env: EventPublisherEnv,
  type: CollaborationEventType,
  spaceId: string,
  entityId: string,
  options: {
    threadId?: string;
    recipientUserIds?: readonly string[];
    additionalRecipientUserIds?: readonly string[];
    mutations?: readonly D1PreparedStatement[];
  } = {},
): Promise<void> {
  const publisher = createEventPublisher(env);
  const payload = {
    entityId,
    ...(options.threadId ? { threadId: options.threadId } : {}),
  };
  await publisher.publish({
    type,
    spaceId,
    stream: { kind: "space", id: spaceId },
    threadId: options.threadId,
    payload,
    recipientUserIds: options.recipientUserIds,
    mutations: options.mutations,
  });
  // Invitees and removed members cannot subscribe to the Space stream.
  // Give them an ID-only invalidation on their own authorized, replayable stream.
  for (const userId of new Set(options.additionalRecipientUserIds ?? [])) {
    await publisher.publish({
      type,
      spaceId,
      stream: { kind: "user", id: userId },
      payload,
      recipientUserIds: [userId],
    });
  }
}
