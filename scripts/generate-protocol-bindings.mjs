import { execSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { format } from "prettier";

const schema = JSON.parse(
  await readFile(
    "packages/protocol/schema/syntila-message.schema.json",
    "utf8",
  ),
);
const workspaceRuntime = schema["x-worker-agent-protocol"];
const realtime = schema["x-realtime-events"];
const errorCodes = schema["x-execution-error-codes"];
const errorMessages = schema["x-execution-error-messages"];

if (
  !workspaceRuntime ||
  !realtime ||
  !Array.isArray(errorCodes) ||
  !errorMessages ||
  errorCodes.some((code) => !Object.hasOwn(errorMessages, code))
) {
  throw new Error("current protocol schema metadata is incomplete");
}

const jsonItems = (items) =>
  items.map((item) => `  ${JSON.stringify(item)},`).join("\n");
const dartItems = (items) =>
  items.map((item) => `  '${String(item).replaceAll("'", "\\'")}',`).join("\n");
const tsErrors = errorCodes
  .map(
    (code) =>
      `  ${JSON.stringify(code)}: ${JSON.stringify(errorMessages[code])},`,
  )
  .join("\n");

const protocolTs = `// GENERATED FILE. Do not edit by hand.

export const EXECUTION_ERROR_CODES = [
${jsonItems(errorCodes)}
] as const;
export const EXECUTION_ERROR_MESSAGES = {
${tsErrors}
} as const;

${realtimeTsConstants(realtime)}
`;

const workerAgentTs = `// GENERATED FILE. Do not edit by hand.

${workerAgentTsConstants(workspaceRuntime)}
`;

const dartProtocol = `// GENERATED FILE. Do not edit by hand.

const executionErrorCodes = <String>{
${dartItems(errorCodes)}
};
const executionErrorMessages = <String, String>{
${errorCodes.map((code) => `  '${code}': '${String(errorMessages[code]).replaceAll("'", "\\'")}',`).join("\n")}
};

${workerAgentDartConstants(workspaceRuntime)}
${realtimeDartConstants(realtime)}
`;

const generatedFiles = new Map([
  ["packages/protocol/src/generated.ts", `${protocolTs.trimEnd()}\n`],
  [
    "packages/worker-agent-protocol/src/generated.ts",
    `${workerAgentTs.trimEnd()}\n`,
  ],
  [
    "packages/dart/protocol/lib/generated_protocol.dart",
    `${dartProtocol.trimEnd()}\n`,
  ],
]);

for (const [path, contents] of generatedFiles) {
  if (path.endsWith(".ts")) {
    generatedFiles.set(path, await format(contents, { filepath: path }));
  } else if (path.endsWith(".dart")) {
    try {
      const formatted = execSync("dart format --language-version=3.5", {
        input: contents,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "ignore"],
      });
      generatedFiles.set(path, formatted);
    } catch {
      // Fall back to unformatted if dart executable is absent in environment
    }
  }
}

if (process.argv.includes("--check")) {
  const staleFiles = [];
  for (const [path, expected] of generatedFiles) {
    let actual;
    try {
      actual = await readFile(path, "utf8");
    } catch {
      staleFiles.push(`${path} (missing)`);
      continue;
    }
    if (actual !== expected) staleFiles.push(path);
  }
  if (staleFiles.length > 0) {
    throw new Error(
      `Generated protocol bindings are stale or differ from the schema:\n${staleFiles.map((path) => `  ${path}`).join("\n")}\nRun pnpm protocol:generate and review the changes.`,
    );
  }
  console.log(
    "Generated protocol bindings exactly match the canonical schema.",
  );
} else {
  for (const [path, contents] of generatedFiles) {
    await writeFile(path, contents);
  }
}

function workerAgentTsConstants(value) {
  return `export const WORKER_AGENT_PROTOCOL_SCHEMA_NAME = ${JSON.stringify(value.name)} as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_VERSION = ${JSON.stringify(value.version)} as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_MAX_MESSAGE_SIZE_BYTES = ${value.maxMessageSizeBytes} as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_MESSAGE_TYPES = [
${jsonItems(value.messageTypes)}
] as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_BASE_ENVELOPE_FIELDS = [
${jsonItems(value.baseEnvelopeFields)}
] as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_ASSIGNMENT_ENVELOPE_FIELDS = [
${jsonItems(value.assignmentEnvelopeFields)}
] as const;`;
}

function realtimeTsConstants(value) {
  return `export const REALTIME_EVENTS_NAME = ${JSON.stringify(value.name)} as const;
export const REALTIME_EVENTS_VERSION = ${JSON.stringify(value.version)} as const;
export const REALTIME_EVENT_ENVELOPE_FIELDS = [
${jsonItems(value.envelopeFields)}
] as const;
export const REALTIME_EVENT_OPTIONAL_ENVELOPE_FIELDS = [
${jsonItems(value.optionalEnvelopeFields)}
] as const;
export const REALTIME_STREAM_KINDS = [
${jsonItems(value.streamKinds)}
] as const;
export const COLLABORATION_REALTIME_EVENT_TYPES = [
${jsonItems(value.collaborationTypes)}
] as const;
export const DURABLE_REALTIME_EVENT_TYPES = [
${jsonItems(value.durableTypes)}
] as const;
export const EPHEMERAL_REALTIME_EVENT_TYPES = [
${jsonItems(value.ephemeralTypes)}
] as const;
`;
}

function workerAgentDartConstants(value) {
  return `const workerAgentProtocolSchemaName = '${value.name}';
const workerAgentProtocolSchemaVersion = '${value.version}';
const workerAgentProtocolSchemaMaxMessageSizeBytes = ${value.maxMessageSizeBytes};
const workerAgentProtocolSchemaMessageTypes = <String>{
${dartItems(value.messageTypes)}
};
const workerAgentProtocolSchemaBaseEnvelopeFields = <String>[
${dartItems(value.baseEnvelopeFields)}
];
const workerAgentProtocolSchemaAssignmentEnvelopeFields = <String>[
${dartItems(value.assignmentEnvelopeFields)}
];`;
}

function realtimeDartConstants(value) {
  return `const realtimeEventsName = '${value.name}';
const realtimeEventsVersion = '${value.version}';
const realtimeEventEnvelopeFields = <String>[
${dartItems(value.envelopeFields)}
];
const realtimeEventOptionalEnvelopeFields = <String>[
${dartItems(value.optionalEnvelopeFields)}
];
const realtimeStreamKinds = <String>{
${dartItems(value.streamKinds)}
};
const collaborationRealtimeEventTypes = <String>{
${dartItems(value.collaborationTypes)}
};
const durableRealtimeEventTypes = <String>{
${dartItems(value.durableTypes)}
};
const ephemeralRealtimeEventTypes = <String>{
${dartItems(value.ephemeralTypes)}
};
`;
}
