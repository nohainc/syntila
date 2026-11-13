// Ported: tests now run on PostgreSQL. Kept as a thin alias so existing
// imports work; new tests should import { pgD1 } from "./pg-d1".
import { pgD1 } from "./pg-d1";
export function sqliteD1(_options: Record<string, unknown> = {}) {
  return pgD1();
}
