import { defineConfig } from "vitest/config";
import { fileURLToPath, URL } from "node:url";

export default defineConfig({
  // scripts/*.test.mjs use node:test (run with `node --test scripts/`).
  test: { include: ["test/**/*.test.ts"] },
  resolve: {
    alias: {
      "cloudflare:workers": fileURLToPath(
        new URL("./test/cloudflare-workers.ts", import.meta.url),
      ),
    },
  },
});
