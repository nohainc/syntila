/**
 * One way to read a request body: parse JSON, validate it against a schema
 * from @syntila/protocol, and answer 400 with every problem at once.
 */
import type { z } from "zod";
import { HttpError, readBodyText } from "./http-security.js";

export interface ValidationIssue {
  readonly path: string;
  readonly message: string;
}

export class RequestValidationError extends HttpError {
  readonly code = "invalid_request";
  constructor(readonly details: readonly ValidationIssue[]) {
    super(400, details[0]?.message ?? "Invalid request");
  }
}

/** The parsed, validated body. Invalid JSON is `invalid_json`; a schema miss is `invalid_request`. */
export async function readBody<S extends z.ZodType>(request: Request, schema: S): Promise<z.output<S>> {
  let value: unknown;
  try {
    const text = await readBodyText(request);
    value = text.trim() ? JSON.parse(text) : {};
  } catch (error) {
    if (error instanceof HttpError) throw error; // 413
    throw Object.assign(new HttpError(400, "Request body must be valid JSON"), { code: "invalid_json" });
  }
  const result = schema.safeParse(value);
  if (result.success) return result.data;
  throw new RequestValidationError(
    result.error.issues.map((issue) => ({ path: issue.path.map(String).join("."), message: issue.message })),
  );
}

/**
 * A JSON object body without a schema, for handlers that check fields
 * themselves. An empty body is `{}`; invalid JSON is 400 `invalid_json`;
 * anything other than an object (array, string, null) is 400 `invalid_request`.
 * Use this instead of `request.json()`, which turns a malformed body into a 500.
 */
export async function readJson(request: Request): Promise<Record<string, unknown>> {
  let value: unknown;
  try {
    const text = await readBodyText(request);
    value = text.trim() ? JSON.parse(text) : {};
  } catch (error) {
    if (error instanceof HttpError) throw error; // 413
    throw Object.assign(new HttpError(400, "Request body must be valid JSON"), { code: "invalid_json" });
  }
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new RequestValidationError([{ path: "", message: "Request body must be a JSON object" }]);
  return value as Record<string, unknown>;
}
