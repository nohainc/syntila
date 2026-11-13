import { canonicalJson } from "../canonical-json.js";
import { verifyEd25519ReleaseSignature } from "../release-trust.js";
import { computePackageDigest } from "@syntila/security";
import { compareSemver } from "@syntila/tool-profile";
import {
  HttpError,
  authorizeRequest,
  authorizeToolProfileAdmin,
  json,
  parseJson,
  testAuthenticationEnabled,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

// =========================================================================
// Workspace Release API Handlers
// =========================================================================

export async function handleGetLatestWorkspaceRelease(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const url = new URL(request.url);
  const channel = url.searchParams.get("channel") || "stable";
  const os = url.searchParams.get("os");
  const arch = url.searchParams.get("arch");
  const currentVersion = url.searchParams.get("currentVersion");

  const rows = await env.SYNTILA_DB.prepare(
    `SELECT version, channel, min_supported_workspace_version as minSupportedWorkspaceVersion,
            supported_os_json as supportedOsJson, supported_arch_json as supportedArchJson,
            package_digest as packageDigest, package_r2_key as packageR2Key,
            signature, signing_key_id as signingKeyId, release_notes as releaseNotes, is_revoked as isRevoked,
            created_at as createdAt
     FROM workspace_releases
     WHERE channel = ?1 AND is_revoked = 0 AND signing_key_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM release_signing_key_revocations revoked
         WHERE revoked.key_id = workspace_releases.signing_key_id
       )
     ORDER BY created_at DESC`,
  )
    .bind(channel)
    .all<{
      version: string;
      channel: string;
      minSupportedWorkspaceVersion: string | null;
      supportedOsJson: string;
      supportedArchJson: string;
      packageDigest: string;
      packageR2Key: string;
      signature: string;
      signingKeyId: string | null;
      releaseNotes: string | null;
      isRevoked: number;
      createdAt: string;
    }>();

  const releases = (rows.results ?? []).filter((r) => {
    if (os) {
      const supportedOS = parseJson<string[]>(r.supportedOsJson, []);
      if (!supportedOS.includes(os)) return false;
    }
    if (arch) {
      const supportedArch = parseJson<string[]>(r.supportedArchJson, []);
      if (!supportedArch.includes(arch)) return false;
    }
    return true;
  });

  releases.sort((a, b) => compareSemver(b.version, a.version));

  const latest = releases[0];
  if (!latest) {
    return json({ updateAvailable: false, release: null });
  }

  const updateAvailable = currentVersion
    ? compareSemver(latest.version, currentVersion) > 0
    : true;

  return json({
    updateAvailable,
    release: {
      version: latest.version,
      channel: latest.channel,
      minSupportedWorkspaceVersion: latest.minSupportedWorkspaceVersion,
      supportedOS: parseJson<string[]>(latest.supportedOsJson, []),
      supportedArch: parseJson<string[]>(latest.supportedArchJson, []),
      packageDigest: latest.packageDigest,
      packageR2Key: latest.packageR2Key,
      signingKeyId: latest.signingKeyId,
      // Workspace releases use the Cloud-managed signing identity. Keep the
      // publisher explicit so Workspace can apply its trust policy rather than
      // treating a missing publisher as an unsigned release.
      publisher: "syntila",
      signature: latest.signature,
      releaseNotes: latest.releaseNotes,
      createdAt: latest.createdAt,
    },
  });
}

export async function handleGetWorkspaceRelease(
  env: SecurityEnv,
  version: string,
): Promise<Response> {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT version, channel, min_supported_workspace_version as minSupportedWorkspaceVersion,
            supported_os_json as supportedOsJson, supported_arch_json as supportedArchJson,
            package_digest as packageDigest, package_r2_key as packageR2Key,
            signature, signing_key_id as signingKeyId, release_notes as releaseNotes, is_revoked as isRevoked,
            revoked_at as revokedAt, revocation_reason as revocationReason,
            created_at as createdAt
     FROM workspace_releases WHERE version = ?1`,
  )
    .bind(version)
    .first<{
      version: string;
      channel: string;
      minSupportedWorkspaceVersion: string | null;
      supportedOsJson: string;
      supportedArchJson: string;
      packageDigest: string;
      packageR2Key: string;
      signature: string;
      signingKeyId: string | null;
      releaseNotes: string | null;
      isRevoked: number;
      revokedAt: string | null;
      revocationReason: string | null;
      createdAt: string;
    }>();

  if (!row) {
    return json(
      { error: `Workspace release '${version}' not found` },
      { status: 404 },
    );
  }

  return json({
    version: row.version,
    channel: row.channel,
    minSupportedWorkspaceVersion: row.minSupportedWorkspaceVersion,
    supportedOS: parseJson<string[]>(row.supportedOsJson, []),
    supportedArch: parseJson<string[]>(row.supportedArchJson, []),
    packageDigest: row.packageDigest,
    packageR2Key: row.packageR2Key,
    signature: row.signature,
    signingKeyId: row.signingKeyId,
    releaseNotes: row.releaseNotes,
    isRevoked: Boolean(row.isRevoked),
    revokedAt: row.revokedAt,
    revocationReason: row.revocationReason,
    createdAt: row.createdAt,
  });
}

export async function handleDownloadWorkspaceRelease(
  request: Request,
  env: SecurityEnv,
  version: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (!testAuthenticationEnabled(env)) {
    await authorizeRequest(
      request,
      env,
      "profiles:release:manage",
      undefined,
      ctx,
    );
  }
  const row = await env.SYNTILA_DB.prepare(
    `SELECT package_r2_key, package_digest, is_revoked, revocation_reason,
            signing_key_id as signingKeyId FROM workspace_releases WHERE version = ?1`,
  )
    .bind(version)
    .first<{
      package_r2_key: string;
      package_digest: string;
      is_revoked: number;
      revocation_reason: string | null;
      signingKeyId: string | null;
    }>();

  if (!row) {
    return json(
      { error: `Workspace release '${version}' not found` },
      { status: 404 },
    );
  }

  if (row.is_revoked || row.signingKeyId == null) {
    return json(
      {
        error: `Workspace release '${version}' has been revoked`,
        revocationReason: row.revocation_reason || "Security revocation",
      },
      { status: 410 },
    );
  }

  const revokedKey = await env.SYNTILA_DB.prepare(
    "SELECT key_id FROM release_signing_key_revocations WHERE key_id = ?1",
  )
    .bind(row.signingKeyId)
    .first();
  if (revokedKey) {
    return json(
      { error: `Workspace release '${version}' signing key is revoked` },
      { status: 410 },
    );
  }

  const bucket =
    (env as unknown as { SYNTILA_STORAGE?: R2Bucket }).SYNTILA_STORAGE ??
    env.SYNTILA_ARTIFACTS;
  if (!bucket) {
    return json({ error: "Storage bucket not configured" }, { status: 500 });
  }

  const object = await bucket.get(row.package_r2_key);
  if (!object) {
    return json(
      { error: "Workspace package file not found in storage" },
      { status: 404 },
    );
  }

  const headers = new Headers();
  headers.set("Content-Type", "application/octet-stream");
  headers.set("content-digest", row.package_digest);
  headers.set("ETag", object.httpEtag);
  headers.set(
    "Content-Disposition",
    `attachment; filename="syntila-workspace-${version}.tar.gz"`,
  );

  return new Response(object.body, { headers });
}

export async function handlePublishWorkspaceRelease(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeToolProfileAdmin(request, env, ctx, "profiles:release:manage");

  let version = "";
  let channel: "stable" | "beta" | "development" = "stable";
  let minSupportedWorkspaceVersion: string | null = null;
  let supportedOS: string[] = ["macos", "linux", "windows"];
  let supportedArch: string[] = ["arm64", "x64"];
  let releaseNotes: string | null = null;
  let packageData: ArrayBuffer | null = null;
  let providedDigest: string | null = null;
  let providedSignature: string | null = null;
  let signingKeyId: string | null = null;

  const contentType = request.headers.get("content-type") || "";
  if (contentType.includes("multipart/form-data")) {
    const formData = await request.formData();
    const versionVal = formData.get("version");
    if (!versionVal || typeof versionVal !== "string") {
      return json({ error: "'version' is required" }, { status: 400 });
    }
    version = versionVal.trim();
    const chanVal = formData.get("channel");
    if (
      chanVal === "beta" ||
      chanVal === "development" ||
      chanVal === "stable"
    ) {
      channel = chanVal;
    }
    const minVer = formData.get("minSupportedWorkspaceVersion");
    if (minVer && typeof minVer === "string")
      minSupportedWorkspaceVersion = minVer;
    const osVal = formData.get("supportedOS");
    if (osVal && typeof osVal === "string") {
      supportedOS = parseJson<string[]>(osVal, supportedOS);
    }
    const archVal = formData.get("supportedArch");
    if (archVal && typeof archVal === "string") {
      supportedArch = parseJson<string[]>(archVal, supportedArch);
    }
    const notes = formData.get("releaseNotes");
    if (notes && typeof notes === "string") releaseNotes = notes;
    const dig = formData.get("packageDigest");
    if (dig && typeof dig === "string") providedDigest = dig;
    const sig = formData.get("signature");
    if (sig && typeof sig === "string") providedSignature = sig;
    const keyId = formData.get("signingKeyId");
    if (keyId && typeof keyId === "string") signingKeyId = keyId;

    const file = formData.get("package");
    if (file && typeof file === "object" && "arrayBuffer" in file) {
      packageData = await (file as Blob).arrayBuffer();
    }
  } else {
    const body = (await request.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;
    if (!body.version || typeof body.version !== "string") {
      return json({ error: "'version' is required" }, { status: 400 });
    }
    version = body.version.trim();
    if (
      body.channel === "beta" ||
      body.channel === "development" ||
      body.channel === "stable"
    ) {
      channel = body.channel;
    }
    if (typeof body.minSupportedWorkspaceVersion === "string") {
      minSupportedWorkspaceVersion = body.minSupportedWorkspaceVersion;
    }
    if (Array.isArray(body.supportedOS))
      supportedOS = body.supportedOS as string[];
    if (Array.isArray(body.supportedArch))
      supportedArch = body.supportedArch as string[];
    if (typeof body.releaseNotes === "string") releaseNotes = body.releaseNotes;
    if (typeof body.packageDigest === "string")
      providedDigest = body.packageDigest;
    if (typeof body.signature === "string") providedSignature = body.signature;
    if (typeof body.signingKeyId === "string") signingKeyId = body.signingKeyId;
    if (typeof body.packageBase64 === "string") {
      packageData = Uint8Array.from(atob(body.packageBase64), (c) =>
        c.charCodeAt(0),
      ).buffer;
    }
  }

  if (!packageData) {
    return json(
      { error: "Package binary archive is required" },
      { status: 400 },
    );
  }

  const computedDigest = await computePackageDigest(packageData);
  if (providedDigest && providedDigest !== computedDigest) {
    return json(
      {
        error: `Package digest mismatch. Provided: ${providedDigest}, computed: ${computedDigest}`,
      },
      { status: 400 },
    );
  }
  const digest = computedDigest;

  const publisher = env.SYNTILA_RELEASE_PUBLISHER ?? "syntila";
  if (!signingKeyId || !providedSignature) {
    return json(
      { error: "signingKeyId and signature are required" },
      { status: 400 },
    );
  }
  const revokedSigningKey = await env.SYNTILA_DB.prepare(
    "SELECT key_id FROM release_signing_key_revocations WHERE key_id = ?1",
  )
    .bind(signingKeyId)
    .first();
  const signedMetadata = {
    version,
    channel,
    minSupportedWorkspaceVersion: minSupportedWorkspaceVersion,
    supportedOS,
    supportedArch,
    releaseNotes,
    publisher,
    signingKeyId,
    packageDigest: digest,
  };
  if (
    revokedSigningKey ||
    !(await verifyEd25519ReleaseSignature({
      trustKeysJson: env.SYNTILA_RELEASE_TRUST_KEYS_JSON,
      publisher,
      signingKeyId,
      signature: providedSignature,
      message: `syntila-workspace-release-metadata-v1\n${canonicalJson(signedMetadata)}`,
    }))
  ) {
    return json(
      { error: "Workspace release signature is invalid or revoked" },
      { status: 400 },
    );
  }
  const signature = providedSignature;

  const previous = await env.SYNTILA_DB.prepare(
    "SELECT package_digest, signature, signing_key_id FROM workspace_releases WHERE version = ?1",
  )
    .bind(version)
    .first<{
      package_digest: string;
      signature: string;
      signing_key_id: string | null;
    }>();
  if (previous) {
    if (
      previous.package_digest === digest &&
      previous.signature === signature &&
      previous.signing_key_id === signingKeyId
    ) {
      return json({
        version,
        channel,
        packageDigest: digest,
        signature,
        signingKeyId,
        status: "already_published",
      });
    }
    return json(
      { error: "Workspace release version is immutable" },
      { status: 409 },
    );
  }

  const bucket =
    (env as unknown as { SYNTILA_STORAGE?: R2Bucket }).SYNTILA_STORAGE ??
    env.SYNTILA_ARTIFACTS;
  if (!bucket) {
    return json({ error: "Storage bucket not configured" }, { status: 500 });
  }

  const r2Key = `workspace/releases/${version}/workspace-${version}.tar.gz`;
  await bucket.put(r2Key, packageData, {
    httpMetadata: {
      contentType: "application/octet-stream",
    },
    customMetadata: {
      version,
      channel,
      packageDigest: digest,
      signature,
    },
  });

  const now = new Date().toISOString();
  await env.SYNTILA_DB.prepare(
    `INSERT INTO workspace_releases (
       version, channel, min_supported_workspace_version, supported_os_json,
       supported_arch_json, package_digest, package_r2_key, signature, signing_key_id,
       release_notes, is_revoked, created_at
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 0, ?11)`,
  )
    .bind(
      version,
      channel,
      minSupportedWorkspaceVersion,
      JSON.stringify(supportedOS),
      JSON.stringify(supportedArch),
      digest,
      r2Key,
      signature,
      signingKeyId,
      releaseNotes,
      now,
    )
    .run();

  return json(
    {
      version,
      channel,
      packageDigest: digest,
      packageR2Key: r2Key,
      signature,
      signingKeyId,
      status: "published",
      publishedAt: now,
    },
    { status: 201 },
  );
}

export async function handleRevokeWorkspaceRelease(
  request: Request,
  env: SecurityEnv,
  version: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeToolProfileAdmin(request, env, ctx, "profiles:release:manage");

  const body = (await request.json().catch(() => ({}))) as { reason?: string };
  const reason = body.reason || "Revoked by administrator";
  const now = new Date().toISOString();

  await env.SYNTILA_DB.prepare(
    `UPDATE workspace_releases
     SET is_revoked = 1, revoked_at = ?1, revocation_reason = ?2
     WHERE version = ?3`,
  )
    .bind(now, reason, version)
    .run();

  return json({
    version,
    isRevoked: true,
    revokedAt: now,
    revocationReason: reason,
  });
}

export async function handleGetReleaseTrustState(
  env: SecurityEnv,
): Promise<Response> {
  const [keys, workspaceReleases] = await Promise.all([
    env.SYNTILA_DB.prepare(
      "SELECT key_id FROM release_signing_key_revocations ORDER BY key_id",
    ).all<{ key_id: string }>(),
    env.SYNTILA_DB.prepare(
      "SELECT version, package_digest FROM workspace_releases WHERE is_revoked = 1",
    ).all<{ version: string; package_digest: string }>(),
  ]);
  return json({
    revokedKeyIds: (keys.results ?? []).map((row) => row.key_id),
    // Workspaces refresh this list before accepting or activating app releases.
    revokedWorkspaceReleases: (workspaceReleases.results ?? []).map((row) => ({
      version: row.version,
      packageDigest: row.package_digest,
    })),
  });
}

export async function handleRevokeReleaseSigningKey(
  request: Request,
  env: SecurityEnv,
  keyId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(keyId)) {
    throw new HttpError(400, "release signing key ID is invalid");
  }
  const actor = await authorizeToolProfileAdmin(
    request,
    env,
    ctx,
    "profiles:release:manage",
  );
  const body = (await request.json().catch(() => ({}))) as { reason?: unknown };
  const reason =
    typeof body.reason === "string" ? body.reason.trim().slice(0, 500) : "";
  if (!reason) throw new HttpError(400, "revocation reason is required");
  const now = new Date().toISOString();
  await env.SYNTILA_DB.prepare(
    `INSERT INTO release_signing_key_revocations (key_id, revoked_at, revoked_by_user_id, reason)
     VALUES (?1, ?2, ?3, ?4) ON CONFLICT(key_id) DO NOTHING`,
  )
    .bind(keyId, now, actor.userId, reason)
    .run();
  return json({ keyId, isRevoked: true, revokedAt: now });
}
