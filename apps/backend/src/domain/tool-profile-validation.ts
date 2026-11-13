import {
  validateToolProfileV1,
  type ToolProfileV1,
} from "@syntila/tool-profile";
import { canonicalJson } from "./canonical-json.js";

export class ToolProfileRegistryError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ToolProfileRegistryError";
  }
}
export interface ToolProfileRegistryEnvironment {
  readonly SYNTILA_DB: D1Database;
}

export interface WorkerProfilePublicationEvidence {
  readonly formatVersion: 1;
  readonly workerTypeId: string;
  readonly candidateDigest: string;
  readonly engineVersion: string;
  readonly providerToolName: string;
  readonly providerToolVersion: string;
  readonly testedAt: string;
  readonly scenarios: Readonly<Record<string, "passed" | "not_applicable">>;
}

const acceptanceScenarios = [
  "activity_mapping",
  "passive_probe",
  "usage_check",
] as const;

/**
 * Scenarios Profile Lab must report for a publishable candidate. Every
 * published Profile must declare a usage command, so the usage check always
 * applies; no scenario calls a model. The detected CLI version records test evidence; it does not restrict
 * which CLI versions may use the Profile.
 */
export function toolProfileAcceptanceScenarioStatuses(
  profile: ToolProfileV1,
): Readonly<Record<string, "passed" | "not_applicable">> {
  const activityMappingApplicable =
    profile.execution.output.mode === "jsonl" &&
    (profile.activity?.mappings.length ?? 0) > 0;
  return {
    activity_mapping: activityMappingApplicable ? "passed" : "not_applicable",
    passive_probe: "passed",
    usage_check: "passed",
  };
}

export function validateWorkerProfilePublicationEvidence(
  input: unknown,
  expected: {
    workerTypeId: string;
    candidateDigest: string;
    profile: ToolProfileV1;
  },
): WorkerProfilePublicationEvidence {
  const fail = (): never => {
    throw new ToolProfileRegistryError(
      409,
      "Publication requires complete, recent evidence for this exact Profile candidate",
    );
  };
  if (!expected.profile.usage)
    throw new ToolProfileRegistryError(
      409,
      "Publication requires the Profile to declare a usage command",
    );
  if (!input || typeof input !== "object" || Array.isArray(input))
    return fail();
  const evidence = input as Record<string, unknown>;
  const forbiddenKeys = new Set([
    "secrets",
    "env",
    "environment",
    "stdout",
    "stderr",
    "apiKey",
    "apiKeys",
    "token",
    "tokens",
    "credentials",
  ]);
  if (Object.keys(evidence).some((key) => forbiddenKeys.has(key)))
    throw new ToolProfileRegistryError(
      400,
      "Raw provider secrets, environment dumps, or unrestricted stdout/stderr are forbidden in Cloud evidence",
    );
  const allowedKeys = new Set([
    "formatVersion",
    "workerTypeId",
    "candidateDigest",
    "engineVersion",
    "providerToolName",
    "providerToolVersion",
    "testedAt",
    "scenarios",
  ]);
  if (Object.keys(evidence).some((key) => !allowedKeys.has(key))) return fail();
  const testedAt =
    typeof evidence.testedAt === "string"
      ? Date.parse(evidence.testedAt)
      : Number.NaN;
  if (
    evidence.formatVersion !== 1 ||
    evidence.workerTypeId !== expected.workerTypeId ||
    evidence.candidateDigest !== expected.candidateDigest ||
    typeof evidence.engineVersion !== "string" ||
    evidence.engineVersion.length === 0 ||
    evidence.providerToolName !== expected.profile.providerTool.name ||
    typeof evidence.providerToolVersion !== "string" ||
    evidence.providerToolVersion.length === 0 ||
    !Number.isFinite(testedAt) ||
    testedAt > Date.now() + 5 * 60 * 1000 ||
    Date.now() - testedAt > 90 * 24 * 60 * 60 * 1000 ||
    !evidence.scenarios ||
    typeof evidence.scenarios !== "object" ||
    Array.isArray(evidence.scenarios)
  )
    return fail();
  const scenarios = evidence.scenarios as Record<string, unknown>;
  const expectedStatuses = toolProfileAcceptanceScenarioStatuses(
    expected.profile,
  );
  if (
    Object.keys(scenarios).length !== acceptanceScenarios.length ||
    acceptanceScenarios.some(
      (name) => scenarios[name] !== expectedStatuses[name],
    )
  )
    return fail();
  if (new TextEncoder().encode(JSON.stringify(evidence)).byteLength > 32768)
    return fail();
  return evidence as unknown as WorkerProfilePublicationEvidence;
}

export function validateId(value: string, label: string): void {
  if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(value) || value.length > 96)
    throw new ToolProfileRegistryError(400, label + " is invalid");
}

export function parseProfile(
  input: unknown,
  _compatibilityIdentity?: unknown,
): { profile: ToolProfileV1; payload: string } {
  let profile: ToolProfileV1;
  try {
    profile = validateToolProfileV1(input);
  } catch (error) {
    throw new ToolProfileRegistryError(
      400,
      error instanceof Error ? error.message : "Tool Profile v1 is invalid",
    );
  }
  const payload = canonicalJson(profile);
  if (new TextEncoder().encode(payload).byteLength > 256 * 1024)
    throw new ToolProfileRegistryError(
      400,
      "Tool Profile payload exceeds the Profile limit",
    );
  return { profile, payload };
}

export async function profileDigest(canonicalPayload: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(canonicalPayload),
    ),
  );
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
