import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  realpathSync,
  mkdirSync,
  writeFileSync,
  symlinkSync,
  rmSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// Facility evidence only. Production plugin launches do not use this policy.
export async function checkMacIsolation() {
  if (process.platform !== "darwin") {
    throw new Error("This acceptance check requires macOS sandbox-exec");
  }
  const root = realpathSync(mkdtempSync(join(tmpdir(), "syntila-isolation-")));
  const work = join(root, "work");
  const data = join(root, "data");
  mkdirSync(work);
  mkdirSync(data);
  writeFileSync(join(work, "existing"), "original");
  symlinkSync(work, join(data, "work-link"));
  const server = createServer((socket) => socket.end());
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const port = server.address().port;
    const probe = `
      const fs = require('node:fs');
      const net = require('node:net');
      const [work, data, port] = process.argv.slice(1);
      const result = {};
      for (const [name, path] of Object.entries({
        existing: work + '/existing', create: work + '/new',
        symlink: data + '/work-link/escape', data: data + '/allowed'
      })) {
        try { fs.writeFileSync(path, 'probe'); result[name] = true; }
        catch (e) { result[name] = false; }
      }
      const socket = net.connect(Number(port), '127.0.0.1');
      const finish = value => {
        result.network = value; socket.destroy();
        process.stdout.write(JSON.stringify(result));
      };
      socket.once('connect', () => finish(true));
      socket.once('error', () => finish(false));
      socket.setTimeout(3000, () => { process.stderr.write('network probe timed out'); process.exit(2); });
    `;
    const args = ["-e", probe, work, data, String(port)];
    const run = (command, commandArgs) => {
      const child = spawnSync(command, commandArgs, {
        encoding: "utf8",
        timeout: 10000,
        maxBuffer: 65536,
      });
      if (child.error || child.status !== 0) {
        throw new Error(
          `Isolation probe failed: ${child.error?.message ?? child.stderr}`,
        );
      }
      return JSON.parse(child.stdout);
    };
    const control = run(process.execPath, args);
    if (!Object.values(control).every((value) => value === true)) {
      throw new Error(
        "Unrestricted control did not establish all requested access",
      );
    }
    // JSON string escaping is also valid for these sandbox profile literals.
    const policy = `(version 1)(allow default)(deny network*)(deny file-write* (subpath ${JSON.stringify(work)}))`;
    const restricted = run("/usr/bin/sandbox-exec", [
      "-p",
      policy,
      process.execPath,
      ...args,
    ]);
    const expected = {
      existing: false,
      create: false,
      symlink: false,
      data: true,
      network: false,
    };
    if (JSON.stringify(restricted) !== JSON.stringify(expected)) {
      throw new Error(
        `Isolation policy did not enforce expected access: ${JSON.stringify(restricted)}`,
      );
    }
    return {
      platform: process.platform,
      architecture: process.arch,
      facility: "sandbox-exec",
      productionIntegrated: false,
      control,
      restricted,
    };
  } finally {
    server.close();
    rmSync(root, { recursive: true, force: true });
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  checkMacIsolation().then(
    (result) => console.log(JSON.stringify(result, null, 2)),
    (error) => {
      console.error(error.message);
      process.exitCode = 1;
    },
  );
}
