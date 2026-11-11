import { PluginManifestSchema } from "@syntila/workspace-runtime-protocol";
import { pluginManifestDigest } from "../plugin-manifest-digest.js";
import { HttpError, json, securityContext } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

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

async function readBody(request: Request): Promise<Record<string, unknown>> {
  const body = (await request.json().catch(() => null)) as unknown;
  if (!body || typeof body !== "object" || Array.isArray(body))
    throw new PluginRouteError(
      400,
      "invalid_request",
      "A JSON body is required",
    );
  return body as Record<string, unknown>;
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
    const rows = await db
      .prepare(
        `SELECT p.plugin_ref AS pluginRef, p.plugin_id AS pluginId,
                p.display_name AS displayName, p.created_at AS createdAt,
                v.version AS version, v.manifest_digest AS manifestDigest,
                v.origin_json AS originJson, v.created_at AS versionCreatedAt
           FROM account_worker_plugins p
           LEFT JOIN account_worker_plugin_versions v ON v.plugin_ref = p.plugin_ref
          WHERE p.owner_user_id = ?1
          ORDER BY p.created_at, v.created_at LIMIT 1000`,
      )
      .bind(userId)
      .all<Record<string, string | null>>();
    const plugins = new Map<string, Record<string, unknown>>();
    for (const row of rows.results ?? []) {
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

  const body = await readBody(request);
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
  const existing = await db
    .prepare(
      "SELECT plugin_ref AS pluginRef, display_name AS displayName FROM account_worker_plugins WHERE owner_user_id = ?1 AND plugin_id = ?2",
    )
    .bind(userId, manifest.pluginId)
    .first<{ pluginRef: string; displayName: string }>();
  let ref = existing?.pluginRef;
  if (!ref) {
    const count = await db
      .prepare(
        "SELECT COUNT(*) AS n FROM account_worker_plugins WHERE owner_user_id = ?1",
      )
      .bind(userId)
      .first<{ n: number }>();
    if ((count?.n ?? 0) >= PLUGIN_LIBRARY_LIMIT)
      throw new PluginRouteError(
        409,
        "plugin_quota_exceeded",
        `A library holds at most ${PLUGIN_LIBRARY_LIMIT} plugins`,
      );
    ref = allocatePluginRef();
    await db.batch([
      db
        .prepare(
          `INSERT INTO account_worker_plugins
             (plugin_ref, owner_user_id, plugin_id, display_name, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?5)`,
        )
        .bind(ref, userId, manifest.pluginId, manifest.displayName, now),
      // The catalog row lets assignments reference the plugin Worker. Only its
      // owner's Workspaces ever list it (readers filter on origin/owner).
      db
        .prepare(
          `INSERT INTO worker_catalog
             (worker_type_id, display_name, description, lifecycle_state,
              created_at, updated_at, engine_family, visibility_state,
              release_stage, sort_order, origin, owner_user_id)
           VALUES (?1, ?2, ?3, 'active', ?4, ?4, 'cli', 'visible', 'stable',
                   1000, 'plugin', ?5)`,
        )
        .bind(
          ref,
          manifest.displayName,
          manifest.description.slice(0, 500),
          now,
          userId,
        ),
    ]);
  } else if (existing && existing.displayName !== manifest.displayName) {
    await db.batch([
      db
        .prepare(
          "UPDATE account_worker_plugins SET display_name = ?2, updated_at = ?3 WHERE plugin_ref = ?1",
        )
        .bind(ref, manifest.displayName, now),
      db
        .prepare(
          "UPDATE worker_catalog SET display_name = ?2, updated_at = ?3 WHERE worker_type_id = ?1",
        )
        .bind(ref, manifest.displayName, now),
    ]);
  }

  const version = await db
    .prepare(
      "SELECT manifest_digest AS digest FROM account_worker_plugin_versions WHERE plugin_ref = ?1 AND version = ?2",
    )
    .bind(ref, manifest.version)
    .first<{ digest: string }>();
  if (version && version.digest !== digest)
    throw new PluginRouteError(
      409,
      "plugin_version_conflict",
      "This version is already registered with different contents",
    );
  if (!version) {
    const versions = await db
      .prepare(
        "SELECT COUNT(*) AS n FROM account_worker_plugin_versions WHERE plugin_ref = ?1",
      )
      .bind(ref)
      .first<{ n: number }>();
    if ((versions?.n ?? 0) >= PLUGIN_VERSION_LIMIT)
      throw new PluginRouteError(
        409,
        "plugin_quota_exceeded",
        `A plugin keeps at most ${PLUGIN_VERSION_LIMIT} versions`,
      );
    await db
      .prepare(
        `INSERT INTO account_worker_plugin_versions
           (plugin_ref, version, manifest_digest, manifest_json, origin_json, signer_json, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      )
      .bind(
        ref,
        manifest.version,
        digest,
        JSON.stringify(manifest),
        JSON.stringify({ kind: origin.kind, locator: origin.locator }),
        signer ? JSON.stringify(signer) : null,
        now,
      )
      .run();
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
  const owned = await db
    .prepare(
      "SELECT 1 AS ok FROM account_worker_plugins WHERE plugin_ref = ?1 AND owner_user_id = ?2",
    )
    .bind(pluginRef, userId)
    .first();
  if (!owned)
    throw new PluginRouteError(404, "plugin_not_found", "Plugin not found");
  const enabled = await db
    .prepare(
      "SELECT 1 AS ok FROM workspace_worker_plugin_enablements WHERE plugin_ref = ?1 AND intent = 'enabled'",
    )
    .bind(pluginRef)
    .first();
  if (enabled)
    throw new PluginRouteError(
      409,
      "plugin_in_use",
      "Disable this plugin on every Workspace first",
    );
  const active = await db
    .prepare(
      `SELECT 1 AS ok FROM worker_assignments
        WHERE worker_type_id = ?1 AND status IN ('created','queued','sent','accepted','running','cancel_requested') LIMIT 1`,
    )
    .bind(pluginRef)
    .first()
    .catch(() => null);
  if (active)
    throw new PluginRouteError(
      409,
      "plugin_in_use",
      "This plugin still has running work",
    );
  const now = new Date().toISOString();
  await db.batch([
    db
      .prepare(
        "DELETE FROM workspace_worker_inventory WHERE worker_type_id = ?1",
      )
      .bind(pluginRef),
    db
      .prepare(
        "UPDATE worker_catalog SET lifecycle_state = 'retired', visibility_state = 'hidden', updated_at = ?2 WHERE worker_type_id = ?1",
      )
      .bind(pluginRef, now),
    db
      .prepare("DELETE FROM account_worker_plugins WHERE plugin_ref = ?1")
      .bind(pluginRef),
  ]);
  return json({ removed: true });
}

/**
 * `PUT|DELETE /api/workspaces/:workspaceId/external-workers/:pluginRef`
 * (also `/worker-plugins/`).
 * Pins one library version on one Workspace the caller owns.
 */
export async function handleWorkspacePluginPin(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  pluginRef: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const userId = context.userId;
  const db = env.SYNTILA_DB;
  const ref = requireRef(pluginRef);
  const workspace = await db
    .prepare(
      "SELECT 1 AS ok FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status != 'revoked'",
    )
    .bind(workspaceId, userId)
    .first();
  if (!workspace) throw new HttpError(404, "Workspace not found");
  const owned = await db
    .prepare(
      "SELECT 1 AS ok FROM account_worker_plugins WHERE plugin_ref = ?1 AND owner_user_id = ?2",
    )
    .bind(ref, userId)
    .first();
  if (!owned)
    throw new PluginRouteError(404, "plugin_not_found", "Plugin not found");

  if (request.method === "DELETE") {
    await db
      .prepare(
        "DELETE FROM workspace_worker_plugin_enablements WHERE workspace_id = ?1 AND plugin_ref = ?2",
      )
      .bind(workspaceId, ref)
      .run();
    return json({ removed: true });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");

  const body = await readBody(request);
  onlyKeys(body, [
    "version",
    "manifestDigest",
    "consentHash",
    "enabled",
    "shareable",
  ]);
  if (
    typeof body.version !== "string" ||
    typeof body.manifestDigest !== "string" ||
    !DIGEST_PATTERN.test(body.manifestDigest) ||
    typeof body.consentHash !== "string" ||
    !DIGEST_PATTERN.test(body.consentHash) ||
    typeof body.enabled !== "boolean" ||
    typeof body.shareable !== "boolean"
  )
    throw new PluginRouteError(400, "invalid_request", "Invalid enablement");
  const version = await db
    .prepare(
      "SELECT manifest_digest AS digest FROM account_worker_plugin_versions WHERE plugin_ref = ?1 AND version = ?2",
    )
    .bind(ref, body.version)
    .first<{ digest: string }>();
  if (!version)
    throw new PluginRouteError(
      404,
      "plugin_not_found",
      "That version is not in your library",
    );
  if (version.digest !== body.manifestDigest)
    throw new PluginRouteError(
      409,
      "plugin_digest_mismatch",
      "The digest differs from the library version",
    );
  await db
    .prepare(
      `INSERT INTO workspace_worker_plugin_enablements
         (workspace_id, plugin_ref, version, manifest_digest, consent_hash, intent, shareable, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
       ON CONFLICT(workspace_id, plugin_ref) DO UPDATE SET
         version = excluded.version,
         manifest_digest = excluded.manifest_digest,
         consent_hash = excluded.consent_hash,
         intent = excluded.intent,
         shareable = excluded.shareable,
         updated_at = excluded.updated_at`,
    )
    .bind(
      workspaceId,
      ref,
      body.version,
      body.manifestDigest,
      body.consentHash,
      body.enabled ? "enabled" : "disabled",
      body.shareable ? 1 : 0,
      new Date().toISOString(),
    )
    .run();
  return json({
    pluginRef: ref,
    version: body.version,
    intent: body.enabled ? "enabled" : "disabled",
  });
}
