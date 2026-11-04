import type { PluginManifest } from "@syntila/workspace-runtime-protocol";
import { canonicalJson } from "./canonical-json.js";

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
