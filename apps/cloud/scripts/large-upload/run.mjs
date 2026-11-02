// Streams real bytes through the production `putStream` in workerd (via
// `wrangler dev --local`, real R2 simulation) and reports peak worker memory.
// Usage: node scripts/large-upload/run.mjs [bytes]
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const size = Number(process.argv[2] ?? 100_000_000);
const port = 8799;
const persist = mkdtempSync(join(tmpdir(), "large-upload-"));
const bin = join(here, "../../../../node_modules/.bin/wrangler");
const dev = spawn(
  bin,
  ["dev", "--local", "--port", String(port), "--persist-to", persist],
  { cwd: here, env: { ...process.env, WRANGLER_SEND_METRICS: "false" } },
);
let log = "";
dev.stdout.on("data", (d) => (log += d));
dev.stderr.on("data", (d) => (log += d));
for (let i = 0; i < 120 && !/Ready on/.test(log); i++)
  await new Promise((r) => setTimeout(r, 500));
if (!/Ready on/.test(log)) {
  console.error(log);
  dev.kill();
  process.exit(1);
}

const rss = () => {
  try {
    const out = execFileSync("ps", ["-A", "-o", "rss=,comm="], {
      encoding: "utf8",
    });
    return out
      .split("\n")
      .filter((line) => /workerd/.test(line))
      .map((line) => Number(line.trim().split(/\s+/)[0]) * 1024)
      .reduce((max, value) => Math.max(max, value), 0);
  } catch {
    return 0;
  }
};

async function put(total, declared, mode = "stream") {
  const chunk = new Uint8Array(1_000_000).fill(97);
  const hash = createHash("sha256");
  let sent = 0;
  const stream = new ReadableStream({
    pull(controller) {
      if (sent >= total) return controller.close();
      const take = Math.min(chunk.length, total - sent);
      const part = chunk.slice(0, take);
      hash.update(part);
      controller.enqueue(part);
      sent += take;
    },
  });
  let peak = rss();
  const timer = setInterval(() => (peak = Math.max(peak, rss())), 50);
  const started = Date.now();
  const response = await fetch(
    `http://127.0.0.1:${port}/?declared=${declared}&mode=${mode}`,
    {
      method: "PUT",
      headers: { "content-length": String(total) },
      body: stream,
      duplex: "half",
    },
  );
  clearInterval(timer);
  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text.slice(0, 300) };
  }
  return {
    status: response.status,
    ...json,
    expectedDigest: `sha256:${hash.digest("hex")}`,
    seconds: (Date.now() - started) / 1000,
    peakWorkerdRssMb: Math.round(peak / 1e6),
  };
}

try {
  const idle = rss();
  if (process.env.MODE === "buffer") {
    // The previous buffering implementation, in a fresh worker, as the baseline.
    console.log(
      JSON.stringify({
        case: `${size} bytes, buffered baseline`,
        workerdIdleRssMb: Math.round(idle / 1e6),
        ...(await put(size, size, "buffer")),
      }),
    );
    process.exit(0);
  }
  const honest = await put(size, size);
  console.log(
    JSON.stringify({
      case: `${size} bytes, honest size`,
      workerdIdleRssMb: Math.round(idle / 1e6),
      digestMatches: honest.digest === honest.expectedDigest,
      ...honest,
    }),
  );
  console.log(
    JSON.stringify({
      case: "declared smaller than body",
      ...(await put(1_000_000, 500_000)),
    }),
  );
  console.log(
    JSON.stringify({
      case: "declared larger than body",
      ...(await put(500_000, 1_000_000)),
    }),
  );
} finally {
  dev.kill();
  if (process.env.SHOW_LOG) console.error(log.slice(-3000));
}
