import {
  PLUGIN_LEASE_CLOCK_SKEW_MS,
  PLUGIN_LEASE_MAX_TTL_MS,
  PluginEntitlementLeaseEnvelopeSchema,
  PluginEntitlementLeaseSchema,
  type PluginEntitlementLease,
  type PluginEntitlementLeaseEnvelope,
  type PluginManifest,
} from "@syntila/workspace-runtime-protocol";
import { canonicalJson } from "./canonical-json.js";
import {
  signEd25519ReleaseMessage,
  verifyEd25519ReleaseSignature,
} from "./release-trust.js";

/** Trust-key publisher name for entitlement leases (separate from releases). */
export const ENTITLEMENT_TRUST_PUBLISHER = "entitlement";

/** Digest that pins a plugin: sha256 of the canonical manifest JSON. */
export async function pluginManifestDigest(
  manifest: PluginManifest,
): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalJson(manifest));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

/**
 * Signs a lease. Cloud only calls this after `requirePaidFeature` for the
 * Workspace owner; `expiresAt` is clamped to the 24 h ceiling and to the plan's
 * period end so offline grace never outlives the subscription.
 */
export function issuePluginEntitlementLease(args: {
  privateKeyBase64OrPem: string;
  claims: Omit<PluginEntitlementLease, "v" | "feature" | "expiresAt"> & {
    expiresAt?: string;
  };
  now: Date;
}): PluginEntitlementLeaseEnvelope {
  const ceiling = +args.now + PLUGIN_LEASE_MAX_TTL_MS;
  const periodEnd = args.claims.planPeriodEnd
    ? Date.parse(args.claims.planPeriodEnd)
    : Infinity;
  const requested = args.claims.expiresAt
    ? Date.parse(args.claims.expiresAt)
    : Infinity;
  const expires = Math.min(ceiling, periodEnd, requested);
  if (!(expires > +args.now))
    throw new Error("Entitlement lease would already be expired");
  const lease = PluginEntitlementLeaseSchema.parse({
    ...args.claims,
    v: 1,
    feature: "workers.custom_plugins",
    expiresAt: new Date(expires).toISOString(),
  });
  return {
    lease,
    signature: signEd25519ReleaseMessage({
      privateKeyBase64OrPem: args.privateKeyBase64OrPem,
      message: canonicalJson(lease),
    }),
  };
}

export type PluginLeaseRejection =
  | "malformed"
  | "signature_invalid"
  | "ttl_invalid"
  | "expired"
  | "binding_mismatch"
  | "entitlement_clock_invalid";

/**
 * Reference verifier for the lease contract. The Dart Service implements the
 * same rules; this is the executable specification and the Cloud-side check.
 */
export async function verifyPluginEntitlementLease(args: {
  envelope: unknown;
  trustKeysJson: string | undefined;
  expected: {
    ownerUserId: string;
    workspaceId: string;
    installationId: string;
  };
  now: Date;
  /** Highest Cloud time previously seen by this installation. */
  highWaterMark?: Date | null;
}): Promise<
  | { ok: true; lease: PluginEntitlementLease }
  | { ok: false; reason: PluginLeaseRejection }
> {
  const parsed = PluginEntitlementLeaseEnvelopeSchema.safeParse(args.envelope);
  if (!parsed.success) return { ok: false, reason: "malformed" };
  const { lease, signature } = parsed.data;
  const signed = await verifyEd25519ReleaseSignature({
    ...(args.trustKeysJson ? { trustKeysJson: args.trustKeysJson } : {}),
    publisher: ENTITLEMENT_TRUST_PUBLISHER,
    signingKeyId: lease.kid,
    signature,
    message: canonicalJson(lease),
  });
  if (!signed) return { ok: false, reason: "signature_invalid" };
  const issued = Date.parse(lease.issuedAt);
  const expires = Date.parse(lease.expiresAt);
  if (!(expires > issued) || expires - issued > PLUGIN_LEASE_MAX_TTL_MS)
    return { ok: false, reason: "ttl_invalid" };
  if (
    lease.ownerUserId !== args.expected.ownerUserId ||
    lease.workspaceId !== args.expected.workspaceId ||
    lease.installationId !== args.expected.installationId
  )
    return { ok: false, reason: "binding_mismatch" };
  const mark = Math.max(
    issued,
    args.highWaterMark ? +args.highWaterMark : -Infinity,
  );
  if (+args.now < mark - PLUGIN_LEASE_CLOCK_SKEW_MS)
    return { ok: false, reason: "entitlement_clock_invalid" };
  if (+args.now >= expires) return { ok: false, reason: "expired" };
  if (lease.planPeriodEnd && +args.now >= Date.parse(lease.planPeriodEnd))
    return { ok: false, reason: "expired" };
  return { ok: true, lease };
}
