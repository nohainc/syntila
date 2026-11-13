/** ExecutionContext for Bun: tracks `waitUntil` work so shutdown can drain it. */
const pending = new Set<Promise<unknown>>();

export function executionContext(): ExecutionContext {
  return {
    waitUntil(promise: Promise<unknown>) {
      const p = Promise.resolve(promise).catch((e) => console.error(JSON.stringify({ level: "error", message: "background.task_failed", error: String(e?.stack ?? e) })));
      pending.add(p);
      p.finally(() => pending.delete(p));
    },
    passThroughOnException() {},
    props: {},
  } as unknown as ExecutionContext;
}

export async function drainBackgroundTasks(timeoutMs = 10_000): Promise<void> {
  await Promise.race([Promise.allSettled([...pending]), Bun.sleep(timeoutMs)]);
}

export const backgroundTaskCount = () => pending.size;
