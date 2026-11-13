import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "./helpers/vitest-compat";
import {
  getCurrentWorkerProfile,
  listWorkerProfileHistory,
  listWorkerProfiles,
  publishWorkerProfile,
  restoreWorkerProfile,
  validateWorkerProfileCandidate,
} from "../../src/domain/worker-profile-registry.js";
import { toolProfileAcceptanceScenarioStatuses } from "../../src/domain/tool-profile-validation.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

const fixture = JSON.parse(
  readFileSync(
    fileURLToPath(
      new URL(
        "../../../../packages/tool-profile/test/fixtures/fixture-cli.v1.json",
        import.meta.url,
      ),
    ),
    "utf8",
  ),
) as Record<string, unknown>;

function makeProfile(workerTypeId: string, releaseVersion: number) {
  const profile = structuredClone(fixture) as Record<string, unknown>;
  profile.logicalWorkerTypeId = workerTypeId;
  profile.releaseVersion = releaseVersion;
  return profile;
}

function makeEvidence(profile: Record<string, unknown>, digest: string) {
  const provider = profile.providerTool as Record<string, unknown>;
  return {
    formatVersion: 1,
    workerTypeId: profile.logicalWorkerTypeId,
    candidateDigest: digest,
    engineVersion: "1.2.0",
    providerToolName: provider.name,
    providerToolVersion: "0.3.1",
    testedAt: new Date().toISOString(),
    scenarios: toolProfileAcceptanceScenarioStatuses(profile as never),
  };
}

function setup() {
  const { db, sqlite } = sqliteD1();
  sqlite.exec(
    "" /* D1 migration: schema is final in PostgreSQL */,
  );
  sqlite.exec(
    "" /* D1 migration: schema is final in PostgreSQL */,
  );
  const now = new Date().toISOString();
  sqlite
    .prepare(
      `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
       VALUES (?, ?, ?, 'active', ?, ?)`,
    )
    .run("profile-lab", "profile-lab@test", "Profile Lab", now, now);
  sqlite
    .prepare(
      `INSERT INTO worker_catalog
         (worker_type_id, display_name, description, lifecycle_state,
          created_at, updated_at, engine_family, visibility_state,
          release_stage, profile_definition_id, provider_tool_name, sort_order)
       VALUES (?, ?, ?, 'active', ?, ?, 'cli', 'visible', 'stable', ?, ?, ?)`,
    )
    .run(
      "fixture-worker",
      "Fixture Worker",
      "V9 registry fixture",
      now,
      now,
      "fixture-cli",
      "fixture",
      1,
    );
  const env = {
    SYNTILA_DB: db,
  } as unknown as Env;
  return { db, sqlite, env };
}

describe("V9 Worker Profile registry", () => {
  it("publishes one current snapshot, keeps history, and restores atomically", async () => {
    const { env, sqlite } = setup();
    try {
      const first = makeProfile("fixture-worker", 1);
      delete (first.providerTool as Record<string, unknown>).supportedVersions;
      const firstValidation = await validateWorkerProfileCandidate(
        "fixture-worker",
        first,
      );
      const published = await publishWorkerProfile({
        env,
        workerTypeId: "fixture-worker",
        expectedRevision: 0,
        candidate: first,
        candidateDigest: firstValidation.digest,
        evidence: makeEvidence(first, firstValidation.digest),
        actorUserId: "profile-lab",
      });
      expect(published.revision).toBe(1);
      expect(published.profile.providerTool).not.toHaveProperty(
        "supportedVersions",
      );

      await expect(
        publishWorkerProfile({
          env,
          workerTypeId: "fixture-worker",
          expectedRevision: 1,
          candidate: first,
          candidateDigest: undefined,
          evidence: makeEvidence(first, firstValidation.digest),
          actorUserId: "profile-lab",
        }),
      ).rejects.toMatchObject({ status: 400 });
      await expect(
        publishWorkerProfile({
          env,
          workerTypeId: "fixture-worker",
          expectedRevision: 1,
          candidate: first,
          candidateDigest: firstValidation.digest,
          evidence: undefined,
          actorUserId: "profile-lab",
        }),
      ).rejects.toMatchObject({ status: 409 });

      const second = makeProfile("fixture-worker", 2);
      const secondValidation = await validateWorkerProfileCandidate(
        "fixture-worker",
        second,
      );
      await publishWorkerProfile({
        env,
        workerTypeId: "fixture-worker",
        expectedRevision: 1,
        candidate: second,
        candidateDigest: secondValidation.digest,
        evidence: makeEvidence(second, secondValidation.digest),
        actorUserId: "profile-lab",
      });

      sqlite
        .prepare(
          "UPDATE worker_profile_history SET digest = ? WHERE worker_type_id = ? AND revision = ?",
        )
        .run("f".repeat(64), "fixture-worker", 1);
      await expect(
        restoreWorkerProfile({
          env,
          workerTypeId: "fixture-worker",
          expectedRevision: 2,
          targetRevision: 1,
          restorationReason: "Reject tampered history",
          actorUserId: "profile-lab",
        }),
      ).rejects.toMatchObject({ status: 409 });
      sqlite
        .prepare(
          "UPDATE worker_profile_history SET digest = ? WHERE worker_type_id = ? AND revision = ?",
        )
        .run(firstValidation.digest, "fixture-worker", 1);

      await expect(
        publishWorkerProfile({
          env,
          workerTypeId: "fixture-worker",
          expectedRevision: 1,
          candidate: first,
          candidateDigest: firstValidation.digest,
          evidence: makeEvidence(first, firstValidation.digest),
          actorUserId: "profile-lab",
        }),
      ).rejects.toMatchObject({ status: 409 });

      const historyBeforeRestore = await listWorkerProfileHistory(
        env,
        "fixture-worker",
      );
      expect(historyBeforeRestore.history.map((row) => row.revision)).toEqual([
        1,
      ]);

      const restored = await restoreWorkerProfile({
        env,
        workerTypeId: "fixture-worker",
        expectedRevision: 2,
        targetRevision: 1,
        restorationReason: "Restore the last known-good snapshot",
        actorUserId: "profile-lab",
      });
      expect(restored.revision).toBe(3);
      expect(restored.profile.releaseVersion).toBe(1);

      const historyAfterRestore = await listWorkerProfileHistory(
        env,
        "fixture-worker",
      );
      expect(historyAfterRestore.history.map((row) => row.revision)).toEqual([
        2, 1,
      ]);
      expect(historyAfterRestore.history[0]?.restorationReason).toContain(
        "last known-good",
      );
      expect(
        (await getCurrentWorkerProfile(env, "fixture-worker")).revision,
      ).toBe(3);
    } finally {
      sqlite.close();
    }
  });

  it("lists every managed Worker without channel-pointer resolution", async () => {
    const { env, sqlite } = setup();
    try {
      const result = await listWorkerProfiles(env.SYNTILA_DB);
      expect(result.workers).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            workerTypeId: "fixture-worker",
            profileDefinitionId: "fixture-cli",
            providerToolName: "fixture",
            currentRevision: null,
            currentDigest: null,
          }),
        ]),
      );
    } finally {
      sqlite.close();
    }
  });
});
