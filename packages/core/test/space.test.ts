import { describe, expect, it } from "vitest";
import {
  SPACE_KINDS,
  validateSpaceMemberships,
  normalizeUserPair,
  type SpaceMembership,
} from "../src/index.js";

const membership = (
  userId: string,
  role: SpaceMembership["role"],
): SpaceMembership => ({
  id: `membership-${userId}`,
  spaceId: "space-1",
  userId,
  role,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
});

describe("Space membership", () => {
  it("exports SPACE_KINDS", () => {
    expect(SPACE_KINDS).toEqual(["group", "direct"]);
  });

  it("requires one owner and unique users within the Space", () => {
    expect(() =>
      validateSpaceMemberships("space-1", [
        membership("owner", "owner"),
        membership("collaborator", "collaborator"),
      ]),
    ).not.toThrow();
    expect(() =>
      validateSpaceMemberships("space-1", [membership("viewer", "viewer")]),
    ).toThrow(/exactly one owner/);
    expect(() =>
      validateSpaceMemberships("space-1", [
        membership("owner", "owner"),
        membership("owner", "collaborator"),
      ]),
    ).toThrow(/unique/);
  });

  it("validates direct space membership cardinality", () => {
    expect(() =>
      validateSpaceMemberships(
        "space-1",
        [
          membership("owner", "owner"),
          membership("collaborator", "collaborator"),
        ],
        "direct",
      ),
    ).not.toThrow();

    expect(() =>
      validateSpaceMemberships(
        "space-1",
        [membership("owner", "owner")],
        "direct",
      ),
    ).toThrow(/Direct Space must have exactly two participants/);
  });

  it("normalizes user pairs and prevents self-conversations", () => {
    expect(normalizeUserPair("bob", "alice")).toEqual({
      userLowId: "alice",
      userHighId: "bob",
    });
    expect(normalizeUserPair("alice", "bob")).toEqual({
      userLowId: "alice",
      userHighId: "bob",
    });
    expect(() => normalizeUserPair("alice", "alice")).toThrow(
      /Cannot pair a user with themselves/,
    );
    expect(() => normalizeUserPair("", "bob")).toThrow(
      /User IDs cannot be empty/,
    );
  });
});
