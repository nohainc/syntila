import { expect, test } from "bun:test";
import { collectRoutes, renderRoutes, ROUTES_FILE } from "../scripts/routes";

test("docs/api/ROUTES.md lists the routes the router serves (run `bun run routes` after changing routes)", async () => {
  expect(await Bun.file(ROUTES_FILE).text()).toBe(await renderRoutes());
});

test("the inventory sees the main resources", async () => {
  const routes = await collectRoutes();
  expect([...routes.get("/api/spaces")!].sort()).toEqual(["GET", "POST"]);
  expect([...routes.get("/api/spaces/:id")!].sort()).toEqual(["DELETE", "GET", "PATCH"]);
  expect(routes.size).toBeGreaterThan(100);
});
