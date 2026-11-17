/**
 * The backend has no build step, so this is the only place its sources are
 * compiled. New type errors fail here (scripts/typecheck.ts explains the
 * baseline). A wrong name, a wrong argument count or a property read on the
 * wrong type is a runtime crash that no other test may happen to reach.
 */
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { compare, typeErrors, type Counts } from "../scripts/typecheck";

test("no type errors beyond the baseline", () => {
  const { counts, lines, global } = typeErrors();
  expect(global).toEqual([]);
  const baseline: Counts = JSON.parse(readFileSync(new URL("../scripts/typecheck-baseline.json", import.meta.url), "utf8"));
  const { worse } = compare(counts, baseline);
  if (worse.length) console.log(lines.join("\n"));
  expect(worse).toEqual([]);
}, 120_000);
