import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";

const read = (path) => readFile(path, "utf8");
const schema = JSON.parse(
  await read("packages/protocol/schema/syntila-message.schema.json"),
);
const [
  protocolTs,
  workerAgentTs,
  dart,
  protocolIndex,
  workerAgentIndex,
  dartIndex,
  workerPackage,
  connectDart,
] = await Promise.all([
  read("packages/protocol/src/generated.ts"),
  read("packages/worker-agent-protocol/src/generated.ts"),
  read("packages/dart/protocol/lib/generated_protocol.dart"),
  read("packages/protocol/src/index.ts"),
  read("packages/worker-agent-protocol/src/index.ts"),
  read("packages/dart/protocol/lib/syntila_protocol.dart"),
  read("packages/syntila_worker_protocol/lib/src/protocol_version.dart"),
  read("packages/dart/protocol/lib/worker_agent_protocol.dart"),
]);

const retiredSchemaKeys = [
  "x-agent-protocol",
  "x-local-protocols",
  "x-worker-protocol",
];
for (const key of retiredSchemaKeys) {
  if (Object.hasOwn(schema, key)) {
    throw new Error(
      `canonical schema still defines retired protocol metadata: ${key}`,
    );
  }
}
for (const message of [
  "worker.install",
  "worker.remove",
  "worker.status",
  "credential.status",
]) {
  if (schema["x-worker-agent-protocol"].messageTypes.includes(message)) {
    throw new Error(
      `canonical schema still defines retired message ${message}`,
    );
  }
}
const generatedFiles = [protocolTs, workerAgentTs, dart];
const forbiddenGeneratedTokens = [
  "const AGENT_PROTOCOL_",
  "agentProtocolName",
  "AGENT_APP_IPC_",
  "WORKER_PLUGIN_",
  "worker" + "PluginProtocolName",
  "workerProtocolName",
  "worker.install",
  "worker.remove",
  "credential.status",
  "resolvedWorkerVersion",
];
for (const token of forbiddenGeneratedTokens) {
  if (generatedFiles.some((contents) => contents.includes(token))) {
    throw new Error(
      `generated bindings still contain retired protocol field: ${token}`,
    );
  }
}
for (const code of schema["x-execution-error-codes"]) {
  if (
    !protocolTs.includes(JSON.stringify(code)) ||
    !dart.includes(`'${code}'`)
  ) {
    throw new Error(`generated execution error bindings are missing ${code}`);
  }
}
for (const type of schema["x-worker-agent-protocol"].messageTypes) {
  if (!workerAgentTs.includes(JSON.stringify(type))) {
    throw new Error(
      `generated Connect protocol bindings are missing ${type}`,
    );
  }
}
for (const type of schema["x-realtime-events"].durableTypes.concat(
  schema["x-realtime-events"].ephemeralTypes,
)) {
  if (!protocolTs.includes(JSON.stringify(type))) {
    throw new Error(`generated realtime event bindings are missing ${type}`);
  }
}
if (
  protocolIndex.includes("generated-local-protocols") ||
  protocolIndex.includes("AGENT_PROTOCOL_") ||
  workerAgentIndex.includes("AGENT_PROTOCOL_") ||
  dartIndex.includes("generated_local_protocols") ||
  [
    "worker.install",
    "worker.remove",
    "worker.status",
    "credential.status",
  ].some((message) => connectDart.includes(`'${message}'`)) ||
  !workerPackage.includes("localWorkerProtocolVersion = '4.1'")
) {
  throw new Error(
    "protocol exports do not use the current schema and Worker Protocol package",
  );
}

execFileSync(
  process.execPath,
  ["scripts/generate-protocol-bindings.mjs", "--check"],
  {
    stdio: "inherit",
  },
);

console.log("Current protocol schema and generated bindings are aligned.");
