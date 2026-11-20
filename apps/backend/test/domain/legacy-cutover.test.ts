import { expect, it } from "./helpers/vitest-compat";
import { conversationFixture } from "./helpers/conversation.js";
import { legacyClosedResponse, legacyCutover } from "../../src/domain/legacy-cutover.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";

// P10: staged, reversible cutover away from Workspaces.

it("keeps every legacy surface open until a switch is set, and closing is reversible", async () => {
  const f = await conversationFixture();
  const env = { SYNTILA_DB: f.db } as unknown as SecurityEnv;
  expect(await legacyCutover(env)).toEqual({ registrationClosed: false, gatewayClosed: false, workerRequired: false });
  expect(await legacyClosedResponse(env, "registration")).toBeNull();

  await f.sqlite.exec("UPDATE legacy_cutover SET workspace_registration_closed_at = now(), workspace_gateway_closed_at = now()");
  const registration = await legacyClosedResponse(env, "registration");
  expect(registration?.status).toBe(410);
  expect(await registration!.json()).toMatchObject({ code: "workspace_registration_closed" });
  expect((await legacyClosedResponse(env, "gateway"))?.status).toBe(410);

  await f.sqlite.exec("UPDATE legacy_cutover SET workspace_registration_closed_at = NULL, workspace_gateway_closed_at = NULL");
  expect(await legacyClosedResponse(env, "registration")).toBeNull();
  await f.sqlite.close();
});

it("refuses new assignments without a Worker Instance only while the switch is on", async () => {
  const f = await conversationFixture();
  await f.assign("A"); // no Worker Instance, allowed before the cutover
  await f.sqlite.exec("UPDATE legacy_cutover SET worker_required_from = now()");
  await expect(f.assign("B")).rejects.toThrow(/worker_instance_required/);
  expect(((await f.sqlite.prepare("SELECT id FROM worker_assignments").all()) as unknown[]).length).toBe(1); // existing rows stay
  await f.sqlite.exec("UPDATE legacy_cutover SET worker_required_from = NULL"); // rollback
  await f.assign("C");
  expect(((await f.sqlite.prepare("SELECT id FROM worker_assignments").all()) as unknown[]).length).toBe(2);
  await f.sqlite.close();
});

it("archives the identity mapping once, however often it is asked", async () => {
  const f = await conversationFixture();
  const before = ((await f.sqlite.prepare("SELECT legacy_worker_id FROM legacy_worker_mapping").all()) as unknown[]).length;
  await f.sqlite.exec("SELECT archive_legacy_worker_mapping()");
  await f.sqlite.exec("SELECT archive_legacy_worker_mapping()");
  expect(((await f.sqlite.prepare("SELECT legacy_worker_id FROM legacy_worker_mapping_archive").all()) as unknown[]).length).toBe(before);
  await f.sqlite.close();
});
