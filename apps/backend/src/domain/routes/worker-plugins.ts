import type { z } from "@syntila/protocol";
import { PluginPinSchema, PluginUploadSchema } from "@syntila/protocol";
import { readBody, RequestValidationError } from "./validation.js";
import { PluginManifestSchema } from "@syntila/workspace-runtime-protocol";
import { pluginManifestDigest } from "../plugin-manifest-digest.js";
import { HttpError, json, securityContext } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";
import { dataOf, queryOf, type Query, atomically } from "../../platform/data.js";

const selectAccountWorkerPluginVersionsByPlugin = <T = Record<string, unknown>>(q: Query, p1: unknown, p2: unknown) =>
  q.row<T>`SELECT manifest_digest AS digest FROM account_worker_plugin_versions WHERE plugin_ref = ${p1} AND version = ${p2}`;

const selectAccountWorkerPluginsByPluginRef = <T = Record<string, unknown>>(q: Query, p1: unknown, p2: unknown) =>
  q.row<T>`SELECT 1 AS ok FROM account_worker_plugins WHERE plugin_ref = ${p1} AND owner_user_id = ${p2}`;

/**
 * Account library and Workspace enablement for custom Worker plugins
 * (ADR-027). Cloud keeps metadata only: the manifest as imported, its digest,
 * origin display strings, a signer fingerprint and a per-Workspace pin. It never
 * stores or runs an executable and never sees a secret or a local path.
 *
 * Managing plugins (register, enable, disable, remove) is free on every plan.
 * Syntila Plus is enforced only when plugin work is used: the scheduler,
 * thread policy and assignment dispatcher admit plugin Workers only for an
 * entitled owner (`pluginOwnerEntitledSql`, `pluginAssignmentAdmissionSql`).
 */

/** Plugins an account may keep in its library (open decision D11). */
export const PLUGIN_LIBRARY_LIMIT = 20;
/** Versions kept per plugin. */
export const PLUGIN_VERSION_LIMIT = 50;

/** An error with a stable code that clients can branch on. */
export class PluginRouteError extends HttpError {
  constructor(
    status: number,
    readonly code: string,
    message: string,
  ) {
    super(status, message);
  }
}

const REF_PATTERN = /^plugin-[0-9a-f]{12}$/;
const DIGEST_PATTERN = /^[0-9a-f]{64}$/;

function allocatePluginRef(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return `plugin-${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}`;
}

/** Reads a body with a schema; a rejected body keeps the plugin routes' own error shape. */
async function readPluginBody<S extends z.ZodType>(
  request: Request,
  schema: S,
): Promise<z.output<S> & Record<string, unknown>> {
  try {
    return (await readBody(request, schema)) as z.output<S> & Record<string, unknown>;
  } catch (error) {
    if (error instanceof RequestValidationError)
      throw new PluginRouteError(400, "invalid_request", error.message);
    throw error;
  }
}

function onlyKeys(body: Record<string, unknown>, allowed: readonly string[]) {
  const extra = Object.keys(body).find((key) => !allowed.includes(key));
  if (extra)
    throw new PluginRouteError(
      400,
      "invalid_request",
      `Unexpected field: ${extra}`,
    );
}

function requireRef(value: string | undefined): string {
  if (!value || !REF_PATTERN.test(value))
    throw new PluginRouteError(
      400,
      "invalid_request",
      "Invalid plugin reference",
    );
  return value;
}

/**
 * `GET|POST /api/me/external-workers` and `DELETE /api/me/external-workers/:ref`
 * (also served under the pre-rename `/api/me/worker-plugins`).
 */
export async function handlePluginLibrary(
  request: Request,
  env: SecurityEnv,
  pluginRef?: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const userId = context.userId;
  const db = env.SYNTILA_DB;

  if (pluginRef !== undefined) {
    if (request.method !== "DELETE")
      throw new HttpError(405, "Unsupported method");
    return removeFromLibrary(env, userId, requireRef(pluginRef));
  }
  if (request.method === "GET") {
    const rows = await queryOf(db).rows<Record<string, string | null>>`SELECT p.plugin_ref AS "pluginRef", p.plugin_id AS "pluginId",
                p.display_name AS "displayName", p.created_at AS "createdAt",
                v.version AS version, v.manifest_digest AS "manifestDigest",
                v.origin_json AS "originJson", v.created_at AS "versionCreatedAt"
           FROM account_worker_plugins p
           LEFT JOIN account_worker_plugin_versions v ON v.plugin_ref = p.plugin_ref
          WHERE p.owner_user_id = ${userId}
          ORDER BY p.created_at, v.created_at LIMIT 1000`;
    const plugins = new Map<string, Record<string, unknown>>();
    for (const row of rows) {
      const ref = String(row.pluginRef);
      const entry = plugins.get(ref) ?? {
        pluginRef: ref,
        pluginId: row.pluginId,
        displayName: row.displayName,
        createdAt: row.createdAt,
        versions: [] as unknown[],
      };
      if (row.version)
        (entry.versions as unknown[]).push({
          version: row.version,
          manifestDigest: row.manifestDigest,
          origin: JSON.parse(String(row.originJson)),
          createdAt: row.versionCreatedAt,
        });
      plugins.set(ref, entry);
    }
    return json({ plugins: [...plugins.values()] });
  }
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");

  const body = await readPluginBody(request, PluginUploadSchema);
  onlyKeys(body, ["manifest", "manifestDigest", "origin", "signer"]);

  const parsed = PluginManifestSchema.safeParse(body.manifest);
  if (!parsed.success)
    throw new PluginRouteError(
      400,
      "plugin_manifest_invalid",
      `Manifest is invalid at ${parsed.error.issues[0]?.path.join(".") || "(root)"}`,
    );
  const manifest = parsed.data;
  // Cloud recomputes the pinned identity; it never trusts a client digest.
  const digest = await pluginManifestDigest(manifest);
  if (
    typeof body.manifestDigest !== "string" ||
    !DIGEST_PATTERN.test(body.manifestDigest) ||
    body.manifestDigest !== digest
  )
    throw new PluginRouteError(
      400,
      "plugin_digest_mismatch",
      "The manifest digest does not match the manifest",
    );
  const origin = body.origin as Record<string, unknown> | undefined;
  if (
    !origin ||
    typeof origin !== "object" ||
    Object.keys(origin).some((key) => !["kind", "locator"].includes(key)) ||
    !["local_path", "export_bundle"].includes(String(origin.kind)) ||
    typeof origin.locator !== "string" ||
    origin.locator.length < 1 ||
    origin.locator.length > 256 ||
    /[\\/]/.test(origin.locator)
  )
    throw new PluginRouteError(
      400,
      "invalid_request",
      "origin must be a kind and a display name, never a path",
    );
  const signer = body.signer as Record<string, unknown> | undefined | null;
  if (
    signer != null &&
    (typeof signer !== "object" ||
      Object.keys(signer).some(
        (key) => !["fingerprint", "verified"].includes(key),
      ) ||
      typeof signer.fingerprint !== "string" ||
      !DIGEST_PATTERN.test(signer.fingerprint) ||
      typeof signer.verified !== "boolean")
  )
    throw new PluginRouteError(400, "invalid_request", "Invalid signer");

  const now = new Date().toISOString();
  const existing = await queryOf(db).row<{ pluginRef: string; displayName: string }>`SELECT plugin_ref AS "pluginRef", display_name AS "displayName" FROM account_worker_plugins WHERE owner_user_id = ${userId} AND plugin_id = ${manifest.pluginId}`;
  let ref = existing?.pluginRef;
  if (!ref) {
    const count = await queryOf(db).row<{ n: number }>`SELECT COUNT(*) AS n FROM account_worker_plugins WHERE owner_user_id = ${userId}`;
    if ((count?.n ?? 0) >= PLUGIN_LIBRARY_LIMIT)
      throw new PluginRouteError(
        409,
        "plugin_quota_exceeded",
        `A library holds at most ${PLUGIN_LIBRARY_LIMIT} plugins`,
      );
    ref = allocatePluginRef();
    await atomically(db, "worker-plugins.register", async (q) => {
      await q.run`INSERT INTO account_worker_plugins
             (plugin_ref, owner_user_id, plugin_id, display_name, created_at, updated_at)
           VALUES (${ref}, ${userId}, ${manifest.pluginId}, ${manifest.displayName}, ${now}, ${now})`;
      // The catalog row lets assignments reference the plugin Worker. Only its
      // owner's Workspaces ever list it (readers filter on origin/owner).
      await q.run`INSERT INTO worker_catalog
             (worker_type_id, display_name, description, lifecycle_state,
              created_at, updated_at, engine_family, visibility_state,
              release_stage, sort_order, origin, owner_user_id)
           VALUES (${ref}, ${manifest.displayName}, ${manifest.description.slice(0, 500)}, 'active', ${now}, ${now}, 'cli', 'visible', 'stable',
                   1000, 'plugin', ${userId})`;
    });
  } else if (existing && existing.displayName !== manifest.displayName) {
    await atomically(db, "worker-plugins.batch231", async (q) => {
      await q.run`UPDATE account_worker_plugins SET display_name = ${manifest.displayName}, updated_at = ${now} WHERE plugin_ref = ${ref}`;
      await q.run`UPDATE worker_catalog SET display_name = ${manifest.displayName}, updated_at = ${now} WHERE worker_type_id = ${ref}`;
    });
  }

  const version = await selectAccountWorkerPluginVersionsByPlugin<{ digest: string }>(queryOf(db), ref, manifest.version);
  if (version && version.digest !== digest)
    throw new PluginRouteError(
      409,
      "plugin_version_conflict",
      "This version is already registered with different contents",
    );
  if (!version) {
    const versions = await queryOf(db).row<{ n: number }>`SELECT COUNT(*) AS n FROM account_worker_plugin_versions WHERE plugin_ref = ${ref}`;
    if ((versions?.n ?? 0) >= PLUGIN_VERSION_LIMIT)
      throw new PluginRouteError(
        409,
        "plugin_quota_exceeded",
        `A plugin keeps at most ${PLUGIN_VERSION_LIMIT} versions`,
      );
    await queryOf(db).run`INSERT INTO account_worker_plugin_versions
           (plugin_ref, version, manifest_digest, manifest_json, origin_json, signer_json, created_at)
         VALUES (${ref}, ${manifest.version}, ${digest}, ${JSON.stringify(manifest)}, ${JSON.stringify({ kind: origin.kind, locator: origin.locator })}, ${signer ? JSON.stringify(signer) : null}, ${now})`;
  }
  return json(
    {
      pluginRef: ref,
      pluginId: manifest.pluginId,
      version: manifest.version,
      manifestDigest: digest,
    },
    { status: version ? 200 : 201 },
  );
}

/**
 * Removing a plugin from the library. Free, so a downgraded owner can clean up.
 * Refused while any Workspace still has it enabled. The catalog row is retired
 * rather than deleted because assignment history references it; it holds only
 * the display name.
 */
async function removeFromLibrary(
  env: SecurityEnv,
  userId: string,
  pluginRef: string,
): Promise<Response> {
  const db = env.SYNTILA_DB;
  const owned = await selectAccountWorkerPluginsByPluginRef(queryOf(db), pluginRef, userId);
  if (!owned)
    throw new PluginRouteError(404, "plugin_not_found", "Plugin not found");
  const enabled = await queryOf(db).row`SELECT 1 AS ok FROM worker_instances WHERE worker_type_id = ${pluginRef} AND revoked_at IS NULL AND enabled LIMIT 1`;
  if (enabled)
    throw new PluginRouteError(
      409,
      "plugin_in_use",
      "Disable or remove active Workers using this plugin first",
    );
  const active = await queryOf(db).row`SELECT 1 AS ok FROM worker_assignments
        WHERE worker_type_id = ${pluginRef} AND status IN ('created','queued','sent','accepted','running','cancel_requested') LIMIT 1`.catch(() => null);
  if (active)
    throw new PluginRouteError(
      409,
      "plugin_in_use",
      "This plugin still has running work",
    );
  const now = new Date().toISOString();
  await atomically(db, "worker-plugins.batch312", async (q) => {
    await q.run`UPDATE worker_catalog SET lifecycle_state = 'retired', visibility_state = 'hidden', updated_at = ${now} WHERE worker_type_id = ${pluginRef}`;
    await q.run`DELETE FROM account_worker_plugins WHERE plugin_ref = ${pluginRef}`;
  });
  return json({ removed: true });
}

