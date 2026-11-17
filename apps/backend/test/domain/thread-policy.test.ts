import { pgD1 } from "./helpers/pg-d1";
import { T0, user, workspace } from "./helpers/seed";
import { describe, expect, it } from "./helpers/vitest-compat";

import {
  eligibilityMessage,
  normalizeThreadWorkConfig,
} from "../../src/domain/routes/thread-policy.js";

describe("catalog-backed Worker validation messages", () => {
  it("uses the supplied catalog name without deriving names from Worker IDs", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "worker_not_ready",
        null,
        "Dynamic Test Worker",
      ),
    ).toBe("Implement: Dynamic Test Worker is not Ready.");
  });

  it("uses a neutral label when catalog display metadata is unavailable", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "worker_not_ready",
      ),
    ).toBe("Implement: Selected Worker is not Ready.");
  });

  it("ignores blank catalog display metadata and stays Worker-neutral", () => {
    expect(
      eligibilityMessage(
        "implement",
        "dynamic-test-worker",
        "worker_disabled",
        null,
        "   ",
      ),
    ).toBe("Implement: Selected Worker is disabled.");
  });
});

describe("Thread authored context", () => {
  it("normalizes instructions without execution preferences", () => {
    expect(
      normalizeThreadWorkConfig({
        defaultWorkflowId: "chat",
        threadInstructions: " Context ",
        bindings: {
          chat: { additionalInstructions: " Focus " },
          direct: { additionalInstructions: " " },
        },
      }).config,
    ).toEqual({
      defaultWorkflowId: "chat",
      threadInstructions: "Context",
      bindings: { chat: { additionalInstructions: "Focus" } },
    });
  });
  it.each([
    "workerId",
    "workerLabel",
    "model",
    "reasoningEffort",
    "fallbackWorkerId",
    "fallbackWorkerLabel",
  ])("rejects obsolete %s preferences", (key) => {
    expect(() =>
      normalizeThreadWorkConfig({
        defaultWorkflowId: "chat",
        bindings: { chat: { [key]: "old" } },
      }),
    ).toThrow("use Workflows");
  });
  it.each([null, 123, "x".repeat(4001)])(
    "rejects malformed instructions %s",
    (instructions) => {
      expect(() =>
        normalizeThreadWorkConfig({
          defaultWorkflowId: "chat",
          bindings: { chat: { additionalInstructions: instructions } },
        }),
      ).toThrow();
    },
  );
});

it("validates selected effort and models against the selected Worker Profile", async () => {
  const { validateWorkflowWorkerEligibility } =
    await import("../../src/domain/routes/thread-policy.js");
  const { BUILTIN_WORKFLOWS } = await import("@syntila/core");
  const executionProfile = JSON.stringify({
    schemaVersion: 1,
    session: { supported: true },
    model: {
      supported: true,
      unknownModelPolicy: "profile_allowlist",
      allowlist: ["a", "b"],
      supportedReasoningEfforts: ["brief", "deep"],
      catalog: [
        { id: "a", name: "A", supportedReasoningEfforts: ["deep"] },
        { id: "b", name: "B", supportedReasoningEfforts: [] },
      ],
    },
  });
  const { db, sqlite } = await pgD1();
  await sqlite.exec(
    user("owner") +
      workspace("WS", "owner") +
      `INSERT INTO worker_catalog (worker_type_id, display_name, created_at, updated_at)
         VALUES ('generic-worker', 'Generic', '${T0}', '${T0}');
       INSERT INTO workspace_worker_inventory (
         worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
         local_concurrency_limit, revision, profile_definition_id, profile_release_version,
         created_at, updated_at, last_seen_at
       ) VALUES ('worker', 'WS', 'owner', 'generic-worker', 'enabled', 'ready', 1, 1,
         'generic-profile', 1, '${T0}', '${T0}', '${T0}');`,
  );
  await sqlite
    .prepare(
      `INSERT INTO worker_profiles (worker_type_id, schema_version, profile_json, revision, digest, updated_at)
       VALUES ('generic-worker', 1, ?, 1, ?, '${T0}')`,
    )
    .run(executionProfile, "a".repeat(64));
  const env = { SYNTILA_DB: db } as unknown as import("../../src/domain/routes/http-security.js").SecurityEnv;
  for (const [model, effort, invalid] of [
    ["a", "deep", false],
    ["a", "brief", true],
    ["b", "deep", true],
    ["other", null, true],
  ] as const) {
    const result = await validateWorkflowWorkerEligibility(
      env,
      "P",
      "W",
      BUILTIN_WORKFLOWS.chat,
      {
        chat: {
          workerId: "worker",
          model,
          ...(effort ? { reasoningEffort: effort } : {}),
        },
      },
    );
    expect(
      result.issues.some(
        (issue) => issue.code === "profile_execution_option_unavailable",
      ),
    ).toBe(invalid);
  }
  const admitted = await validateWorkflowWorkerEligibility(
    env,
    "P",
    "W",
    BUILTIN_WORKFLOWS.chat,
    { chat: { workerId: "worker", model: "a", reasoningEffort: "deep" } },
  );
  const revision = admitted.workerCatalogRevisions.chat;
  expect(revision).toMatch(/^[a-f0-9]{64}$/);
  const pinned = {
    chat: {
      workerId: "worker",
      model: "a",
      reasoningEffort: "deep",
      catalogRevision: revision,
    },
  };
  // The Profile is republished with a renamed model: same revision, new content.
  (await sqlite
    .prepare("UPDATE worker_profiles SET profile_json = ?, digest = ? WHERE worker_type_id = 'generic-worker'")
    .run(executionProfile.replace('"name":"A"', '"name":"Renamed A"'), "b".repeat(64)));
  const changed = await validateWorkflowWorkerEligibility(
    env,
    "P",
    "W",
    BUILTIN_WORKFLOWS.chat,
    pinned,
  );
  expect(changed.issues).toContainEqual(
    expect.objectContaining({
      code: "profile_execution_option_unavailable",
      message: expect.stringContaining("catalog changed"),
    }),
  );
  const accepted = {
    chat: {
      schemaVersion: 1 as const,
      workerId: "worker",
      profileId: "generic-profile",
      profileReleaseVersion: 1,
      modelId: "a",
      effort: "deep",
      workflowId: "chat" as const,
      workflowVersion: 1,
    },
  };
  const retry = await validateWorkflowWorkerEligibility(
    env,
    "P",
    "W",
    BUILTIN_WORKFLOWS.chat,
    pinned,
    accepted,
  );
  expect(
    retry.issues.some(
      (issue) => issue.code === "profile_execution_option_unavailable",
    ),
  ).toBe(false);
  const replacedProfile = await validateWorkflowWorkerEligibility(
    env,
    "P",
    "W",
    BUILTIN_WORKFLOWS.chat,
    pinned,
    { chat: { ...accepted.chat, profileReleaseVersion: 2 } },
  );
  expect(
    replacedProfile.issues.some(
      (issue) => issue.code === "profile_execution_option_unavailable",
    ),
  ).toBe(true);
});
