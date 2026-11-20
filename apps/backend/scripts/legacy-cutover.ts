#!/usr/bin/env bun
/**
 * Staged cutover away from Workspaces (P10). Each step is a switch in the
 * `legacy_cutover` table, so it can be rehearsed and rolled back.
 *
 *   bun scripts/legacy-cutover.ts status
 *   bun scripts/legacy-cutover.ts close-registration   no new Workspace registers
 *   bun scripts/legacy-cutover.ts require-worker       new assignments/commands must name a Worker Instance
 *   bun scripts/legacy-cutover.ts close-gateway        refuses while legacy assignments are still running (--force to override)
 *   bun scripts/legacy-cutover.ts archive-mapping      copy legacy_worker_mapping into its archive table
 *   bun scripts/legacy-cutover.ts reopen [registration|gateway|worker|all]   roll back (default all)
 *
 * Connection: PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE (defaults: the local
 * development database). Against production, run it on the VPS with the
 * service's environment; it never runs by itself.
 */
import { SQL } from "bun";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "../src/domain/assignment-transitions";

const db = new SQL({
  hostname: process.env.PGHOST ?? "127.0.0.1",
  port: Number(process.env.PGPORT ?? 5432),
  username: process.env.PGUSER ?? "syntila_app",
  password: process.env.PGPASSWORD ?? "devpass",
  database: process.env.PGDATABASE ?? "syntila_local",
  max: 2,
});
const [command = "status", arg] = Bun.argv.slice(2).filter((a) => a !== "--force");
const force = Bun.argv.includes("--force");

type State = { registration: Date | null; gateway: Date | null; worker: Date | null };
async function state(): Promise<State> {
  const [r] = await db`SELECT workspace_registration_closed_at AS registration, workspace_gateway_closed_at AS gateway, worker_required_from AS worker FROM legacy_cutover WHERE id`;
  return r as State;
}
async function legacyWork() {
  const [r] = await db.unsafe(
    `SELECT count(*)::int AS open_assignments FROM worker_assignments WHERE worker_instance_id IS NULL AND status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})`,
  );
  const [u] = await db`SELECT count(*)::int AS unmapped FROM workspace_worker_inventory i WHERE NOT EXISTS (SELECT 1 FROM legacy_worker_mapping m WHERE m.legacy_worker_id = i.worker_id)`;
  const [a] = await db`SELECT count(*)::int AS archived FROM legacy_worker_mapping_archive`;
  const [m] = await db`SELECT count(*)::int AS mapped FROM legacy_worker_mapping`;
  return { ...(r as object), ...(u as object), ...(a as object), ...(m as object) } as { open_assignments: number; unmapped: number; archived: number; mapped: number };
}
async function set(column: "workspace_registration_closed_at" | "workspace_gateway_closed_at" | "worker_required_from", on: boolean) {
  await db.unsafe(`UPDATE legacy_cutover SET ${column} = ${on ? "COALESCE(" + column + ", now())" : "NULL"}, updated_at = now() WHERE id`);
}
async function print() {
  const s = await state();
  const w = await legacyWork();
  const f = (d: Date | null) => (d ? `closed since ${d.toISOString()}` : "open");
  console.log(`workspace registration : ${f(s.registration)}`);
  console.log(`workspace gateway      : ${f(s.gateway)}`);
  console.log(`worker required        : ${s.worker ? `on since ${s.worker.toISOString()}` : "off"}`);
  console.log(`legacy assignments still running: ${w.open_assignments}`);
  console.log(`inventory Workers without a Worker Instance: ${w.unmapped}`);
  console.log(`identity mapping: ${w.mapped} rows, ${w.archived} archived`);
}

try {
  switch (command) {
    case "status": break;
    case "close-registration": await set("workspace_registration_closed_at", true); break;
    case "require-worker": {
      const w = await legacyWork();
      if (w.unmapped > 0 && !force) { console.error(`${w.unmapped} inventory Workers have no Worker Instance yet (run the P1 backfill); --force to override.`); process.exitCode = 1; break; }
      await set("worker_required_from", true); break;
    }
    case "close-gateway": {
      const w = await legacyWork();
      if (w.open_assignments > 0 && !force) { console.error(`${w.open_assignments} legacy assignments are still running; let them finish (--force to override).`); process.exitCode = 1; break; }
      await set("workspace_gateway_closed_at", true); break;
    }
    case "archive-mapping": {
      const [r] = await db`SELECT archive_legacy_worker_mapping() AS copied`;
      console.log(`archived ${(r as { copied: number }).copied} mapping rows`);
      break;
    }
    case "reopen": {
      const which = arg ?? "all";
      if (which === "registration" || which === "all") await set("workspace_registration_closed_at", false);
      if (which === "gateway" || which === "all") await set("workspace_gateway_closed_at", false);
      if (which === "worker" || which === "all") await set("worker_required_from", false);
      break;
    }
    default: console.error(`unknown command "${command}"`); process.exitCode = 2;
  }
  if (!process.exitCode) await print();
} finally {
  await db.close();
}
