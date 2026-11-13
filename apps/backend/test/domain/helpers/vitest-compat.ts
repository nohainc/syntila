// Vitest-compatible API on bun:test for the ported Cloudflare test suite.
import { mock, jest } from "bun:test";
import * as bt from "bun:test";
export { describe, it, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { dirname, resolve } from "node:path";
import { existsSync, readFileSync } from "node:fs";
interface MockEntry { explicit: (() => Promise<any>) | null; inherited: { produce: () => Promise<any>; keys: () => Promise<string[]> }[] }
const mockEntries = new Map<string, MockEntry>();
function mockEntry(target: string): MockEntry {
  let e = mockEntries.get(target);
  if (!e) mockEntries.set(target, (e = { explicit: null, inherited: [] }));
  return e;
}
function register(target: string) {
  const e = mockEntry(target);
  mock.module(target, async () => {
    const base = e.explicit ? await e.explicit() : await import(target + "?original");
    const patched: Record<string, unknown> = { ...base };
    for (const inherited of e.inherited) {
      const [overrides, keys] = await Promise.all([inherited.produce(), inherited.keys()]);
      // Only what the re-exporting module's mock actually replaced.
      for (const k of keys) if (k in patched) patched[k] = overrides[k];
    }
    return patched;
  });
}
function reexportSources(file: string): string[] {
  if (!existsSync(file)) return [];
  const text = readFileSync(file, "utf8");
  const out: string[] = [];
  for (const m of text.matchAll(/^export\s+\*\s+from\s+["'](\.[^"']+)["']/gm)) {
    const full = resolve(dirname(file), m[1]!);
    const ts = full.replace(/\.js$/, ".ts");
    out.push(existsSync(ts) ? ts : full);
  }
  return out;
}
function resolveFromCaller(path: string): string {
  if (!path.startsWith(".")) return path;
  const frames = (new Error().stack ?? "").split("\n");
  for (const f of frames) {
    const m = f.match(/\(?((?:\/|[A-Za-z]:)[^():]+\.[cm]?[tj]s)(?::\d+)+\)?/);
    if (m && !m[1]!.includes("vitest-compat")) {
      const full = resolve(dirname(m[1]!), path);
      // Sources import "./x.js" but the module registry holds the .ts file.
      const ts = full.replace(/\.js$/, ".ts");
      return full !== ts && existsSync(ts) ? ts : full;
    }
  }
  return path;
}
const stubbedGlobals = new Map<string, PropertyDescriptor | undefined>();
const stubbedEnv = new Map<string, string | undefined>();
const base: any = (bt as any).vi ?? jest;
const vi: any = Object.assign(Object.create(base), base, {
  fn: jest.fn, spyOn: jest.spyOn,
  hoisted: (factory: () => unknown) => factory(),
  mock: (path: string, factory?: (importOriginal: () => Promise<any>) => unknown) => {
    if (!factory) return;
    const target = resolveFromCaller(path);
    if (process.env.VI_DEBUG) console.log("vi.mock", path, "->", target);
    const entry = mockEntry(target);
    let result: Promise<any> | null = null;
    entry.explicit = () => (result ??= Promise.resolve(factory(() => import(target + "?original"))));
    register(target);
    // Vitest replaces the whole module; ESM `export * from` re-exports would
    // otherwise still reach the original binding. Patch re-export sources too.
    for (const source of reexportSources(target)) {
      let keys: Promise<string[]> | null = null;
      // The names the test's factory sets itself (evaluated against an empty original).
      const overridden = () => (keys ??= Promise.resolve().then(() => factory(async () => ({}))).then((r: any) => Object.keys(r ?? {})).catch(() => []));
      mockEntry(source).inherited.push({ produce: entry.explicit, keys: overridden });
      register(source);
    }
  },
  stubGlobal: (name: string, value: unknown) => {
    if (!stubbedGlobals.has(name)) stubbedGlobals.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
    return vi;
  },
  unstubAllGlobals: () => {
    for (const [name, desc] of stubbedGlobals) desc ? Object.defineProperty(globalThis, name, desc) : delete (globalThis as any)[name];
    stubbedGlobals.clear();
    return vi;
  },
  stubEnv: (name: string, value: string) => { if (!stubbedEnv.has(name)) stubbedEnv.set(name, process.env[name]); process.env[name] = value; return vi; },
  unstubAllEnvs: () => { for (const [k, v] of stubbedEnv) v === undefined ? delete process.env[k] : (process.env[k] = v); stubbedEnv.clear(); return vi; },
  waitFor: async (fn: () => unknown, opts: number | { timeout?: number; interval?: number } = {}) => {
    const { timeout = 1000, interval = 20 } = typeof opts === "number" ? { timeout: opts } : opts;
    const end = Date.now() + timeout;
    for (;;) {
      try { return await fn(); } catch (e) { if (Date.now() > end) throw e; await new Promise((r) => setTimeout(r, interval)); }
    }
  },
  useFakeTimers: (...a: any[]) => { jest.useFakeTimers(...a); return vi; },
  useRealTimers: () => { jest.useRealTimers(); return vi; },
  // Code under test reaches its timers after real (PostgreSQL) I/O, which a
  // microtask flush does not cover: let pending I/O settle around the advance.
  advanceTimersByTimeAsync: async (ms: number) => { await settleIo(); jest.advanceTimersByTime(ms); await settleIo(); return vi; },
  advanceTimersByTime: (ms: number) => { jest.advanceTimersByTime(ms); return vi; },
  runAllTimersAsync: async () => { jest.runAllTimers(); await Promise.resolve(); return vi; },
  setSystemTime: (t: number | Date) => { jest.setSystemTime(t as any); return vi; },
  restoreAllMocks: () => { jest.restoreAllMocks(); return vi; },
  clearAllMocks: () => { jest.clearAllMocks(); return vi; },
  resetAllMocks: () => { (jest as any).resetAllMocks?.(); return vi; },
  mocked: <T>(x: T) => x,
});
let realTicks: Int32Array | null = null;
function realClock() {
  if (!realTicks) {
    const buffer = new SharedArrayBuffer(4);
    const worker = new Worker(new URL("./real-clock-worker.ts", import.meta.url));
    worker.postMessage(buffer);
    worker.unref();
    realTicks = new Int32Array(buffer);
  }
  return realTicks;
}
async function settleIo(ms = 60) {
  // Every JS clock is faked; a worker thread counts real milliseconds while
  // the event loop keeps turning (setImmediate is not faked) so I/O completes.
  const ticks = realClock();
  const until = Atomics.load(ticks, 0) + ms;
  let turns = 0;
  while (Atomics.load(ticks, 0) < until || turns < 50) { turns++; await new Promise((r) => setImmediate(r)); }
}
export { vi };
export const expectTypeOf = () => new Proxy({}, { get: () => () => undefined });
