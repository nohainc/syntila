/** Canonical permissions carried by a Cloud assignment to Connect. */
export const EXECUTION_PERMISSIONS = [
  "repository:read",
  "repository:write",
  "shell:execute",
  "network:use",
] as const;

export type ExecutionPermission = (typeof EXECUTION_PERMISSIONS)[number];

export function isExecutionPermission(
  value: unknown,
): value is ExecutionPermission {
  return (
    typeof value === "string" &&
    (EXECUTION_PERMISSIONS as readonly string[]).includes(value)
  );
}
