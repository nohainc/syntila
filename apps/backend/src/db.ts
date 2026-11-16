import { SQL } from "bun";
import type { Config } from "./config";

export type Db = InstanceType<typeof SQL>;

/**
 * The API's connection pool. Every session gets a statement timeout (15 s), a
 * lock-wait limit and an idle-in-transaction limit, so one stuck request can
 * neither hold locks forever nor make others wait forever. The migration
 * runner passes `limits: false`: it takes its own locks and sets its own
 * timeouts (migrate.ts).
 */
export function createDb(config: Config["db"], applicationName = "syntila-backend", limits = true): Db {
  return new SQL({
    hostname: config.hostname,
    port: config.port,
    username: config.username,
    database: config.database,
    password: config.password,
    max: config.max,
    connectionTimeout: 5,
    idleTimeout: 60,
    connection: {
      application_name: applicationName,
      statement_timeout: "15000",
      ...(limits && {
        lock_timeout: String(config.lockTimeoutMs ?? 10_000),
        idle_in_transaction_session_timeout: String(config.idleInTransactionMs ?? 30_000),
      }),
    },
  });
}

