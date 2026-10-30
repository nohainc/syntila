import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  expandExecutionArguments,
  interpretProfileExecution,
  parseToolProfileV1,
  validateToolProfileV1,
  type ProfileExecutionContext,
} from "../src/index.js";

const context: ProfileExecutionContext = {
  prompt: "Continue",
  workingDirectory: "/workspace",
  home: "/home/test",
  workerStateDirectory: "/state",
  assignmentTimeoutMs: 30000,
  executionPolicy: "restricted",
  sessionPolicy: "stateless",
};
function starterJson(name: string) {
  return JSON.parse(
    readFileSync(
      new URL(
        `../../../apps/profile_lab/assets/profiles/${name}.json`,
        import.meta.url,
      ),
      "utf8",
    ),
  ) as Record<string, unknown>;
}
const starter = (name: string) =>
  parseToolProfileV1(JSON.stringify(starterJson(name)));

describe("context management", () => {
  it.each(["claude", "chatgpt", "copilot", "grok", "gemini"])(
    "%s starter describes context overflow",
    (name) => {
      expect(starter(name).context?.overflow?.markers.length).toBeGreaterThan(
        0,
      );
    },
  );

  it("declares on-demand compaction only where the CLI supports it", () => {
    expect(
      ["claude", "chatgpt", "copilot", "grok", "gemini"].filter(
        (name) => starter(name).context?.compaction,
      ),
    ).toEqual(["claude", "copilot", "grok", "gemini"]);
  });

  it("classifies Claude's overflow result as context_limit_exceeded", () => {
    const result = interpretProfileExecution(starter("claude"), {
      context,
      exitCode: 1,
      stdout: JSON.stringify({
        type: "result",
        is_error: true,
        result: "Prompt is too long",
      }),
    });
    expect(result).toMatchObject({
      terminal: "failure",
      issueCode: "context_limit_exceeded",
    });
  });

  it("classifies Codex's overflow error as context_limit_exceeded", () => {
    const result = interpretProfileExecution(starter("chatgpt"), {
      context,
      exitCode: 1,
      stdout: JSON.stringify({
        type: "turn.failed",
        error: {
          message:
            "Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying.",
        },
      }),
    });
    expect(result.issueCode).toBe("context_limit_exceeded");
  });

  it("ignores overflow phrases inside a successful answer", () => {
    const result = interpretProfileExecution(starter("claude"), {
      context,
      exitCode: 0,
      stdout: JSON.stringify({
        type: "result",
        is_error: false,
        session_id: "11111111-1111-4111-8111-111111111111",
        result: "The CLI prints 'Prompt is too long' when the context is full.",
      }),
    });
    expect(result).toMatchObject({ terminal: "success", issueCode: null });
  });

  it("expands auto-compaction arguments into the Claude invocation", () => {
    const args = expandExecutionArguments(starter("claude"), context);
    const at = args.indexOf("--autocompact");
    expect(at).toBeGreaterThan(-1);
    expect(args[at + 1]).toBe("auto");
  });

  it("requires exactly one slot when auto-compaction is declared", () => {
    const profile = starterJson("claude");
    const execution = profile.execution as { arguments: unknown[] };
    execution.arguments = execution.arguments.filter(
      (part) =>
        !(
          typeof part === "object" &&
          part !== null &&
          "autoCompactionArguments" in part
        ),
    );
    expect(() => validateToolProfileV1(profile)).toThrow(
      /autoCompactionArguments/,
    );
  });

  it("rejects compaction for a Profile without sessions", () => {
    const profile = starterJson("claude");
    profile.session = {
      supported: false,
      formatId: "claude-session",
      compatibleFormatIds: ["claude-session"],
      resumeArguments: [],
      requireObservedIdMatch: false,
    };
    const execution = profile.execution as { arguments: unknown[] };
    execution.arguments = execution.arguments.filter(
      (part) =>
        !(
          typeof part === "object" &&
          part !== null &&
          "sessionResumeArguments" in part
        ),
    );
    expect(() => validateToolProfileV1(profile)).toThrow(
      /Compaction requires supported sessions/,
    );
  });
});
