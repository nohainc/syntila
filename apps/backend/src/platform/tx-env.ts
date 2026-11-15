/**
 * Runs existing domain code inside one data-layer transaction
 * (claude/concurrency-plan.md, Phase 5).
 *
 *   await inTransaction(env, "pin.set", async (txEnv, tx) => {
 *     await tx.lock("syntila.pins", userId);
 *     await publishCollaborationEvent(txEnv, …, { mutations: [stmt] });
 *   });
 *
 * `txEnv` is `env` with:
 *  - SYNTILA_DB: the adapter bound to the transaction (`within`): every
 *    `prepare()` and `batch()` runs on it, without the global writer lock;
 *  - SYNTILA_DATA: a `JoinedData`, so data-layer code joins the transaction;
 *  - an after-commit hook: realtime fan-out and other effects outside the
 *    database run only once the transaction committed (event-publisher.ts).
 * Calling `inTransaction` with a `txEnv` joins the open transaction.
 *
 * Two differences from the adapter's one-transaction-per-statement model:
 *  - a failed statement aborts the whole transaction. Code that catches a
 *    statement error and carries on (D1 style "try the insert, else …")
 *    must do that outside, or use a conflict-safe statement instead;
 *  - inside, use only `txEnv`: a call on the outer `env` waits for a second
 *    pool connection, and with the pool full of waiting transactions that
 *    wait never ends.
 */
import { dataOf, JoinedData, type Tx } from "./data";
import type { PgD1Database } from "./pg-d1";

const ROOT = Symbol("syntila.rootEnv");
const OPEN = Symbol("syntila.openTx");

type Env = { SYNTILA_DB: unknown; SYNTILA_DATA?: unknown };

export async function inTransaction<E extends Env, T>(
  env: E,
  label: string,
  fn: (txEnv: E, tx: Tx) => Promise<T>,
): Promise<T> {
  const open = (env as Record<symbol, unknown>)[OPEN] as Tx | undefined;
  if (open) return fn(env, open);
  const db = env.SYNTILA_DB as { within?: unknown } | null;
  if (typeof db?.within !== "function") return withoutTransaction(env, fn);
  return dataOf(env).tx(label, (tx) => fn(transactionEnv(env, tx), tx));
}

/**
 * Hand-written test doubles of the adapter (no PostgreSQL behind them) run
 * the function as is: there is nothing to lock and nothing to roll back.
 * The production adapter always has `within`, so this never applies there.
 */
async function withoutTransaction<E extends Env, T>(
  env: E,
  fn: (txEnv: E, tx: Tx) => Promise<T>,
): Promise<T> {
  const after: (() => unknown)[] = [];
  const unsupported = () => {
    throw new Error("This test database double has no data layer");
  };
  const tx = {
    rows: unsupported,
    row: unsupported,
    run: unsupported,
    list: unsupported,
    frag: unsupported,
    raw: unsupported,
    lock: async () => {},
    afterCommit: (f: () => unknown) => {
      after.push(f);
    },
    get connection(): never {
      return unsupported();
    },
  } as unknown as Tx;
  const result = await fn({ ...env, [OPEN]: tx, [ROOT]: env } as E, tx);
  for (const f of after) await f();
  return result;
}

function transactionEnv<E extends Env>(env: E, tx: Tx): E {
  const db = env.SYNTILA_DB as PgD1Database;
  if (typeof db?.within !== "function")
    throw new Error("SYNTILA_DB cannot join a transaction");
  return {
    ...env,
    SYNTILA_DB: db.within(tx.connection),
    SYNTILA_DATA: new JoinedData(tx),
    [ROOT]: env,
    [OPEN]: tx,
  } as E;
}

/** The environment outside any transaction (for work after commit). */
export function rootEnv<E>(env: E): E {
  return ((env as Record<symbol, unknown>)[ROOT] as E | undefined) ?? env;
}

/** Runs `fn` after the open transaction commits, or now outside one. */
export function afterCommit(
  env: unknown,
  fn: () => unknown,
): Promise<void> | void {
  const open = (env as Record<symbol, unknown>)?.[OPEN] as Tx | undefined;
  if (open) open.afterCommit(fn);
  else return Promise.resolve(fn()).then(() => undefined);
}

export function inOpenTransaction(env: unknown): boolean {
  return !!(env as Record<symbol, unknown>)?.[OPEN];
}

/**
 * One self-contained statement (conditional or conflict-safe on its own),
 * run without the global writer lock. For anything that reads before it
 * writes, use `inTransaction` and lock what the rule needs.
 */
export function writeAlone<E extends Env>(
  env: E,
  label: string,
  build: (db: D1Database) => D1PreparedStatement,
): Promise<D1Result> {
  return inTransaction(env, label, (txEnv) =>
    build(txEnv.SYNTILA_DB as unknown as D1Database).run(),
  );
}

/** Statements prepared on any adapter, run as one transaction without the global writer lock. */
export function batchAlone<E extends Env>(
  env: E,
  label: string,
  statements: readonly D1PreparedStatement[],
): Promise<D1Result[]> {
  return inTransaction(env, label, (txEnv) =>
    (txEnv.SYNTILA_DB as unknown as D1Database).batch([...statements]),
  );
}
