import { dataOf } from "../platform/data.js";
import { json } from "./routes/http-security.js";
import type { SecurityEnv } from "./routes/http-security.js";

/**
 * The switches of the staged Workspace cutover (P10, migration 0035). They are
 * read from the database on every use, so every node agrees and a rollback
 * (`scripts/legacy-cutover.sh reopen`) takes effect without a restart.
 */
export type LegacyCutover = {
  registrationClosed: boolean;
  gatewayClosed: boolean;
  workerRequired: boolean;
};

export async function legacyCutover(env: SecurityEnv): Promise<LegacyCutover> {
  const row = await dataOf(env).read.row<{ r: boolean; g: boolean; w: boolean }>`
    SELECT workspace_registration_closed_at IS NOT NULL AS r,
           workspace_gateway_closed_at IS NOT NULL AS g,
           worker_required_from IS NOT NULL AS w
      FROM legacy_cutover WHERE id`;
  return { registrationClosed: row?.r === true, gatewayClosed: row?.g === true, workerRequired: row?.w === true };
}

/** 410 for a closed legacy surface, naming the replacement; null while it is open. */
export async function legacyClosedResponse(env: SecurityEnv, surface: "registration" | "gateway"): Promise<Response | null> {
  const state = await legacyCutover(env);
  const closed = surface === "registration" ? state.registrationClosed : state.gatewayClosed;
  if (!closed) return null;
  return json(
    {
      error:
        surface === "registration"
          ? "Workspaces can no longer register. Install the Syntila Worker Agent and pair it with a code."
          : "The Workspace gateway is closed. Use the Syntila Worker Agent.",
      code: surface === "registration" ? "workspace_registration_closed" : "workspace_gateway_closed",
    },
    { status: 410 },
  );
}
