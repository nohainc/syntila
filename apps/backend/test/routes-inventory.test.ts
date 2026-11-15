import { expect, test } from "bun:test";
import { collectRoutes, renderRoutes, ROUTES_FILE } from "../scripts/routes";
import { findRoute, matchPath, routeTable, type WorkerRouteHandlers } from "../src/domain/routes/table";

const routes = routeTable({} as WorkerRouteHandlers);

test("docs/api/ROUTES.md is generated from the route table (run `bun run routes` after changing routes)", async () => {
  expect(await Bun.file(ROUTES_FILE).text()).toBe(renderRoutes());
});

test("the table has the main resources", () => {
  const all = collectRoutes();
  expect([...all.get("/api/spaces")!].sort()).toEqual(["GET", "POST"]);
  expect([...all.get("/api/spaces/:spaceId")!].sort()).toEqual(["DELETE", "GET", "PATCH"]);
  expect(all.size).toBeGreaterThan(100);
});

test("no two routes have the same method and path", () => {
  const seen = new Set<string>();
  for (const route of routes) {
    const key = `${route.method} ${route.path}`;
    expect(seen.has(key)).toBe(false);
    seen.add(key);
  }
});

test("a literal path is listed before a parameter path that would also match it", () => {
  // Otherwise the literal route could never be reached.
  routes.forEach((route, index) => {
    if (route.segments.some((s) => s.startsWith(":"))) return;
    const shadow = routes.slice(0, index).find((earlier) =>
      (earlier.method === route.method || earlier.method === "*") && matchPath(earlier, route.path));
    expect(shadow ? `${route.method} ${route.path} is shadowed by ${shadow.method} ${shadow.path}` : null).toBeNull();
  });
});

test("matching decodes parameters and refuses empty segments", () => {
  const { match } = findRoute(routes, "GET", "/api/spaces/a%20b");
  expect(match?.route.path).toBe("/api/spaces/:spaceId");
  expect(match?.params).toEqual({ spaceId: "a b" });
  expect(findRoute(routes, "GET", "/api/spaces//threads").match).toBeNull();
  expect(findRoute(routes, "GET", "/api/spaces/%E0%A4%A/threads").match).toBeNull();
});

test("a known path with an unsupported method reports the allowed methods", () => {
  const { match, allowed } = findRoute(routes, "PUT", "/api/spaces");
  expect(match).toBeNull();
  expect(allowed.sort()).toEqual(["GET", "POST"]);
});
