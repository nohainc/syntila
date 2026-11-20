/**
 * Artifact outputs a Workflow step declares (ADR-037). Only files directly in
 * the step's output folder whose name matches a declared pattern leave the Agent
 * as artifacts; a step that declares none produces none. A pattern is one file
 * name of letters, digits, `.`, `_` and `-` (the characters an artifact name
 * keeps), with at most one `*`.
 */
export const MAX_ARTIFACT_OUTPUTS = 8;
const MAX_PATTERN_LENGTH = 100;

export function validArtifactOutputPattern(pattern: string): boolean {
  if (pattern.length === 0 || pattern.length > MAX_PATTERN_LENGTH) return false;
  if (!/^[A-Za-z0-9._*-]+$/.test(pattern)) return false;
  if ((pattern.match(/\*/g) ?? []).length > 1) return false;
  return pattern !== "." && pattern !== "..";
}

/** The valid patterns of a declaration (at most [MAX_ARTIFACT_OUTPUTS]); anything else is dropped. */
export function normalizeArtifactOutputs(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  for (const item of value) {
    if (typeof item === "string" && validArtifactOutputPattern(item)) seen.add(item);
    if (seen.size >= MAX_ARTIFACT_OUTPUTS) break;
  }
  return [...seen];
}

export function artifactOutputMatches(patterns: readonly string[], name: string): boolean {
  return patterns.some((pattern) => {
    if (!validArtifactOutputPattern(pattern)) return false;
    const star = pattern.indexOf("*");
    if (star < 0) return pattern === name;
    const head = pattern.slice(0, star);
    const tail = pattern.slice(star + 1);
    return name.length >= head.length + tail.length && name.startsWith(head) && name.endsWith(tail);
  });
}
