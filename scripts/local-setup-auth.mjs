import { randomBytes } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";

// Local-only session signing material; never put it in CLI arguments or logs.
export function setupDevelopmentAuth(root) {
  const file = join(root, "apps/cloud/.dev.vars");
  const previous = existsSync(file) ? readFileSync(file, "utf8") : "";
  const values = parseEnv(previous);
  if (Object.hasOwn(values, "BETTER_AUTH_SECRET")) {
    if (!values.BETTER_AUTH_SECRET.trim()) {
      throw new Error(
        "BETTER_AUTH_SECRET is empty in apps/cloud/.dev.vars. Remove the empty setting to generate a local secret, or configure it explicitly.",
      );
    }
    chmodSync(file, 0o600);
    return { generated: false };
  }
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(
    file,
    `${previous}${previous && !previous.endsWith("\n") ? "\n" : ""}\n# Local development authentication; never deploy this secret.\nBETTER_AUTH_SECRET=${randomBytes(32).toString("hex")}\n`,
    { mode: 0o600 },
  );
  chmodSync(file, 0o600);
  return { generated: true };
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  setupDevelopmentAuth(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
  console.log(
    "Local authentication configured (secret preserved; not printed).",
  );
}
