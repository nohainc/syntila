import { expect, it } from "vitest";
import {
  defaultSpaceMemberPermissions,
  normalizeSpaceMemberSnapshot,
  spaceMemberPermissions,
  storedSpaceMemberRights,
} from "../src/index.js";

it("keeps role defaults only when the override is absent, and fails closed for malformed stored overrides", () => {
  const none = defaultSpaceMemberPermissions("viewer");
  for (const value of [false, null, 0, "", [], "invalid", { chat: "true" }]) {
    expect(
      spaceMemberPermissions(
        "collaborator",
        { memberPermissions: { member: value } },
        "member",
      ),
    ).toEqual(none);
  }
  expect(spaceMemberPermissions("collaborator", {}, "member")).toEqual(
    defaultSpaceMemberPermissions("collaborator"),
  );
  expect(
    spaceMemberPermissions(
      "owner",
      { memberPermissions: { member: none } },
      "member",
    ),
  ).toEqual(defaultSpaceMemberPermissions("owner"));
  expect(
    spaceMemberPermissions(
      "collaborator",
      { memberPermissions: { member: { chat: true } } },
      "member",
    ),
  ).toEqual({ ...none, chat: true, useOwnWorkers: true });
  // Legacy useOwnWorkers is never read from stored data.
  expect(
    spaceMemberPermissions(
      "collaborator",
      { memberPermissions: { member: { chat: false, useOwnWorkers: true } } },
      "member",
    ).useOwnWorkers,
  ).toBe(false);
  expect(
    spaceMemberPermissions(
      "collaborator",
      { memberPermissions: { member: { chat: true, useOwnWorkers: false } } },
      "member",
    ).useOwnWorkers,
  ).toBe(true);
});

it("normalizes invitation snapshots fail-closed and stores only three rights", () => {
  const none = defaultSpaceMemberPermissions("viewer");
  expect(normalizeSpaceMemberSnapshot("viewer", undefined)).toEqual(none);
  expect(normalizeSpaceMemberSnapshot("collaborator", {})).toEqual(
    defaultSpaceMemberPermissions("collaborator"),
  );
  expect(normalizeSpaceMemberSnapshot("collaborator", "junk")).toEqual(
    defaultSpaceMemberPermissions("collaborator"),
  );
  expect(
    normalizeSpaceMemberSnapshot("collaborator", { chat: "yes", work: true }),
  ).toEqual({ ...none, work: true });
  expect(
    storedSpaceMemberRights(defaultSpaceMemberPermissions("owner")),
  ).toEqual({ chat: true, work: true, manageOwnThreads: true });
});

it("derives own Workers from Chat", () => {
  expect(defaultSpaceMemberPermissions("collaborator").useOwnWorkers).toBe(
    true,
  );
  expect(defaultSpaceMemberPermissions("viewer").useOwnWorkers).toBe(false);
  const stored = (value: Record<string, boolean>) =>
    spaceMemberPermissions(
      "collaborator",
      { memberPermissions: { member: value } },
      "member",
    ).useOwnWorkers;
  expect(stored({ chat: true, useOwnWorkers: true })).toBe(true);
  expect(stored({ chat: false, useOwnWorkers: true })).toBe(false);
  expect(stored({ chat: true })).toBe(true);
  expect(stored({ chat: true, useOwnWorkers: false })).toBe(true);
});
