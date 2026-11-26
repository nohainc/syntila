#!/usr/bin/env node
// Repeats existing boundary suites; real provider/deployment evidence is separate.
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

export const SUITES = {
  backend: {
    cwd: fileURLToPath(new URL("../apps/backend/", import.meta.url)),
    command: "bun",
    args: [
      "scripts/test.ts",
      ...[
        "assignment-lifecycle-races",
        "assignment-revocation",
        "assignment-start-permit",
        "assignment-recovery",
        "worker-instances",
        "workflow-terminal-wait",
      ].map((name) => `test/domain/${name}.test.ts`),
    ],
  },
  connect: {
    cwd: fileURLToPath(new URL("../apps/connect/", import.meta.url)),
    command: "dart",
    args: [
      "test",
      "--concurrency=1",
      "test/agent_matrix_test.dart",
      "test/journal_test.dart",
      "test/mcp_worker_runner_test.dart",
    ],
  },
  engine: {
    cwd: fileURLToPath(
      new URL("../packages/syntila_cli_worker_runtime/", import.meta.url),
    ),
    command: "dart",
    args: ["test", "--concurrency=1"],
  },
  web: {
    cwd: fileURLToPath(new URL("../apps/app/", import.meta.url)),
    command: "flutter",
    args: [
      "test",
      "--concurrency=1",
      ...[
        "ax_execution_phase",
        "ax_work_realtime_sync",
        "ax_work_latency_trace",
      ].map((name) => `test/${name}_test.dart`),
    ],
  },
};

function execute(suite) {
  return new Promise((resolve) => {
    const child = spawn(suite.command, suite.args, {
      cwd: suite.cwd,
      stdio: "inherit",
      shell: false,
      env: { ...process.env, ...suite.env },
    });
    child.once("error", (error) =>
      resolve({ exitCode: null, error: error.message }),
    );
    child.once("exit", (code, signal) => resolve({ exitCode: code, signal }));
  });
}

export async function runAcceptance(
  { suites = Object.keys(SUITES), repeat = 3 } = {},
  run = execute,
) {
  if (!Number.isInteger(repeat) || repeat < 1 || repeat > 25)
    throw new Error("--repeat must be an integer from 1 to 25");
  if (
    !suites.length ||
    suites.some((name) => !Object.hasOwn(SUITES, name)) ||
    new Set(suites).size !== suites.length
  )
    throw new Error(
      "Choose unique suites: backend, connect, engine, web, or all",
    );
  const runs = [];
  for (let iteration = 1; iteration <= repeat; iteration++)
    for (const name of suites) {
      const started = performance.now();
      const result = await run(SUITES[name]);
      runs.push({
        suite: name,
        iteration,
        durationMs: Math.round(performance.now() - started),
        ...result,
      });
    }
  return {
    schemaVersion: 1,
    boundaryTestsStatus: runs.every(
      (run) => run.exitCode === 0 && !run.error && !run.signal,
    )
      ? "pass"
      : "fail",
    status: runs.some((run) => run.exitCode !== 0 || run.error || run.signal)
      ? "fail"
      : "incomplete",
    runs,
    liveEvidenceRequired: [
      "real Codex/Gemini/Claude fresh and second requests",
      "deployed Cloud event delivery and transport recovery",
      "complete idle/burst latency capture",
    ],
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const options = {};
    let json;
    for (let i = 2; i < process.argv.length; i += 2) {
      const flag = process.argv[i],
        value = process.argv[i + 1];
      if (!value) throw new Error(`Missing value for ${flag}`);
      if (flag === "--suite")
        options.suites =
          value === "all" ? Object.keys(SUITES) : value.split(",");
      else if (flag === "--repeat") options.repeat = Number(value);
      else if (flag === "--json") json = value;
      else throw new Error(`Unknown option: ${flag}`);
    }
    const result = await runAcceptance(options);
    if (json) writeFileSync(json, JSON.stringify(result, null, 2) + "\n");
    console.log(JSON.stringify(result, null, 2));
    // Exit code covers the selected deterministic tests, not release approval.
    process.exitCode = result.boundaryTestsStatus === "pass" ? 0 : 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 2;
  }
}
