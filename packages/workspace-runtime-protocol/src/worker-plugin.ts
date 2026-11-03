import { z } from "zod";

/**
 * Worker plugin contracts (ADR-027). The manifest is the public, versioned
 * description of a user-imported plugin; it is not a Tool Profile. The
 * entitlement lease is the Cloud-signed, short-lived statement the Workspace
 * Service uses for offline decisions. Cloud scheduling remains authoritative.
 */

export const WORKER_PLUGIN_PAID_FEATURE = "workers.custom_plugins" as const;
export const WORKER_PLUGIN_MANIFEST_SCHEMA_VERSION = 1 as const;
export const WORKER_PLUGIN_PROTOCOL_MAJOR = 1 as const;
export const WORKER_PLUGIN_ID_PREFIX = "plugin-" as const;
/** Longest lease Cloud may issue; also the offline grace ceiling. */
export const PLUGIN_LEASE_MAX_TTL_MS = 24 * 60 * 60 * 1000;
/** Running work may finish this long after an entitlement lapse. */
export const PLUGIN_LAPSE_DRAIN_MAX_MS = 30 * 60 * 1000;
/** Local clock may trail the highest Cloud time seen by at most this much. */
export const PLUGIN_LEASE_CLOCK_SKEW_MS = 5 * 60 * 1000;
export const WORKER_PLUGIN_MAX_ARTIFACT_BYTES = 256 * 1024 * 1024;

const sha256Hex = z.string().regex(/^[0-9a-f]{64}$/);

export const PluginIdSchema = z
  .string()
  .max(48)
  .regex(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/);

/** Cloud-allocated Worker Type ID: `plugin-` plus 12 lowercase hex. */
export const PluginRefSchema = z.string().regex(/^plugin-[0-9a-f]{12}$/);

export const PluginVersionSchema = z
  .string()
  .max(64)
  .regex(/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/);

export const PluginPlatformSchema = z.enum([
  "darwin-arm64",
  "darwin-x64",
  "linux-x64",
  "linux-arm64",
  "windows-x64",
  "any",
]);

/** Relative, normalized path inside the package; no traversal or drive. */
const packagePath = z
  .string()
  .min(1)
  .max(256)
  .refine(
    (value) =>
      !value.includes("\0") &&
      !value.startsWith("/") &&
      !value.startsWith("\\") &&
      !/^[A-Za-z]:/.test(value) &&
      !value.split(/[\\/]/).some((part) => part === ".." || part === ""),
    { message: "must be a relative path inside the package" },
  );

const PluginArtifactSchema = z
  .object({
    command: packagePath,
    args: z.array(z.string().max(256)).max(32),
    sha256: sha256Hex,
    size: z.number().int().positive().max(WORKER_PLUGIN_MAX_ARTIFACT_BYTES),
  })
  .strict();

const protocolVersion = z.string().regex(/^1\.(0|[1-9]\d*)$/);

const envName = z
  .string()
  .regex(/^[A-Z][A-Z0-9_]{0,63}$/)
  .refine((name) => !name.startsWith("SYNTILA_"), {
    message: "SYNTILA_* variables are reserved",
  });

export const PluginManifestSchema = z
  .object({
    schemaVersion: z.literal(WORKER_PLUGIN_MANIFEST_SCHEMA_VERSION),
    pluginId: PluginIdSchema,
    version: PluginVersionSchema,
    displayName: z.string().min(1).max(128),
    description: z.string().max(512),
    author: z
      .object({
        name: z.string().min(1).max(128),
        contact: z.string().max(256).optional(),
      })
      .strict(),
    protocol: z
      .object({ min: protocolVersion, max: protocolVersion })
      .strict()
      .refine(
        (range) =>
          Number(range.min.split(".")[1]) <= Number(range.max.split(".")[1]),
        { message: "protocol.min must not exceed protocol.max" },
      ),
    artifacts: z
      .partialRecord(PluginPlatformSchema, PluginArtifactSchema)
      .refine((artifacts) => Object.keys(artifacts).length > 0, {
        message: "at least one platform artifact is required",
      }),
    capabilities: z
      .object({
        progress: z.boolean().optional(),
        activity: z.boolean().optional(),
        sessionResume: z.boolean().optional(),
        readOnly: z.enum(["honors", "never"]).optional(),
      })
      .strict(),
    access: z
      .object({
        workRoot: z.enum(["none", "read", "write"]),
        network: z.discriminatedUnion("mode", [
          z.object({ mode: z.literal("none") }).strict(),
          z
            .object({
              mode: z.literal("declared"),
              hosts: z.array(z.string().min(1).max(253)).min(1).max(16),
            })
            .strict(),
        ]),
        subprocess: z.boolean(),
        env: z.array(envName).max(16),
      })
      .strict(),
    limits: z
      .object({
        maxConcurrent: z.number().int().min(1).max(4).optional(),
        memoryMiB: z.number().int().min(64).max(8192).optional(),
      })
      .strict()
      .optional(),
    requires: z
      .array(
        z
          .object({
            tool: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/),
            minVersion: z.string().max(64).optional(),
          })
          .strict(),
      )
      .max(8)
      .optional(),
    license: z.string().max(64).optional(),
    homepage: z
      .url({ protocol: /^https$/ })
      .max(512)
      .optional(),
  })
  .strict();
export type PluginManifest = z.infer<typeof PluginManifestSchema>;

const timestamp = z.iso.datetime();

/** Claims signed by Cloud. The signature covers canonical JSON of these. */
export const PluginEntitlementLeaseSchema = z
  .object({
    v: z.literal(1),
    kid: z.string().min(1).max(64),
    feature: z.literal(WORKER_PLUGIN_PAID_FEATURE),
    ownerUserId: z.string().min(1).max(128),
    workspaceId: z.string().min(1).max(128),
    installationId: z.string().min(1).max(128),
    leaseId: z.string().min(1).max(128),
    issuedAt: timestamp,
    expiresAt: timestamp,
    planStatus: z.enum(["active", "trialing", "past_due"]),
    planPeriodEnd: timestamp.nullable(),
  })
  .strict();
export type PluginEntitlementLease = z.infer<
  typeof PluginEntitlementLeaseSchema
>;

export const PluginEntitlementLeaseEnvelopeSchema = z
  .object({
    lease: PluginEntitlementLeaseSchema,
    /** Base64 Ed25519 signature over canonical JSON of `lease`. */
    signature: z.string().min(1).max(256),
  })
  .strict();
export type PluginEntitlementLeaseEnvelope = z.infer<
  typeof PluginEntitlementLeaseEnvelopeSchema
>;
