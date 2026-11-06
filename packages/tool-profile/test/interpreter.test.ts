import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  constructProviderStdin,
  expandExecutionArguments,
  interpretProfileExecution,
  mapProfileActivities,
  parseToolProfileV1,
  selectProfileValue,
  type ProfileExecutionContext,
} from "../src/index.js";

function loadProfile(name: string) {
  const source = readFileSync(
    fileURLToPath(new URL(`./fixtures/${name}.json`, import.meta.url)),
    "utf8",
  );
  return parseToolProfileV1(source);
}

function context(
  overrides: Partial<ProfileExecutionContext> = {},
): ProfileExecutionContext {
  return {
    prompt: "Make the requested change",
    workingDirectory: "/workspace/repo",
    home: "/home/tester",
    workerStateDirectory: "/home/tester/.syntila/worker",
    assignmentTimeoutMs: 30_000,
    executionPolicy: "restricted",
    sessionPolicy: "stateless",
    ...overrides,
  };
}

describe("Tool Profile v1 pure interpreter", () => {
  it("maps Codex and agy events to equivalent repeated tool activities", () => {
    const codex = loadProfile("chatgpt-codex.v1");
    const agy = loadProfile("gemini-antigravity.v1");
    const codexActivities = mapProfileActivities(codex, [
      { type: "unknown.provider.event" },
      {
        type: "item.started",
        item: { id: "codex-1", type: "command_execution" },
      },
      {
        type: "item.completed",
        item: { id: "codex-1", type: "command_execution" },
      },
      {
        type: "item.started",
        item: { id: "codex-2", type: "command_execution" },
      },
      {
        type: "item.completed",
        item: { id: "codex-2", type: "command_execution" },
      },
    ]);
    const agyActivities = mapProfileActivities(agy, [
      { event: "unknown.provider.event" },
      {
        event: "step_update",
        step_update: {
          state: "ACTIVE",
          step_type: "tool_execution",
          tool_id: "agy-1",
          tool_name: "shell",
        },
      },
      {
        event: "step_update",
        step_update: {
          state: "COMPLETED",
          step_type: "tool_execution",
          tool_id: "agy-1",
          tool_name: "shell",
        },
      },
      {
        event: "step_update",
        step_update: {
          state: "ACTIVE",
          step_type: "tool_execution",
          tool_id: "agy-2",
          tool_name: "shell",
        },
      },
      {
        event: "step_update",
        step_update: {
          state: "COMPLETED",
          step_type: "tool_execution",
          tool_id: "agy-2",
          tool_name: "shell",
        },
      },
    ]);
    expect(codexActivities.map(({ type, status }) => [type, status])).toEqual([
      ["tool.started", "running"],
      ["tool.completed", "completed"],
      ["tool.started", "running"],
      ["tool.completed", "completed"],
    ]);
    expect(agyActivities.map(({ type, status }) => [type, status])).toEqual([
      ["tool.started", "running"],
      ["tool.completed", "completed"],
      ["tool.started", "running"],
      ["tool.completed", "completed"],
    ]);
    expect(codexActivities.map((activity) => activity.activityId)).toEqual([
      "codex-1",
      "codex-1",
      "codex-2",
      "codex-2",
    ]);
    expect(
      agyActivities.every((activity) => activity.percentage === undefined),
    ).toBe(true);
  });

  it("uses the deterministic provider-version override during interpretation", () => {
    const profile = loadProfile("chatgpt-codex.v1");
    profile.compatibilityOverrides = [
      {
        providerVersion: { min: "0.180.0", maxExclusive: "0.181.0" },
        executionArguments: [
          "override",
          ...profile.compatibilityOverrides[0]!.executionArguments!.slice(1),
        ],
      },
    ];
    const args = expandExecutionArguments(
      profile,
      context({ providerVersion: "0.180.5" }),
    );
    expect(args[0]).toBe("override");
    expect(
      expandExecutionArguments(
        profile,
        context({ providerVersion: "0.190.0" }),
      )[0],
    ).not.toBe("override");
  });

  it("preserves sandbox policy in every Codex compatibility argument layout", () => {
    const profile = loadProfile("chatgpt-codex.v1");
    const layouts = [
      profile.execution.arguments,
      ...profile.compatibilityOverrides.flatMap((override) =>
        override.executionArguments ? [override.executionArguments] : [],
      ),
    ];
    for (const layout of layouts) {
      for (const sessionId of [undefined, "conversation-existing"]) {
        for (const [executionPolicy, sandbox] of [
          ["provider_default", "read-only"],
          ["restricted", "workspace-write"],
        ] as const) {
          const args = expandExecutionArguments(
            profile,
            context({
              executionPolicy,
              sessionPolicy: "durable",
              sessionId,
            }),
            layout,
          );
          const index = args.indexOf("--sandbox");
          const approval = args.indexOf("--ask-for-approval");
          expect(approval).toBeGreaterThanOrEqual(0);
          expect(args[approval + 1]).toBe("never");
          expect(
            args.filter((arg) => arg === "--ask-for-approval"),
          ).toHaveLength(1);
          expect(index).toBeGreaterThanOrEqual(0);
          expect(args[index + 1]).toBe(sandbox);
          expect(args.filter((arg) => arg === "--sandbox")).toHaveLength(1);
          expect(args).not.toContain(
            sandbox === "read-only" ? "workspace-write" : "read-only",
          );
          expect(args).not.toContain(
            "--dangerously-bypass-approvals-and-sandbox",
          );
        }
        const fullAccess = expandExecutionArguments(
          profile,
          context({
            executionPolicy: "full_access",
            sessionPolicy: "durable",
            sessionId,
          }),
          layout,
        );
        expect(fullAccess).toContain(
          "--dangerously-bypass-approvals-and-sandbox",
        );
        expect(fullAccess).not.toContain("--ask-for-approval");
        expect(fullAccess).not.toContain("--sandbox");
      }
    }
  });
  it.each([
    ["provider_default", "read-only"],
    ["restricted", "workspace-write"],
  ] as const)(
    "Codex maps %s to %s for fresh and resumed conversations",
    (executionPolicy, sandbox) => {
      const profile = loadProfile("chatgpt-codex.v1");
      for (const sessionId of [undefined, "conversation-existing"]) {
        const args = expandExecutionArguments(
          profile,
          context({
            executionPolicy,
            sessionPolicy: "durable",
            sessionId,
          }),
        );
        expect(args.slice(0, 4)).toEqual([
          "--ask-for-approval",
          "never",
          "--sandbox",
          sandbox,
        ]);
        expect(args.filter((arg) => arg === "--sandbox")).toHaveLength(1);
        expect(args).not.toContain(
          "--dangerously-bypass-approvals-and-sandbox",
        );
        expect(args).not.toContain(
          sandbox === "read-only" ? "workspace-write" : "read-only",
        );
      }
    },
  );
  it("expands Codex arguments into discrete argv without shell parsing", () => {
    const profile = loadProfile("chatgpt-codex.v1");
    const result = expandExecutionArguments(
      profile,
      context({ model: "gpt-test", workingDirectory: "/work path/repo" }),
    );
    expect(result).toEqual([
      "--ask-for-approval",
      "never",
      "--sandbox",
      "workspace-write",
      "exec",
      "--json",
      "--color",
      "never",
      "--skip-git-repo-check",
      "--cd",
      "/work path/repo",
      "--model",
      "gpt-test",
      "--ephemeral",
      "-",
    ]);

    const literal = expandExecutionArguments(profile, context(), [
      { sandboxPolicyMapping: true },
      { modelArguments: true },
      { sessionResumeArguments: true },
      { providerTimeoutArguments: true },
      "one; touch /tmp/not-created",
    ]);
    expect(literal).toContain("one; touch /tmp/not-created");
  });

  it("expands model, resume, timeout, and sandbox vectors at their declared slots", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    const result = expandExecutionArguments(
      profile,
      context({
        model: "gemini-pro",
        sessionPolicy: "durable",
        sessionId: "conversation-7",
        assignmentTimeoutMs: 30_000,
      }),
    );
    expect(result).toEqual([
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--sandbox",
      "--mode",
      "accept-edits",
      "--print-timeout",
      "29s",
      "--conversation",
      "conversation-7",
      "--model",
      "gemini-pro",
    ]);
  });

  it("uses AGY plan mode for Chat and accept-edits for Work", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    expect(
      expandExecutionArguments(
        profile,
        context({ executionPolicy: "restricted" }),
      ),
    ).toEqual(expect.arrayContaining(["--sandbox", "--mode", "accept-edits"]));
    expect(
      expandExecutionArguments(
        profile,
        context({ executionPolicy: "provider_default" }),
      ),
    ).toEqual(expect.arrayContaining(["--sandbox"]));
    expect(
      expandExecutionArguments(
        profile,
        context({ executionPolicy: "provider_default" }),
      ),
    ).toEqual(expect.arrayContaining(["--sandbox", "--mode", "plan"]));
    const fullAccess = expandExecutionArguments(
      profile,
      context({ executionPolicy: "full_access" }),
    );
    expect(fullAccess).toContain("--dangerously-skip-permissions");
    expect(fullAccess).not.toContain("--sandbox");
  });

  it("repeats additional folder arguments once per verified folder", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    const slots: NonNullable<Parameters<typeof expandExecutionArguments>[2]> = [
      { sandboxPolicyMapping: true },
      { modelArguments: true },
      { sessionResumeArguments: true },
      { providerTimeoutArguments: true },
      { forEachAdditionalDirectory: ["--add-dir", "{{additionalDirectory}}"] },
    ];
    const result = expandExecutionArguments(
      profile,
      context({
        additionalDirectories: ["/Users/me/api", "/Users/me/my docs"],
      }),
      [...slots],
    );
    expect(result.slice(-4)).toEqual([
      "--add-dir",
      "/Users/me/api",
      "--add-dir",
      "/Users/me/my docs",
    ]);
    expect(
      expandExecutionArguments(profile, context(), [...slots]),
    ).not.toContain("--add-dir");
    expect(() =>
      expandExecutionArguments(
        profile,
        context({ additionalDirectories: ["/Users/me/api"] }),
        [...slots.slice(0, 4)],
      ),
    ).toThrow("does not support additional folders");
  });

  it("passes MCP arguments only when a config path is provided", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    const slots: NonNullable<Parameters<typeof expandExecutionArguments>[2]> = [
      { sandboxPolicyMapping: true },
      { modelArguments: true },
      { sessionResumeArguments: true },
      { providerTimeoutArguments: true },
      { mcpConfigArguments: ["--mcp-config", "{{mcpConfigPath}}"] },
    ];
    const withMcp = expandExecutionArguments(
      profile,
      context({ mcpConfigPath: "/tmp/run 1/mcp.json" }),
      [...slots],
    );
    expect(withMcp.slice(-2)).toEqual(["--mcp-config", "/tmp/run 1/mcp.json"]);
    expect(
      expandExecutionArguments(profile, context(), [...slots]),
    ).not.toContain("--mcp-config");
    expect(() =>
      expandExecutionArguments(
        profile,
        context({ mcpConfigPath: "/tmp/mcp.json" }),
        [...slots.slice(0, 4)],
      ),
    ).toThrow("does not support MCP servers");
  });

  it("passes an inline TOML table through {{mcpServersToml}} and isolates user config", () => {
    const profile = loadProfile("chatgpt-codex.v2");
    const slots: NonNullable<Parameters<typeof expandExecutionArguments>[2]> = [
      { sandboxPolicyMapping: true },
      { modelArguments: true },
      { sessionResumeArguments: true },
      { providerTimeoutArguments: true },
      {
        mcpConfigArguments: [
          "--ignore-user-config",
          "-c",
          "mcp_servers={{mcpServersToml}}",
        ],
      },
    ];
    const withMcp = expandExecutionArguments(
      profile,
      context({
        mcpConfigPath: "/tmp/run/mcp.json",
        mcpServersToml: '{"files"={command="/bin/files"}}',
      }),
      [...slots],
    );
    expect(withMcp.slice(-3)).toEqual([
      "--ignore-user-config",
      "-c",
      'mcp_servers={"files"={command="/bin/files"}}',
    ]);
    // An empty selection still isolates: the table is empty, never absent.
    expect(
      expandExecutionArguments(
        profile,
        context({ mcpConfigPath: "/tmp/run/mcp.json", mcpServersToml: "{}" }),
        [...slots],
      ).slice(-3),
    ).toEqual(["--ignore-user-config", "-c", "mcp_servers={}"]);
    // No MCP execution at all: nothing is emitted.
    expect(
      expandExecutionArguments(profile, context(), [...slots]),
    ).not.toContain("--ignore-user-config");
    // The placeholder needs a config path to be defined.
    expect(() =>
      expandExecutionArguments(profile, context(), [
        ...slots.slice(0, 4),
        "mcp_servers={{mcpServersToml}}",
      ]),
    ).toThrow();
  });

  it("rejects {{mcpConfigPath}} outside its slot and malformed slots", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    const base = [
      { sandboxPolicyMapping: true },
      { modelArguments: true },
      { sessionResumeArguments: true },
      { providerTimeoutArguments: true },
    ] as const;
    expect(() =>
      expandExecutionArguments(profile, context(), [
        ...base,
        "{{mcpConfigPath}}",
      ]),
    ).toThrow();
    expect(() =>
      expandExecutionArguments(profile, context(), [
        ...base,
        { mcpConfigArguments: ["--mcp-config"] },
      ]),
    ).toThrow();
    expect(() =>
      expandExecutionArguments(profile, context(), [
        ...base,
        { mcpConfigArguments: ["--a", "{{mcpConfigPath}}"] },
        { mcpConfigArguments: ["--b", "{{mcpConfigPath}}"] },
      ]),
    ).toThrow();
  });

  it("rejects {{additionalDirectory}} outside its argument slot", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    expect(() =>
      expandExecutionArguments(profile, context(), [
        { sandboxPolicyMapping: true },
        { modelArguments: true },
        { sessionResumeArguments: true },
        { providerTimeoutArguments: true },
        "{{additionalDirectory}}",
      ]),
    ).toThrow();
    expect(() =>
      expandExecutionArguments(profile, context(), [
        { sandboxPolicyMapping: true },
        { modelArguments: true },
        { sessionResumeArguments: true },
        { providerTimeoutArguments: true },
        { forEachAdditionalDirectory: ["--add-dir"] },
      ]),
    ).toThrow();
  });

  it("evaluates only the fixed present/absent argument conditions", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    expect(
      expandExecutionArguments(
        profile,
        context({ model: "gpt-test", sessionId: "thread-9" }),
        [
          { sandboxPolicyMapping: true },
          { modelArguments: true },
          { sessionResumeArguments: true },
          { providerTimeoutArguments: true },
          { ifPresent: "model", values: ["--model", "{{model}}"] },
          { ifPresent: "sessionId", values: ["resume", "{{sessionId}}"] },
          {
            ifAbsent: "sessionId",
            ifSessionPolicy: "stateless",
            values: ["--ephemeral"],
          },
          "{{timeoutMs}}",
          "{{timeoutSeconds}}",
        ],
      ),
    ).toEqual([
      "--sandbox",
      "--mode",
      "accept-edits",
      "--model",
      "gpt-test",
      "--conversation",
      "thread-9",
      "--print-timeout",
      "29s",
      "--model",
      "gpt-test",
      "resume",
      "thread-9",
      "28500",
      "29",
    ]);
    const newStatelessSession = expandExecutionArguments(
      profile,
      context({ sessionPolicy: "stateless" }),
      [
        { sandboxPolicyMapping: true },
        { modelArguments: true },
        { sessionResumeArguments: true },
        { providerTimeoutArguments: true },
        {
          ifAbsent: "sessionId",
          ifSessionPolicy: "stateless",
          values: ["--ephemeral"],
        },
      ],
    );
    expect(newStatelessSession).toContain("--ephemeral");
    expect(newStatelessSession).not.toContain("--conversation");
  });

  it("constructs raw-text stdin and JSON-object stdin without string interpolation", () => {
    const prompt = 'A quote: "hello"\nand a newline';
    const chatgpt = loadProfile("chatgpt-codex.v1");
    expect(constructProviderStdin(chatgpt, context({ prompt }))).toBe(prompt);

    const gemini = loadProfile("gemini-antigravity.v1");
    const serialized = constructProviderStdin(gemini, context({ prompt }));
    expect(serialized.endsWith("\n")).toBe(true);
    expect(JSON.parse(serialized)).toEqual({
      event: "user",
      message: { content: prompt },
    });
  });

  it("normalizes Codex JSONL into the expected final result and progress", () => {
    const profile = loadProfile("chatgpt-codex.v1");
    const stdout = [
      { type: "thread.started", thread_id: "thread-1" },
      { type: "turn.started" },
      { type: "item.started", item: { type: "command_execution" } },
      { type: "item.updated", item: { type: "command_execution" } },
      { type: "item.completed", item: { type: "command_execution" } },
      {
        type: "item.completed",
        item: { type: "agent_message", text: "Codex answer" },
      },
      { type: "turn.completed" },
    ]
      .map((event) => JSON.stringify(event))
      .join("\n");

    expect(
      interpretProfileExecution(profile, {
        context: context({ sessionPolicy: "durable" }),
        stdout,
        exitCode: 0,
      }),
    ).toEqual({
      terminal: "success",
      finalText: "Codex answer",
      sessionId: "thread-1",
      terminalStatus: null,
      progress: [
        { percentage: 10, messageKey: "provider_working" },
        { percentage: 45, messageKey: "provider_tool_started" },
        { percentage: 45, messageKey: "provider_tool_started" },
        { percentage: 45, messageKey: "provider_tool_started" },
      ],
      issueCode: null,
    });
  });

  it("normalizes Antigravity JSONL and chooses the first matching progress rule", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    const stdout = [
      { event: "init", conversation_id: "conversation-7" },
      {
        event: "step_update",
        step_update: { state: "ACTIVE", step_type: "agent_response" },
      },
      {
        event: "step_update",
        step_update: { state: "ACTIVE", step_type: 42 },
      },
      {
        event: "step_update",
        step_update: { state: "ACTIVE", step_type: "tool_execution" },
      },
      {
        event: "result",
        result: {
          status: "SUCCESS",
          response: "Gemini answer",
          conversation_id: "conversation-7",
        },
      },
    ]
      .map((event) => JSON.stringify(event))
      .join("\n");

    expect(
      interpretProfileExecution(profile, {
        context: context({ sessionPolicy: "durable" }),
        stdout,
        exitCode: 0,
      }),
    ).toEqual({
      terminal: "success",
      finalText: "Gemini answer",
      sessionId: "conversation-7",
      terminalStatus: "SUCCESS",
      progress: [
        { percentage: 40, messageKey: "provider_response_received" },
        { percentage: 40, messageKey: "provider_working" },
      ],
      issueCode: null,
    });
  });

  it("supports plain-text and single-JSON output modes", () => {
    const base = loadProfile("chatgpt-codex.v1");
    const plain = structuredClone(base);
    plain.execution.output.mode = "plain_text";
    expect(
      interpretProfileExecution(plain, {
        context: context(),
        stdout: "plain answer",
        exitCode: 0,
      }).finalText,
    ).toBe("plain answer");

    const single = structuredClone(base);
    single.execution.output.mode = "single_json";
    single.execution.events = [
      {
        when: [{ kind: "equals", selector: "$.status", value: "SUCCESS" }],
        actions: [
          { type: "set_final_text", selector: "$.response" },
          { type: "mark_success" },
        ],
      },
    ];
    expect(
      interpretProfileExecution(single, {
        context: context(),
        stdout: JSON.stringify({ status: "SUCCESS", response: "JSON answer" }),
        exitCode: 0,
      }),
    ).toMatchObject({ terminal: "success", finalText: "JSON answer" });
  });

  it("fails closed on invalid output, missing terminal state, and resume mismatch", () => {
    const profile = loadProfile("chatgpt-codex.v1");
    expect(
      interpretProfileExecution(profile, {
        context: context(),
        stdout: '{"type":',
        exitCode: 0,
      }).issueCode,
    ).toBe("provider_failure");
    expect(
      interpretProfileExecution(profile, {
        context: context(),
        stdout: JSON.stringify({
          type: "thread.started",
          thread_id: "thread-1",
        }),
        exitCode: 0,
      }),
    ).toMatchObject({ terminal: "failure", issueCode: "provider_failure" });
    expect(
      interpretProfileExecution(profile, {
        context: context({ sessionPolicy: "durable", sessionId: "expected" }),
        stdout: JSON.stringify({
          type: "thread.started",
          thread_id: "different",
        }),
        exitCode: 0,
      }).issueCode,
    ).toBe("session_resume_failed");
  });

  it.each(["chatgpt-codex.v1", "gemini-antigravity.v1"])(
    "classifies unavailable native sessions through the signed %s mapping",
    (name) => {
      const profile = loadProfile(name);
      expect(
        interpretProfileExecution(profile, {
          context: context(),
          stdout: "",
          stderr: "Conversation not found",
          exitCode: 1,
        }).issueCode,
      ).toBe("session_resume_failed");
      expect(
        interpretProfileExecution(profile, {
          context: context(),
          stdout: "",
          stderr: "Provider temporarily unavailable",
          exitCode: 1,
        }).issueCode,
      ).not.toBe("session_resume_failed");
    },
  );

  it("maps provider authentication evidence and Engine-owned timeout failures", () => {
    const profile = loadProfile("chatgpt-codex.v1");
    expect(
      interpretProfileExecution(profile, {
        context: context(),
        stdout: "",
        stderr: "Authentication required. Please sign in.",
        exitCode: 1,
      }).issueCode,
    ).toBe("provider_authentication_required");
    expect(
      interpretProfileExecution(profile, {
        context: context(),
        stdout: "",
        exitCode: 1,
        timedOut: true,
      }).issueCode,
    ).toBe("deadline_exceeded");
    const apparentlySuccessful = [
      { type: "item.completed", item: { type: "agent_message", text: "late" } },
      { type: "turn.completed" },
    ]
      .map((event) => JSON.stringify(event))
      .join("\n");
    expect(
      interpretProfileExecution(profile, {
        context: context(),
        stdout: apparentlySuccessful,
        exitCode: 0,
        timedOut: true,
      }),
    ).toMatchObject({ terminal: "failure", issueCode: "deadline_exceeded" });
  });

  it("maps an Antigravity terminal error and captures its terminal status", () => {
    const profile = loadProfile("gemini-antigravity.v1");
    const result = interpretProfileExecution(profile, {
      context: context(),
      stdout: JSON.stringify({
        event: "result",
        result: { status: "ERROR", error: "Not authenticated" },
      }),
      exitCode: 0,
    });
    expect(result).toMatchObject({
      terminal: "failure",
      terminalStatus: "ERROR",
      issueCode: "provider_authentication_required",
    });
  });

  it("applies existence predicates, provider-error actions, progress actions, and failure actions", () => {
    const profile = structuredClone(loadProfile("chatgpt-codex.v1"));
    profile.execution.events = [
      {
        when: [{ kind: "exists", selector: "$.error", exists: true }],
        actions: [
          { type: "set_provider_error", selector: "$.error" },
          {
            type: "emit_progress",
            percentage: 15,
            messageKey: "provider_working",
          },
          { type: "mark_failure" },
        ],
      },
      {
        when: [{ kind: "not_equals", selector: "$.kind", value: "ignore" }],
        actions: [
          {
            type: "emit_progress",
            percentage: 20,
            messageKey: "provider_finalizing",
          },
        ],
      },
    ];
    profile.errors.mappings.unshift({
      evidence: { kind: "structured_provider_error", selector: "$.error" },
      issueCode: "provider_authentication_required",
    });
    const result = interpretProfileExecution(profile, {
      context: context(),
      stdout: JSON.stringify({
        error: "authentication required",
        kind: "error",
      }),
      exitCode: 0,
    });
    expect(result).toMatchObject({
      terminal: "failure",
      issueCode: "provider_authentication_required",
      progress: [
        { percentage: 15, messageKey: "provider_working" },
        { percentage: 20, messageKey: "provider_finalizing" },
      ],
    });
  });

  it("selects own JSON properties and refuses prototype traversal", () => {
    const root = JSON.parse('{"type":"safe","constructor":"data"}');
    expect(selectProfileValue(root, "$.type")).toBe("safe");
    expect(selectProfileValue(root, "$.absent")).toBeUndefined();
    expect(() => selectProfileValue(root, "$.constructor")).toThrow();
  });

  it("expands reasoningEffort when configured", () => {
    const profile = loadProfile("chatgpt-codex.v1");
    const args = expandExecutionArguments(
      profile,
      context({
        model: "gpt-6.1-sol",
        reasoningEffort: "xhigh",
      }),
    );
    expect(args).toContain("--model");
    expect(args).toContain("gpt-6.1-sol");
    expect(args).toContain("-c");
    expect(args).toContain('model_reasoning_effort="xhigh"');
  });
});

it("maps generic effort values and rejects invalid model/effort combinations", () => {
  const profile = loadProfile("chatgpt-codex.v1");
  profile.model.executionOptions = {
    schemaVersion: 1,
    discovery: "profile_catalog",
    modelSwitchSupported: true,
    effortSupported: true,
    effortMapping: { high: "provider-high" },
  };
  const args = expandExecutionArguments(
    profile,
    context({ model: "gpt-6.1-sol", reasoningEffort: "high" }),
  );
  expect(args).toContain('model_reasoning_effort="provider-high"');
  expect(() =>
    expandExecutionArguments(
      profile,
      context({ model: "gpt-6-luna", reasoningEffort: "ultra" }),
    ),
  ).toThrow(/Effort/);
  profile.model.executionOptions.modelSwitchSupported = false;
  expect(() =>
    expandExecutionArguments(
      profile,
      context({
        model: "gpt-6-luna",
        sessionPolicy: "durable",
        sessionId: "native",
        sessionModel: "gpt-6.1-sol",
      }),
    ),
  ).toThrow(/change model/);
});
