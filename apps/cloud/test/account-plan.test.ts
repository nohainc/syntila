import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { identityService } from "../src/auth/identity-service.js";
import { handleAccountPlan } from "../src/routes/profile.js";
import {
  PaidPlanRequiredError,
  effectiveTier,
  getAccountPlan,
  requirePaidFeature,
} from "../src/account-plan.js";
import type { SecurityEnv } from "../src/routes/http-security.js";

let store: ReturnType<typeof sqliteD1>;
let env: SecurityEnv;
const now = new Date("2026-10-31T12:00:00Z");

beforeEach(() => {
  store = sqliteD1();
  store.sqlite
    .exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('free','f@test','Free','now','now'),('paid','p@test','Paid','now','now');
 INSERT INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at) VALUES('paid','paid','active','manual',NULL,'now','now');`);
  vi.spyOn(identityService, "resolve").mockImplementation(async (req) => {
    const id = req.headers.get("authorization");
    return id
      ? { userId: id, email: `${id}@test`, name: id, sessionId: "test" }
      : null;
  });
  env = {
    SYNTILA_DB: store.db,
    BETTER_AUTH_SECRET: "test",
    SYNTILA_ENVIRONMENT: "development",
  } as SecurityEnv;
});
afterEach(() => {
  vi.restoreAllMocks();
  store.sqlite.close();
});

it("treats only current paid subscriptions as the paid tier", () => {
  const row = (
    status: "active" | "trialing" | "past_due" | "canceled",
    end: string | null = null,
    tier: "free" | "paid" = "paid",
  ) => ({ tier, status, current_period_end: end });
  expect(effectiveTier(null, now)).toBe("free");
  expect(effectiveTier(row("active"), now)).toBe("paid");
  expect(effectiveTier(row("trialing", "2026-11-30T00:00:00Z"), now)).toBe(
    "paid",
  );
  expect(effectiveTier(row("past_due", "2026-11-01T00:00:00Z"), now)).toBe(
    "paid",
  );
  expect(effectiveTier(row("active", "2026-10-31T00:00:00Z"), now)).toBe(
    "free",
  );
  expect(effectiveTier(row("canceled"), now)).toBe("free");
  expect(effectiveTier(row("active", null, "free"), now)).toBe("free");
});

it("reports the caller's plan and defaults people without a row to free", async () => {
  const plan = async (user: string) =>
    (
      await handleAccountPlan(
        new Request("https://test/api/me/plan", {
          headers: { authorization: user },
        }),
        env,
      )
    ).json();
  expect(await plan("free")).toEqual({
    tier: "free",
    status: null,
    currentPeriodEnd: null,
    features: [],
  });
  expect(await plan("paid")).toMatchObject({ tier: "paid", status: "active" });
  await expect(
    handleAccountPlan(
      new Request("https://test/api/me/plan", {
        method: "PUT",
        headers: { authorization: "free" },
      }),
      env,
    ),
  ).rejects.toMatchObject({ status: 405 });
});

it("rejects paid features for free accounts with a stable code", async () => {
  expect((await getAccountPlan(env, "free")).tier).toBe("free");
  await expect(
    requirePaidFeature(env, "paid", "workspace.sharing"),
  ).resolves.toBeUndefined();
  const failure = requirePaidFeature(env, "free", "workspace.sharing");
  await expect(failure).rejects.toBeInstanceOf(PaidPlanRequiredError);
  await expect(failure).rejects.toMatchObject({
    status: 402,
    code: "paid_plan_required",
    feature: "workspace.sharing",
  });
});
