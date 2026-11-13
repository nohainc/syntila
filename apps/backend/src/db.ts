import { SQL } from "bun";
import type { Config } from "./config";

export type Db = InstanceType<typeof SQL>;

export function createDb(config: Config["db"], applicationName = "syntila-backend"): Db {
  return new SQL({
    hostname: config.hostname,
    port: config.port,
    username: config.username,
    database: config.database,
    password: config.password,
    max: config.max,
    connectionTimeout: 5,
    idleTimeout: 60,
    connection: { application_name: applicationName, statement_timeout: "15000" },
  });
}

/** Encode a value for a `${json(x)}::text::jsonb` parameter. */
export const json = (value: unknown): string => JSON.stringify(value ?? null);

export function pgCode(error: unknown): string | undefined {
  return (error as { errno?: string } | null)?.errno;
}
