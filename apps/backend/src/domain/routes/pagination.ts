/**
 * One pagination shape for list endpoints:
 *   request:  ?limit=N&cursor=<opaque>
 *   response: { <items>: [...], nextCursor: string | null }
 * A cursor points after the last item of the previous page (newest first,
 * ordered by a timestamp and then the id). Clients pass it back unchanged.
 */
import { HttpError } from "./http-security.js";

export interface PagePosition {
  /** Timestamp of the last item on the previous page (ISO 8601). */
  readonly at: string;
  readonly id: string;
}

export interface PageRequest {
  readonly limit: number;
  readonly after: PagePosition | null;
}

export function encodeCursor(position: PagePosition): string {
  return Buffer.from(JSON.stringify([position.at, position.id])).toString("base64url");
}

export function decodeCursor(cursor: string): PagePosition {
  try {
    if (cursor.length > 512) throw new Error("too long");
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    if (Array.isArray(value) && value.length === 2 && typeof value[0] === "string" && typeof value[1] === "string" && !Number.isNaN(Date.parse(value[0])))
      return { at: value[0], id: value[1] };
  } catch {
    // fall through
  }
  throw Object.assign(new HttpError(400, "cursor is not valid"), { code: "invalid_cursor" });
}

export function pageRequest(url: URL, options: { defaultLimit: number; maxLimit: number }): PageRequest {
  const raw = url.searchParams.get("limit");
  const limit = raw === null || raw === "" ? options.defaultLimit : Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > options.maxLimit)
    throw new HttpError(400, `limit must be between 1 and ${options.maxLimit}`);
  const cursor = url.searchParams.get("cursor");
  return { limit, after: cursor ? decodeCursor(cursor) : null };
}

/**
 * Splits the rows of a query that asked for `limit + 1` into the page and the
 * cursor for the next one.
 */
export function pageOf<T>(rows: readonly T[], limit: number, position: (row: T) => PagePosition) {
  const items = rows.slice(0, limit);
  const last = items[items.length - 1];
  return { items, nextCursor: rows.length > limit && last !== undefined ? encodeCursor(position(last)) : null };
}

/**
 * Timestamps reach clients with millisecond precision while PostgreSQL keeps
 * microseconds, so cursor ordering and comparison use milliseconds; the id
 * breaks ties. Use both helpers in one query.
 */
const ms = (column: string) => `date_trunc('milliseconds', ${column})`;

/** SQL condition: after the cursor in `cursorOrderSql` order. */
export function afterCursorSql(atColumn: string, idColumn: string, atParam: number, idParam: number): string {
  return `(${ms(atColumn)} < ?${atParam}::timestamptz OR (${ms(atColumn)} = ?${atParam}::timestamptz AND ${idColumn} < ?${idParam}))`;
}

/** ORDER BY clause body matching `afterCursorSql`: newest first. */
export function cursorOrderSql(atColumn: string, idColumn: string): string {
  return `${ms(atColumn)} DESC, ${idColumn} DESC`;
}
