#!/usr/bin/env bun
/**
 * Route list: renders the route table (src/domain/routes/table.ts) as
 * Markdown. `bun scripts/routes.ts` prints it; `--write` updates
 * docs/api/ROUTES.md. A test keeps the committed file current.
 */
import { join } from "node:path";
import { routeTable, type WorkerRouteHandlers } from "../src/domain/routes/table";

export const ROUTES_FILE = join(import.meta.dir, "..", "..", "..", "docs", "api", "ROUTES.md");

/** Path -> methods, in table order. */
export function collectRoutes(): Map<string, Set<string>> {
  const routes = new Map<string, Set<string>>();
  for (const route of routeTable({} as WorkerRouteHandlers)) {
    const set = routes.get(route.path) ?? new Set<string>();
    set.add(route.method === "*" ? "ANY" : route.method);
    routes.set(route.path, set);
  }
  return routes;
}

export function renderRoutes(): string {
  const table = routeTable({} as WorkerRouteHandlers);
  const order = ["GET", "POST", "PUT", "PATCH", "DELETE", "ANY"];
  const notes = new Map<string, Set<string>>();
  for (const route of table) {
    const set = notes.get(route.path) ?? new Set<string>();
    if (route.machine) set.add("Connect/server");
    if (route.idempotent) set.add("Idempotency-Key");
    notes.set(route.path, set);
  }
  const rows = [...collectRoutes().entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([path, methods]) => {
      const list = [...methods].sort((a, b) => order.indexOf(a) - order.indexOf(b)).join(", ");
      return `| \`${path}\` | ${list} | ${[...(notes.get(path) ?? [])].join(", ")} |`;
    });
  return [
    "# Backend API routes",
    "",
    "Generated from `apps/backend/src/domain/routes/table.ts` by `bun run routes`. Do not edit by hand.",
    "",
    "`:name` is a path parameter. `ANY` means the handler decides by method itself.",
    "Every JSON error is `{ error, code, requestId }`; every response carries `x-syntila-api`.",
    "A path that exists but not for the request's method answers `405` with an `Allow` header.",
    "`Connect/server`: called with Connect or server credentials, no browser same-origin check.",
    "`Idempotency-Key`: a retry with the same key returns the first response (see CONTRACT.md).",
    "",
    `${rows.length} paths.`,
    "",
    "| Path | Methods | Notes |",
    "| --- | --- | --- |",
    ...rows,
    "",
  ].join("\n");
}

if (import.meta.main) {
  const text = renderRoutes();
  if (Bun.argv.includes("--write")) {
    await Bun.write(ROUTES_FILE, text);
    console.log(`wrote ${ROUTES_FILE}`);
  } else process.stdout.write(text);
}
