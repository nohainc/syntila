import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  writeFileSync,
  rmSync,
  lstatSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export function buildPluginAuthorKit(outputDirectory) {
  const staging = mkdtempSync(join(tmpdir(), "syntila-author-kit-"));
  const name = "syntila-plugin-author-kit";
  const kit = join(staging, name);
  const copied = [];
  function copy(relative) {
    const source = join(repository, relative);
    if (!lstatSync(source).isFile())
      throw new Error(`Not a regular file: ${relative}`);
    const target = join(kit, relative);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, readFileSync(source));
    copied.push(relative);
  }
  function dartTree(relative) {
    for (const entry of readdirSync(join(repository, relative), {
      withFileTypes: true,
    }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.isSymbolicLink())
        throw new Error("Author-kit sources must not be symlinks");
      if (entry.isDirectory()) dartTree(`${relative}/${entry.name}`);
      else if (entry.isFile() && entry.name.endsWith(".dart"))
        copy(`${relative}/${entry.name}`);
    }
  }
  try {
    for (const pkg of [
      "syntila_external_worker_protocol",
      "syntila_mcp_protocol",
      "syntila_external_worker_conformance",
      "syntila_external_worker_sdk",
    ]) {
      const base = `packages/${pkg}`;
      copy(`${base}/pubspec.yaml`);
      copy(`${base}/pubspec.lock`);
      dartTree(`${base}/lib`);
      if (pkg === "syntila_external_worker_conformance" || pkg === "syntila_external_worker_sdk")
        dartTree(`${base}/bin`);
    }
    for (const relative of [
      "examples/mcp/echo_worker/echo_worker.dart",
      "scripts/sign-plugin.mjs",
      "docs/specifications/WORKER_PLUGIN_PROTOCOL_V1.md",
    ])
      copy(relative);
    for (const entry of readdirSync(
      join(repository, "docs/specifications/worker-plugin-vectors"),
    )) {
      if (entry.endsWith(".jsonl"))
        copy(`docs/specifications/worker-plugin-vectors/${entry}`);
    }
    mkdirSync(kit, { recursive: true });
    writeFileSync(
      join(kit, "README.md"),
      `# Syntila plugin author kit

This archive contains the protocol, SDK, conformance runner and reference MCP
Worker. It uses only internal relative package paths; no Syntila checkout,
account or Plus entitlement is needed for authoring. Install Dart (SDK >=3.5)
and Node for optional signing.

From the extracted kit root:

\`\`\`sh
cd packages/syntila_external_worker_sdk
dart pub get
dart run syntila_external_worker_sdk:init ../../my-plugin my-plugin
cd ../../my-plugin
dart pub get
dart compile exe bin/main.dart -o bin/plugin
dart run syntila_external_worker_sdk:pack .
cd ../packages/syntila_external_worker_conformance
dart pub get
dart run bin/syntila_external_worker_conformance.dart ../../my-plugin
\`\`\`

On Windows use bin/plugin.exe as the compiler output (the generated manifest
already uses this name). Review plugin.json access declarations. Packing fills
hash/size fields after compilation; it does not create an archive or signature.
The generated project README repeats the platform-specific build commands.

The language-neutral protocol is in docs/specifications/WORKER_PLUGIN_PROTOCOL_V1.md
and transcript vectors are beside it. examples/plugins/echo_dart demonstrates
progress and sessions; examples/plugins/echo_python/echo.py uses only Python's
standard library. For long work, keep protocol input responsive to ping/cancel.
Optional scripts/sign-plugin.mjs takes package directory, private PEM key file,
and key ID, and writes plugin.sig. Keep private keys outside the package.

A passing conformance result proves protocol behavior only, not safety. A plugin
runs as its installing user. Production testing, registration and enablement go
through Workspace Service and require Plus and explicit consent. Standalone
conformance does not register or enable anything.

MANIFEST.sha256 records archive source contents. This is a local distribution
artifact, not publication to a package registry or a signed Syntila release.
`,
    );
    copied.push("README.md");
    const manifest = copied
      .sort()
      .map(
        (relative) =>
          `${createHash("sha256")
            .update(readFileSync(join(kit, relative)))
            .digest("hex")}  ${relative}`,
      )
      .join("\n");
    writeFileSync(join(kit, "MANIFEST.sha256"), `${manifest}\n`);
    const destination = resolve(outputDirectory);
    mkdirSync(destination, { recursive: true });
    const archive = join(destination, `${name}.tar.gz`);
    execFileSync("tar", ["-czf", archive, "-C", staging, name]);
    writeFileSync(
      `${archive}.sha256`,
      `${createHash("sha256").update(readFileSync(archive)).digest("hex")}  ${name}.tar.gz\n`,
    );
    return archive;
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  if (process.argv.length > 3) {
    console.error(
      "usage: node scripts/build-plugin-author-kit.mjs [output-directory]",
    );
    process.exitCode = 64;
  } else {
    console.log(
      buildPluginAuthorKit(
        process.argv[2] ?? join(repository, "dist/plugin-author-kit"),
      ),
    );
  }
}
