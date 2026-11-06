import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  expandExecutionArguments,
  parseToolProfileV1,
  type ProfileExecutionContext,
} from "../src/index.js";

const drafts = ["chatgpt", "claude", "copilot", "gemini", "grok"] as const;
const load = (name: string) =>
  parseToolProfileV1(
    readFileSync(
      fileURLToPath(
        new URL(
          `../../../apps/profile_lab/assets/profiles/${name}.json`,
          import.meta.url,
        ),
      ),
      "utf8",
    ),
  );
const context = (
  overrides: Partial<ProfileExecutionContext> = {},
): ProfileExecutionContext => ({
  prompt: "Summarize the folders",
  workingDirectory: "/work/space",
  home: "/home/tester",
  workerStateDirectory: "/home/tester/state",
  assignmentTimeoutMs: 60_000,
  executionPolicy: "restricted",
  sessionPolicy: "durable",
  additionalDirectories: ["/Users/me/api", "/Users/me/my docs"],
  ...overrides,
});
const pairs = (args: string[]) =>
  args.flatMap((arg, index) => (arg === "--add-dir" ? [args[index + 1]] : []));

describe("Profile Lab drafts pass additional folders", () => {
  for (const name of drafts) {
    it(`${name} repeats --add-dir per folder, fresh and resumed`, () => {
      const profile = load(name);
      for (const sessionId of [undefined, "session-1"]) {
        const args = expandExecutionArguments(profile, context({ sessionId }));
        expect(pairs(args)).toEqual(["/Users/me/api", "/Users/me/my docs"]);
      }
      expect(
        expandExecutionArguments(
          profile,
          context({ additionalDirectories: [] }),
        ),
      ).not.toContain("--add-dir");
    });
  }

  it("keeps Codex folder flags on exec, before the resume subcommand", () => {
    const profile = load("chatgpt");
    const versions = [undefined, "0.180.5"];
    for (const providerVersion of versions) {
      const args = expandExecutionArguments(
        profile,
        context({ sessionId: "session-1", providerVersion }),
      );
      expect(args.lastIndexOf("--add-dir")).toBeLessThan(
        args.indexOf("resume"),
      );
    }
  });
});

describe("Claude draft passes MCP servers through a private config", () => {
  it("loads only the generated config, including an empty config", () => {
    const profile = load("claude");
    const withServers = expandExecutionArguments(
      profile,
      context({ mcpConfigPath: "/tmp/run 1/mcp.json" }),
    );
    const at = withServers.indexOf("--mcp-config");
    expect(withServers.slice(at, at + 2)).toEqual([
      "--mcp-config",
      "/tmp/run 1/mcp.json",
    ]);
    // Strict: the user's own global MCP servers are not loaded.
    expect(withServers).toContain("--strict-mcp-config");
    // The Engine supplies a path even for an empty selection.
    const empty = expandExecutionArguments(
      profile,
      context({ mcpConfigPath: "/tmp/empty/mcp.json" }),
    );
    expect(empty).toContain("/tmp/empty/mcp.json");
    expect(empty).toContain("--strict-mcp-config");
  });
});
