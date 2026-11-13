import { describe, expect, test } from "bun:test";
import { pgD1 } from "./domain/helpers/pg-d1";
import { WorkflowHost, durationMs } from "../src/platform/workflows";

const until = async (fn: () => Promise<boolean>, ms = 8000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await fn()) return; await Bun.sleep(25); }
  throw new Error("condition not met");
};

describe("durable workflow runner", () => {
  test("durations", () => {
    expect(durationMs("15 seconds")).toBe(15_000);
    expect(durationMs("1 minute")).toBe(60_000);
    expect(durationMs(250)).toBe(250);
  });

  test("memoises steps across replays, buffers events, resumes on events and times out waits", async () => {
    const { sql } = pgD1();
    const calls: string[] = [];
    let host!: WorkflowHost;
    host = new WorkflowHost("demo", sql as any, () => ({
      async run(event: any, step: any) {
        const a = await step.do("a", async () => { calls.push("a"); return { n: event.payload.n + 1 }; });
        const ev = await step.waitForEvent("approval", { type: "approve", timeout: "1 minute" });
        let timedOut = false;
        try { await step.waitForEvent("never", { type: "never", timeout: 300 }); } catch { timedOut = true; }
        const b = await step.do("b", async () => { calls.push("b"); return a.n * 10; });
        return { b, approvedBy: (ev.payload as any).by, timedOut };
      },
    }), () => ({}));
    host.start();
    try {
      const inst = await host.binding().create({ id: "wf-1", params: { n: 1 } });
      await expect(host.binding().create({ id: "wf-1", params: {} })).rejects.toThrow(/exist/);
      await until(async () => (await inst.status()).status === "waiting");
      expect(calls).toEqual(["a"]);
      await inst.sendEvent({ type: "approve", payload: { by: "vitalii" } });
      await until(async () => (await inst.status()).status === "complete");
      const status = await inst.status();
      expect(status.output).toEqual({ b: 20, approvedBy: "vitalii", timedOut: true });
      expect(calls).toEqual(["a", "b"]); // "a" was not re-executed on replay

      // Events sent before the wait starts are buffered.
      const early = await host.binding().create({ id: "wf-2", params: { n: 0 } });
      await early.sendEvent({ type: "approve", payload: { by: "early" } });
      await until(async () => (await early.status()).status === "complete");
      expect((await early.status()).output).toMatchObject({ approvedBy: "early" });
    } finally {
      await host.stop();
    }
  });

  test("a wait inside try/catch still parks the instance (the catch sees only a real timeout)", async () => {
    const { sql } = pgD1();
    const seen: string[] = [];
    const host = new WorkflowHost("demo3", sql as any, () => ({
      async run(_event: any, step: any) {
        try { await step.waitForEvent("result", { type: "done", timeout: "10 minutes" }); seen.push("event"); }
        catch { seen.push("caught"); }
        return seen;
      },
    }), () => ({}));
    host.start();
    try {
      const inst = await host.binding().create({ id: "wf-catch", params: {} });
      await until(async () => (await inst.status()).status === "waiting");
      await Bun.sleep(300);
      expect(seen).toEqual([]);
      await inst.sendEvent({ type: "done", payload: {} });
      await until(async () => (await inst.status()).status === "complete");
      expect((await inst.status()).output).toEqual(["event"]);
    } finally {
      await host.stop();
    }
  });

  test("graceful stop hands a still-running instance back at once", async () => {
    const { sql } = pgD1();
    const host = new WorkflowHost("demo4", sql as any, () => ({
      async run(_e: any, step: any) { await step.do("slow", async () => { await Bun.sleep(60_000); }); },
    }), () => ({}));
    host.start();
    await host.binding().create({ id: "wf-slow", params: {} });
    await until(async () => (await sql`SELECT status FROM workflow_instances WHERE id = 'wf-slow'`)[0].status === "running");
    await host.stop(100);
    const [row] = await sql`SELECT status, lease_owner FROM workflow_instances WHERE id = 'wf-slow'`;
    expect(row).toEqual({ status: "queued", lease_owner: null });
  });

  test("a crashed process's instance is resumed after its lease expires; failures are recorded", async () => {
    const { sql } = pgD1();
    await sql.unsafe(`INSERT INTO workflow_instances(id, workflow, params, status, lease_owner, lease_until)
      VALUES ('wf-crash', 'demo2', '{}'::jsonb, 'running', 'dead-process', now() - interval '1 second')`);
    const host = new WorkflowHost("demo2", sql as any, () => ({
      async run(event: any, step: any) {
        if (event.instanceId === "wf-fail") await step.do("boom", { retries: { limit: 1, delay: 10 } }, async () => { throw new Error("nope"); });
        return step.do("work", async () => "done");
      },
    }), () => ({}));
    host.start();
    try {
      const b = host.binding();
      await until(async () => (await (await b.get("wf-crash")).status()).status === "complete");
      await b.create({ id: "wf-fail" });
      await until(async () => (await (await b.get("wf-fail")).status()).status === "errored");
      expect((await (await b.get("wf-fail")).status()).error).toBe("nope");
    } finally {
      await host.stop();
    }
  });
});
