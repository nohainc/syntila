import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const boundaryDocPath = "docs/architecture/PROTOCOL_BOUNDARIES.md";
const boundaryDoc = readFileSync(boundaryDocPath, "utf8");

const requiredContractText = [
  "## 1. AX ↔ Cloud — Human Product Protocol",
  "## 2. Connect ↔ Cloud — Worker Agent Protocol",
  "## 3. Worker ↔ CLI Worker Engine — Local Worker Protocol 4.1",
  "AX MUST NOT open a Worker Runtime Protocol connection",
  "CLI Worker Engine process",
  "Local Worker Protocol: `packages/syntila_worker_protocol`",
  "## Shared canonical domain vocabulary",
  "`WorkerId`",
  "`WorkerTypeId`",
  "`AssignmentId`",
  "`RunId`",
  "`TaskId`",
  "`WorkerReadiness`",
  "`AssignmentStatus`",
  "`ErrorCode`",
  "These are canonical domain concepts, not a shared message envelope.",
  "apps/app/lib/src/realtime",
  "apps/backend/src/domain/worker-gateway.ts",
  "apps/connect/lib/src/cli_engine.dart",
];

const missingContractText = requiredContractText.filter(
  (required) => !boundaryDoc.includes(required),
);

const trackedFiles = execFileSync("git", ["ls-files", "-z"], {
  encoding: "utf8",
})
  .split("\0")
  .filter(Boolean);

const sourceFiles = trackedFiles
  .filter((file) => existsSync(file))
  .filter((file) => /\.(?:dart|ts|tsx|js|mjs|json)$/.test(file));

const violations = missingContractText.map(
  (required) =>
    `${boundaryDocPath}: missing required boundary statement: ${required}`,
);

const axRuntimeProtocolPattern =
  /syntila\.workspace-runtime-protocol|workerAgentProtocol|WorkerAgentMessage|workspace-runtime\.ts|@syntila\/workspace-runtime-protocol/i;
const firstPartyProviderPackagePattern = /\b(?:codex|antigravity)\b/i;

for (const file of sourceFiles) {
  const contents = readFileSync(file, "utf8");

  if (
    file.startsWith("apps/app/lib/") &&
    axRuntimeProtocolPattern.test(contents)
  ) {
    violations.push(
      `${file}: AX source references the Workspace Runtime Protocol`,
    );
  }

  if (
    file.startsWith("apps/app/lib/") &&
    firstPartyProviderPackagePattern.test(contents)
  ) {
    violations.push(
      `${file}: AX source references a first-party provider package ID`,
    );
  }

  if (
    [
      "apps/cloud/src/assignment-dispatcher.ts",
      "apps/cloud/src/scheduler.ts",
    ].includes(file) &&
    firstPartyProviderPackagePattern.test(contents)
  ) {
    violations.push(
      `${file}: Cloud assignment selection/dispatch references a provider package ID`,
    );
  }
}

if (violations.length > 0) {
  console.error("Protocol boundary architecture check failed:");
  for (const violation of violations) console.error(`- ${violation}`);
  process.exit(1);
}

console.log(
  "Protocol boundary architecture check passed: endpoint ownership is explicit, and Cloud assignments, AX, Workspace, and the CLI Worker Engine use their owned protocol boundaries.",
);
