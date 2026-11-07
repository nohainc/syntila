/** Current space membership vocabulary. */

import { DomainInvariantError } from "./domain-error.js";

export const SPACE_KINDS = ["group", "direct"] as const;
export type SpaceKind = (typeof SPACE_KINDS)[number];

export type SpaceRole = "owner" | "collaborator" | "viewer";

/** A person participating in a Space; this does not grant Workspace access. */
export interface SpaceMembership {
  readonly id: string;
  readonly spaceId: string;
  readonly userId: string;
  readonly role: SpaceRole;
  readonly permissions?: {
    readonly chat: boolean;
    /** Chat only: the member may answer with Workers from Workspaces they own. */
    readonly useOwnWorkers: boolean;
    readonly work: boolean;
    readonly manageOwnThreads: boolean;
  };
  readonly createdAt: string;
  readonly updatedAt: string;
}

export function validateSpaceMemberships(
  spaceId: string,
  memberships: readonly SpaceMembership[],
  kind: SpaceKind = "group",
): void {
  if (!spaceId.trim()) throw new DomainInvariantError("Space id is required");
  if (memberships.some((membership) => membership.spaceId !== spaceId)) {
    throw new DomainInvariantError(
      "SpaceMembership references a different Space",
    );
  }
  if (
    new Set(memberships.map((membership) => membership.userId)).size !==
    memberships.length
  ) {
    throw new DomainInvariantError(
      "SpaceMembership userId must be unique within a Space",
    );
  }
  if (
    memberships.filter((membership) => membership.role === "owner").length !== 1
  ) {
    throw new DomainInvariantError("Space must have exactly one owner");
  }
  if (kind === "direct" && memberships.length !== 2) {
    throw new DomainInvariantError(
      "Direct Space must have exactly two participants",
    );
  }
}

/** Normalized user pair representing an undirected two-participant relationship. */
export interface NormalizedUserPair {
  readonly userLowId: string;
  readonly userHighId: string;
}

export function normalizeUserPair(
  userA: string,
  userB: string,
): NormalizedUserPair {
  const a = userA.trim();
  const b = userB.trim();
  if (!a || !b) {
    throw new DomainInvariantError("User IDs cannot be empty");
  }
  if (a === b) {
    throw new DomainInvariantError("Cannot pair a user with themselves");
  }
  return a < b
    ? { userLowId: a, userHighId: b }
    : { userLowId: b, userHighId: a };
}

/** Direct Space identity referencing a dedicated one-to-one Space. */
export interface DirectSpace {
  readonly spaceId: string;
  readonly userLowId: string;
  readonly userHighId: string;
  readonly generalThreadId: string;
  readonly createdAt: string;
}

export const PERSON_INVITATION_STATUSES = [
  "pending",
  "accepted",
  "declined",
  "cancelled",
  "expired",
] as const;
export type PersonInvitationStatus =
  (typeof PERSON_INVITATION_STATUSES)[number];

export interface PersonInvitation {
  readonly id: string;
  readonly inviterUserId: string;
  readonly inviteeUserId: string | null;
  readonly email: string | null;
  readonly status: PersonInvitationStatus;
  readonly createdAt: string;
  readonly expiresAt: string;
  readonly acceptedByUserId?: string | null;
  readonly updatedAt: string;
}

export const PERSON_CONNECTION_STATUSES = [
  "connected",
  "disconnected",
] as const;
export type PersonConnectionStatus =
  (typeof PERSON_CONNECTION_STATUSES)[number];

export interface PersonConnection {
  readonly userLowId: string;
  readonly userHighId: string;
  readonly status: PersonConnectionStatus;
  readonly establishedAt: string;
  readonly disconnectedAt?: string | null;
  readonly directSpaceId?: string | null;
}

export interface DirectSpaceUserState {
  readonly spaceId: string;
  readonly userId: string;
  readonly hidden: boolean;
  readonly lastOpenedAt?: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
}
