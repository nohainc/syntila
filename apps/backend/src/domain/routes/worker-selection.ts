import { HttpError } from "./http-security.js";

/** A person's choice of Worker, model and effort for one Step (`{implementer, verifier}` of an Implement plan). */
export interface WorkflowExecutionSelectionOverride {
  readonly workerId?: string | null;
  readonly model?: string | null;
  readonly reasoningEffort?: string | null;
  readonly catalogRevision?: string | null;
}

export function parseWorkflowExecutionSelection(
  value: unknown,
): WorkflowExecutionSelectionOverride | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "executionSelection must be an object");
  const object = value as Record<string, unknown>;
  if (
    Object.keys(object).some(
      (key) =>
        !["workerId", "model", "reasoningEffort", "catalogRevision"].includes(
          key,
        ),
    )
  )
    throw new HttpError(400, "executionSelection contains an unknown field");
  const stringOrNull = (key: string): string | null | undefined => {
    const selected = object[key];
    if (selected === undefined || selected === null) return selected as null | undefined;
    if (typeof selected !== "string" || selected.trim().length === 0)
      throw new HttpError(400, `executionSelection.${key} is invalid`);
    if (selected.length > 200)
      throw new HttpError(400, `executionSelection.${key} is too long`);
    if (key === "catalogRevision" && !/^[a-f0-9]{64}$/.test(selected))
      throw new HttpError(400, "executionSelection.catalogRevision is invalid");
    if (selected === "Auto" || selected === "Automatic") {
      if (key === "workerId")
        throw new HttpError(400, "Worker must be selected explicitly");
      if (selected === "Automatic")
        throw new HttpError(400, "Use Auto for model and effort defaults");
      return null;
    }
    return selected.trim();
  };
  return {
    ...(Object.hasOwn(object, "catalogRevision")
      ? { catalogRevision: stringOrNull("catalogRevision") }
      : {}),
    ...(Object.hasOwn(object, "workerId")
      ? { workerId: stringOrNull("workerId") }
      : {}),
    ...(Object.hasOwn(object, "model") ? { model: stringOrNull("model") } : {}),
    ...(Object.hasOwn(object, "reasoningEffort")
      ? { reasoningEffort: stringOrNull("reasoningEffort") }
      : {}),
  };
}
