import {
  TOOL_PROFILE_LIMITS,
  resolveToolProfileCompatibility,
  validateToolProfileV1,
  type ToolProfileV1,
} from "./index.js";

export const PROFILE_INTERPRETER_LIMITS = Object.freeze({
  inputBytes: 1024 * 1024,
  argumentBytes: 128 * 1024,
  outputBytes: 4 * 1024 * 1024,
  outputLineBytes: 512 * 1024,
  outputEvents: 10_000,
  finalTextBytes: 512 * 1024,
  sessionIdLength: 256,
});

export type ExecutionPolicy = "restricted" | "provider_default" | "full_access";
export type SessionPolicy = "stateless" | "durable";
export type ProfileIssueCode =
  ToolProfileV1["errors"]["mappings"][number]["issueCode"];
export type ProfileProgressKey =
  ToolProfileV1["progress"][number]["messageKey"];

export interface ProfileExecutionContext {
  prompt: string;
  workingDirectory: string;
  home: string;
  workerStateDirectory: string;
  assignmentTimeoutMs: number;
  executionPolicy: ExecutionPolicy;
  sessionPolicy: SessionPolicy;
  model?: string;
  reasoningEffort?: string;
  sessionId?: string;
  /** Last successful model for resume capability checks; null means Default. */
  sessionModel?: string | null;
  /** Detected provider CLI version used to select one compatibility override. */
  providerVersion?: string;
  /** Workspace-verified folders the CLI may use besides workingDirectory. */
  additionalDirectories?: readonly string[];
}

export interface ProfileExecutionInput {
  context: ProfileExecutionContext;
  stdout: string;
  stderr?: string;
  exitCode: number;
  timedOut?: boolean;
  cancelled?: boolean;
}

export interface NormalizedProfileProgress {
  percentage: number;
  messageKey: ProfileProgressKey;
}

type ProfileActivityMapping = NonNullable<
  ToolProfileV1["activity"]
>["mappings"][number];

export interface NormalizedProfileActivity {
  type: ProfileActivityMapping["type"];
  status: ProfileActivityMapping["status"];
  title: string;
  activityId: string | null;
  message: string | null;
  details: Record<string, string | number | boolean | null>;
  percentage?: number;
}

/** Maps provider JSON events using only declarative Profile selectors. */
export function mapProfileActivities(
  profile: ToolProfileV1,
  events: readonly unknown[],
): NormalizedProfileActivity[] {
  const mappings = profile.activity?.mappings ?? [];
  const activities: NormalizedProfileActivity[] = [];
  for (const event of events) {
    for (const mapping of mappings) {
      if (!matchesConditions(event, mapping.when)) continue;
      const rawId = mapping.activityIdSelector
        ? selectProfileValue(event, mapping.activityIdSelector)
        : undefined;
      // Some providers identify a step by its numeric index within one run.
      const selectedId = typeof rawId === "number" ? String(rawId) : rawId;
      const selectedMessage = mapping.messageSelector
        ? selectProfileValue(event, mapping.messageSelector)
        : undefined;
      const details: Record<string, string | number | boolean | null> = {};
      for (const [key, path] of Object.entries(mapping.detailSelectors ?? {})) {
        if (
          path
            .slice(2)
            .split(".")
            .some((part) =>
              [
                "prompt",
                "content",
                "text",
                "output",
                "stdout",
                "stderr",
                "arguments",
                "command",
                "environment",
                "env",
                "token",
                "secret",
                "password",
                "api_key",
              ].includes(part.toLowerCase()),
            )
        )
          continue;
        const value = selectProfileValue(event, path);
        if (
          value === null ||
          typeof value === "string" ||
          typeof value === "number" ||
          typeof value === "boolean"
        ) {
          details[key] = value;
        }
      }
      activities.push({
        type: mapping.type,
        status: mapping.status,
        title: mapping.title,
        activityId:
          typeof selectedId === "string" && selectedId.length > 0
            ? selectedId.slice(0, 128)
            : null,
        message:
          typeof selectedMessage === "string" && selectedMessage.length > 0
            ? selectedMessage.slice(0, 2048)
            : null,
        details,
        ...(mapping.percentage === undefined
          ? {}
          : { percentage: mapping.percentage }),
      });
    }
  }
  return activities;
}

export interface NormalizedProfileResult {
  terminal: "success" | "failure";
  finalText: string | null;
  sessionId: string | null;
  terminalStatus: string | null;
  progress: NormalizedProfileProgress[];
  issueCode: ProfileIssueCode | null;
}

export interface ProviderVersionProbeInput {
  stdout: string;
  stderr?: string;
  exitCode: number;
}

export interface NormalizedProviderVersion {
  version: string | null;
  supported: boolean;
  issueCode: ProfileIssueCode | null;
}

export interface NormalizedReadinessCheck {
  code: string;
  status: "passed" | "warning" | "failed";
}

export interface ProfileReadinessInput {
  versionProbe: ProviderVersionProbeInput;
  commandExitCodes?: Record<string, number>;
  configFiles?: Record<string, string>;
  environment?: Record<string, string>;
}

export interface NormalizedProfileReadiness {
  ready: boolean;
  providerVersion: string | null;
  checks: NormalizedReadinessCheck[];
  issueCode: ProfileIssueCode | null;
}

export class ProfileInterpreterError extends Error {
  constructor(
    message: string,
    readonly issueCode: ProfileIssueCode = "provider_failure",
  ) {
    super(message);
    this.name = "ProfileInterpreterError";
  }
}

function requireContextText(name: string, value: string): void {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > TOOL_PROFILE_LIMITS.stringLength
  ) {
    throw new ProfileInterpreterError(
      `Invalid execution context field: ${name}`,
    );
  }
}

function validateContext(
  profile: ToolProfileV1,
  context: ProfileExecutionContext,
): void {
  if (
    context.sessionPolicy !== "stateless" &&
    context.sessionPolicy !== "durable"
  )
    throw new ProfileInterpreterError("Invalid session policy");
  if (!Object.hasOwn(profile.sandbox.mappings, context.executionPolicy))
    throw new ProfileInterpreterError("Invalid execution policy");
  if (
    typeof context.prompt !== "string" ||
    new TextEncoder().encode(context.prompt).byteLength >
      PROFILE_INTERPRETER_LIMITS.inputBytes
  )
    throw new ProfileInterpreterError("Prompt exceeds the Engine input limit");
  requireContextText("workingDirectory", context.workingDirectory);
  requireContextText("home", context.home);
  requireContextText("workerStateDirectory", context.workerStateDirectory);
  if (
    !Number.isSafeInteger(context.assignmentTimeoutMs) ||
    context.assignmentTimeoutMs < 1 ||
    context.assignmentTimeoutMs > 24 * 60 * 60 * 1000
  ) {
    throw new ProfileInterpreterError("Invalid assignment timeout");
  }
  if (context.model !== undefined) {
    requireContextText("model", context.model);
    if (context.model.length > TOOL_PROFILE_LIMITS.shortStringLength)
      throw new ProfileInterpreterError(
        "Model identifier exceeds the Engine limit",
        "model_not_supported",
      );
    if (!profile.model.supported)
      throw new ProfileInterpreterError(
        "Profile does not support model selection",
        "model_not_supported",
      );
    if (
      profile.model.unknownModelPolicy === "profile_allowlist" &&
      !profile.model.allowlist?.includes(context.model)
    ) {
      throw new ProfileInterpreterError(
        "Model is outside the Profile allowlist",
        "model_not_supported",
      );
    }
  }
  if (context.reasoningEffort !== undefined) {
    requireContextText("reasoningEffort", context.reasoningEffort);
    if (context.reasoningEffort.length > TOOL_PROFILE_LIMITS.shortStringLength)
      throw new ProfileInterpreterError(
        "Reasoning effort exceeds the Engine limit",
        "model_not_supported",
      );
  }
  if (context.reasoningEffort !== undefined) {
    const selected = profile.model.catalog?.find(
      (entry) =>
        entry.id ===
        (context.model ?? profile.model.executionOptions?.defaultModelId),
    );
    const values =
      selected?.supportedReasoningEfforts ??
      profile.model.supportedReasoningEfforts;
    // Without a declared list the efforts come from runtime discovery (for
    // example Grok's per-model effort probe); the Engine checks the request
    // against that discovered catalog, which this interpreter cannot see.
    const discoveredOnly =
      values === undefined && profile.model.discovery !== undefined;
    if (
      profile.model.executionOptions?.effortSupported === false ||
      (!discoveredOnly && !(values ?? []).includes(context.reasoningEffort))
    ) {
      throw new ProfileInterpreterError(
        "Effort is not supported by the selected model/Profile",
        "model_not_supported",
      );
    }
  }
  if (
    context.sessionId !== undefined &&
    profile.model.executionOptions?.modelSwitchSupported === false &&
    (context.model ?? null) !== (context.sessionModel ?? null)
  ) {
    throw new ProfileInterpreterError(
      "Profile cannot change model within this native session",
      "session_resume_failed",
    );
  }
  if (context.sessionId !== undefined) {
    requireContextText("sessionId", context.sessionId);
    if (context.sessionId.length > PROFILE_INTERPRETER_LIMITS.sessionIdLength)
      throw new ProfileInterpreterError(
        "Session identifier exceeds the Engine limit",
        "session_resume_failed",
      );
    if (!profile.session.supported)
      throw new ProfileInterpreterError(
        "Profile does not support session resume",
        "session_resume_failed",
      );
  }
  if (context.sessionPolicy === "durable" && !profile.session.supported)
    throw new ProfileInterpreterError(
      "Profile does not support durable sessions",
      "session_resume_failed",
    );
}

function timeoutValues(
  profile: ToolProfileV1,
  context: ProfileExecutionContext,
) {
  const providerTimeoutMs = Math.max(
    1,
    context.assignmentTimeoutMs - profile.timeout.providerReserveMs,
  );
  return {
    timeoutMs: String(providerTimeoutMs),
    timeoutSeconds: String(Math.max(1, Math.ceil(providerTimeoutMs / 1000))),
  };
}

/** Extracts the informational CLI version using the schema's fixed SemVer pattern. */
export function extractProfileProviderVersion(
  profileInput: ToolProfileV1,
  input: ProviderVersionProbeInput,
): NormalizedProviderVersion {
  const profile = validateToolProfileV1(profileInput);
  if (input.exitCode !== 0) {
    return {
      version: null,
      supported: false,
      issueCode: "unsupported_provider_tool_version",
    };
  }
  const output =
    profile.providerTool.versionProbe.source === "stderr"
      ? (input.stderr ?? "")
      : input.stdout;
  const match =
    /(?<![A-Za-z0-9])v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)(?![A-Za-z0-9])/.exec(
      output,
    );
  const version = match?.[1] ?? null;
  if (version === null) {
    return {
      version: null,
      supported: false,
      issueCode: "unsupported_provider_tool_version",
    };
  }
  return { version, supported: true, issueCode: null };
}

/** Evaluates passive readiness from bounded synthetic provider/config evidence. */
export function interpretProfileReadiness(
  profileInput: ToolProfileV1,
  input: ProfileReadinessInput,
): NormalizedProfileReadiness {
  const parsedProfile = validateToolProfileV1(profileInput);
  const version = extractProfileProviderVersion(
    parsedProfile,
    input.versionProbe,
  );
  const checks: NormalizedReadinessCheck[] = [
    {
      code: "provider_tool_version",
      status: version.supported ? "passed" : "failed",
    },
  ];
  let issueCode = version.issueCode;
  if (!version.supported) {
    return {
      ready: false,
      providerVersion: version.version,
      checks,
      issueCode,
    };
  }
  const profile = resolveToolProfileCompatibility(
    parsedProfile,
    version.version!,
  ).profile;

  for (const command of profile.probe.passive.checks) {
    const exitCode = input.commandExitCodes?.[command.id];
    const passed =
      Number.isInteger(exitCode) &&
      command.successExitCodes.includes(exitCode as number);
    checks.push({
      code: command.id.replaceAll("-", "_"),
      status: passed ? "passed" : "failed",
    });
    if (!passed) issueCode ??= command.failureIssueCode;
  }

  const environment = input.environment ?? {};
  for (const config of profile.probe.passive.configChecks) {
    const source = input.configFiles?.[config.relativePath];
    let status: NormalizedReadinessCheck["status"];
    let configIssue: ProfileIssueCode | null = null;
    if (source === undefined) {
      status = config.onMissing;
      if (status === "failed") configIssue = "provider_failure";
    } else if (new TextEncoder().encode(source).byteLength > config.maxBytes) {
      status = config.onInvalid;
      if (status === "failed") configIssue = "provider_failure";
    } else {
      let decoded: unknown;
      try {
        decoded = JSON.parse(source);
      } catch {
        status = config.onInvalid;
        if (status === "failed") configIssue = "provider_failure";
        checks.push({ code: config.id, status });
        issueCode ??= configIssue;
        continue;
      }
      const matchingRule = config.rules.find((rule) =>
        matchesConditions(decoded, rule.when),
      );
      if (matchingRule) {
        const required = matchingRule.requiredEnvironmentAny;
        if (
          required &&
          !required.some((name) => (environment[name] ?? "").length > 0)
        ) {
          status = matchingRule.whenEnvironmentMissing?.result ?? "failed";
          if (status === "failed") {
            configIssue =
              matchingRule.whenEnvironmentMissing?.issueCode ??
              "provider_authentication_required";
          }
        } else {
          status = matchingRule.result;
          if (status === "failed") {
            configIssue =
              matchingRule.issueCode ?? "provider_authentication_required";
          }
        }
      } else {
        status = config.onNoMatch.result;
        if (status === "failed") {
          configIssue =
            config.onNoMatch.issueCode ?? "provider_authentication_required";
        }
      }
    }
    checks.push({ code: config.id, status });
    if (
      status === "failed" ||
      (status === "warning" &&
        configIssue === "provider_authentication_required")
    ) {
      issueCode ??= configIssue ?? "provider_failure";
    }
  }

  return {
    ready: issueCode === null,
    providerVersion: version.version,
    checks,
    issueCode,
  };
}

function expandTemplate(
  value: string,
  profile: ToolProfileV1,
  context: ProfileExecutionContext,
  additionalDirectory?: string,
): string {
  const timeout = timeoutValues(profile, context);
  const substitutions: Record<string, string | undefined> = {
    prompt: context.prompt,
    model: context.model,
    reasoningEffort:
      context.reasoningEffort === undefined
        ? undefined
        : (profile.model.executionOptions?.effortMapping?.[
            context.reasoningEffort
          ] ?? context.reasoningEffort),
    sessionId: context.sessionId,
    timeoutMs: timeout.timeoutMs,
    timeoutSeconds: timeout.timeoutSeconds,
    workingDirectory: context.workingDirectory,
    home: context.home,
    workerStateDirectory: context.workerStateDirectory,
    additionalDirectory,
  };
  return value.replace(/\{\{([^{}]+)\}\}/g, (_whole, name: string) => {
    const replacement = substitutions[name];
    if (replacement === undefined)
      throw new ProfileInterpreterError(
        `Placeholder is unavailable in this execution: ${name}`,
      );
    return replacement;
  });
}

type ArgumentList = ToolProfileV1["execution"]["arguments"];

/** Expands a Profile's argv array without parsing or invoking a shell. */
export function expandExecutionArguments(
  profileInput: ToolProfileV1,
  context: ProfileExecutionContext,
  argumentsOverride?: ArgumentList,
): string[] {
  const parsedProfile = validateToolProfileV1(profileInput);
  const compatibleProfile = context.providerVersion
    ? resolveToolProfileCompatibility(parsedProfile, context.providerVersion)
        .profile
    : parsedProfile;
  const profile = argumentsOverride
    ? validateToolProfileV1({
        ...compatibleProfile,
        execution: {
          ...compatibleProfile.execution,
          arguments: argumentsOverride,
        },
        compatibilityOverrides: [],
      })
    : compatibleProfile;
  validateContext(profile, context);
  const sourceArguments = profile.execution.arguments;
  const directories = context.additionalDirectories ?? [];
  if (
    directories.length > 0 &&
    !sourceArguments.some(
      (part) =>
        typeof part === "object" && "forEachAdditionalDirectory" in part,
    )
  )
    throw new ProfileInterpreterError(
      "Worker Profile does not support additional folders",
    );
  const output: string[] = [];
  for (const part of sourceArguments) {
    if (typeof part === "string") {
      output.push(expandTemplate(part, profile, context));
      continue;
    }
    if ("forEachAdditionalDirectory" in part) {
      for (const directory of directories)
        output.push(
          ...part.forEachAdditionalDirectory.map((value) =>
            expandTemplate(value, profile, context, directory),
          ),
        );
    } else if ("sandboxPolicyMapping" in part) {
      output.push(
        ...profile.sandbox.mappings[context.executionPolicy].map((value) =>
          expandTemplate(value, profile, context),
        ),
      );
    } else if ("modelArguments" in part) {
      if (context.model !== undefined)
        output.push(
          ...profile.model.arguments.map((value) =>
            expandTemplate(value, profile, context),
          ),
        );
    } else if ("sessionResumeArguments" in part) {
      if (context.sessionId !== undefined)
        output.push(
          ...profile.session.resumeArguments.map((value) =>
            expandTemplate(value, profile, context),
          ),
        );
    } else if ("providerTimeoutArguments" in part) {
      output.push(
        ...profile.timeout.providerArguments.map((value) =>
          expandTemplate(value, profile, context),
        ),
      );
    } else if ("autoCompactionArguments" in part) {
      output.push(
        ...(profile.context?.autoCompaction?.arguments ?? []).map((value) =>
          expandTemplate(value, profile, context),
        ),
      );
    } else if ("ifPresent" in part) {
      const present =
        part.ifPresent === "model"
          ? context.model !== undefined
          : part.ifPresent === "sessionId"
            ? context.sessionId !== undefined
            : context.reasoningEffort !== undefined;
      if (present)
        output.push(
          ...part.values.map((value) =>
            expandTemplate(value, profile, context),
          ),
        );
    } else if ("ifAbsent" in part) {
      if (
        context.sessionId === undefined &&
        context.sessionPolicy === part.ifSessionPolicy
      )
        output.push(
          ...part.values.map((value) =>
            expandTemplate(value, profile, context),
          ),
        );
    }
    if (output.length > TOOL_PROFILE_LIMITS.arguments)
      throw new ProfileInterpreterError(
        "Expanded argument count exceeds the Engine limit",
      );
  }
  if (output.length > TOOL_PROFILE_LIMITS.arguments)
    throw new ProfileInterpreterError(
      "Expanded argument count exceeds the Engine limit",
    );
  const argumentBytes = output.reduce(
    (total, item) => total + new TextEncoder().encode(item).byteLength,
    0,
  );
  if (argumentBytes > PROFILE_INTERPRETER_LIMITS.argumentBytes)
    throw new ProfileInterpreterError(
      "Expanded argument bytes exceed the Engine limit",
    );
  return output;
}

function expandJsonTemplate(
  template: Record<string, unknown>,
  profile: ToolProfileV1,
  context: ProfileExecutionContext,
): Record<string, unknown> {
  const root: Record<string, unknown> = Object.create(null) as Record<
    string,
    unknown
  >;
  const stack: Array<{
    source: Record<string, unknown> | unknown[];
    target: Record<string, unknown> | unknown[];
  }> = [{ source: template, target: root }];
  while (stack.length > 0) {
    const frame = stack.pop()!;
    const keys = Array.isArray(frame.source)
      ? frame.source.map((_value, index) => String(index))
      : Object.keys(frame.source);
    for (const key of keys) {
      const sourceValue = Array.isArray(frame.source)
        ? frame.source[Number(key)]
        : Object.hasOwn(frame.source, key)
          ? frame.source[key]
          : undefined;
      let expanded: unknown;
      if (typeof sourceValue === "string") {
        expanded = expandTemplate(sourceValue, profile, context);
      } else if (Array.isArray(sourceValue)) {
        const child: unknown[] = new Array(sourceValue.length);
        if (Array.isArray(frame.target)) frame.target[Number(key)] = child;
        else frame.target[key] = child;
        stack.push({ source: sourceValue, target: child });
        continue;
      } else if (sourceValue !== null && typeof sourceValue === "object") {
        const child: Record<string, unknown> = Object.create(null) as Record<
          string,
          unknown
        >;
        if (Array.isArray(frame.target)) frame.target[Number(key)] = child;
        else frame.target[key] = child;
        stack.push({
          source: sourceValue as Record<string, unknown>,
          target: child,
        });
        continue;
      } else {
        expanded = sourceValue;
      }
      if (Array.isArray(frame.target)) frame.target[Number(key)] = expanded;
      else frame.target[key] = expanded;
    }
  }
  return root;
}

/** Produces provider stdin as bytes represented by a string; no shell or process I/O is involved. */
export function constructProviderStdin(
  profileInput: ToolProfileV1,
  context: ProfileExecutionContext,
): string {
  const parsedProfile = validateToolProfileV1(profileInput);
  const profile = context.providerVersion
    ? resolveToolProfileCompatibility(parsedProfile, context.providerVersion)
        .profile
    : parsedProfile;
  validateContext(profile, context);
  let value: string;
  if (profile.execution.stdin.mode === "raw_text") {
    value = expandTemplate(profile.execution.stdin.value, profile, context);
  } else {
    const object = expandJsonTemplate(
      profile.execution.stdin.value,
      profile,
      context,
    );
    value = JSON.stringify(object);
    if (profile.execution.stdin.appendNewline) value += "\n";
  }
  if (
    new TextEncoder().encode(value).byteLength >
    PROFILE_INTERPRETER_LIMITS.inputBytes
  )
    throw new ProfileInterpreterError(
      "Provider stdin exceeds the Engine limit",
    );
  return value;
}

/** Reads only own JSON properties through the bounded selector grammar. */
export function selectProfileValue(root: unknown, path: string): unknown {
  if (
    !/^\$(?:\.[A-Za-z_][A-Za-z0-9_]*)+$/.test(path) ||
    path.length > TOOL_PROFILE_LIMITS.selectorLength
  )
    throw new ProfileInterpreterError("Invalid Profile selector");
  const properties = path.slice(2).split(".");
  if (
    properties.length > TOOL_PROFILE_LIMITS.selectorDepth ||
    properties.some((key) =>
      ["__proto__", "prototype", "constructor"].includes(key),
    )
  )
    throw new ProfileInterpreterError("Profile selector exceeds Engine limits");
  let current = root;
  for (const property of properties) {
    if (
      current === null ||
      typeof current !== "object" ||
      !Object.hasOwn(current, property)
    )
      return undefined;
    current = (current as Record<string, unknown>)[property];
  }
  return current;
}

function matchesConditions(
  root: unknown,
  when: ToolProfileV1["progress"][number]["when"],
): boolean {
  for (const condition of when) {
    const value = selectProfileValue(root, condition.selector);
    if (condition.kind === "equals" && value !== condition.value) return false;
    if (
      condition.kind === "not_equals" &&
      (value === undefined || value === condition.value)
    )
      return false;
    if (
      condition.kind === "one_of" &&
      !condition.values.some((candidate) => candidate === value)
    )
      return false;
    if (condition.kind === "type_is") {
      const actualType = Array.isArray(value)
        ? "array"
        : value === null
          ? "null"
          : typeof value;
      if (actualType !== condition.value) return false;
    }
    if (
      condition.kind === "exists" &&
      (value !== undefined) !== condition.exists
    )
      return false;
  }
  return true;
}

function parseOutput(
  profile: ToolProfileV1,
  stdout: string,
): { events: unknown[]; plainText: string | null } {
  const bytes = new TextEncoder().encode(stdout).byteLength;
  if (bytes > PROFILE_INTERPRETER_LIMITS.outputBytes)
    throw new ProfileInterpreterError(
      "Provider output exceeds the Engine limit",
    );
  if (profile.execution.output.mode === "plain_text")
    return { events: [], plainText: stdout };
  if (profile.execution.output.mode === "single_json") {
    try {
      return { events: [JSON.parse(stdout)], plainText: null };
    } catch {
      throw new ProfileInterpreterError("Provider returned invalid JSON");
    }
  }
  const events: unknown[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    if (line.length === 0) continue;
    if (
      new TextEncoder().encode(line).byteLength >
      PROFILE_INTERPRETER_LIMITS.outputLineBytes
    )
      throw new ProfileInterpreterError(
        "Provider JSONL line exceeds the Engine limit",
      );
    try {
      events.push(JSON.parse(line));
    } catch {
      throw new ProfileInterpreterError("Provider returned invalid JSONL");
    }
    if (events.length > PROFILE_INTERPRETER_LIMITS.outputEvents)
      throw new ProfileInterpreterError(
        "Provider event count exceeds the Engine limit",
      );
  }
  return { events, plainText: null };
}

function boundedText(value: string): string {
  const bytes = new TextEncoder().encode(value);
  if (bytes.byteLength <= PROFILE_INTERPRETER_LIMITS.finalTextBytes)
    return value;
  return new TextDecoder().decode(
    bytes.slice(0, PROFILE_INTERPRETER_LIMITS.finalTextBytes),
  );
}

const stderrMatchers: Record<string, RegExp> = {
  session_unavailable:
    /(?:session|thread|conversation).{0,60}(?:not found|does not exist|no longer exists|unavailable)|(?:no such|unknown) (?:session|thread|conversation)/i,
  cancelled: /cancelled|canceled|interrupted|user interrupted/i,
  deadline_exceeded: /timeout|timed out|deadline exceeded/i,
  provider_tool_unavailable: /enoent|executable not found|command not found/i,
  provider_authentication_required:
    /unauthori[sz]ed|authentication required|not authenticated|sign in|login required|credentials? (missing|expired|invalid)|token expired|api key.{0,40}(not set|missing|invalid|revoked|expired)/i,
  permission_denied:
    /permission denied|approval denied|permission.{0,60}(configuration|settings)|sandbox.*(denied|blocked)|tool.*(denied|rejected)/i,
  quota_exhausted:
    /quota.{0,40}(?:exceeded|exhausted)|(?:exceeded|exhausted).{0,40}quota|insufficient[_ -]quota|usage[_ -]limit[_ -](?:reached|exceeded)|(?:reached|exceeded|exhausted|hit).{0,40}(?:usage|session|weekly|daily|monthly|spending|rate) limit|(?:usage|session|weekly|daily|monthly|spending|rate|free) limit.{0,40}(?:reached|exceeded|exhausted)|rate[_ -]limit(?:ed|[_ -]error|[_ -]exceeded)|you(?:['’]ve| have) (?:hit|reached) (?:all |any |your )?.{0,40}limit|credits? balance is too low|resource_exhausted|resource has been exhausted|free[_ -]usage[_ -]exhausted|you(?:['’]ve| have) used (?:all|up) .{0,40}usage|too many requests/i,
  provider_unavailable:
    /provider unavailable|service unavailable|temporarily unavailable/i,
  context_limit_exceeded:
    /prompt is too long|context[_ -]length[_ -]exceeded|context[_ -]window[_ -]exceeded|exceeds the context window|ran out of room in the model's context window|maximum context length/i,
  provider_failure: /.+/s,
};

/** True when a failed run's text carries one of the Profile's overflow markers. */
export function contextOverflowMatched(
  profile: ToolProfileV1,
  texts: readonly (string | null | undefined)[],
): boolean {
  const markers = profile.context?.overflow?.markers ?? [];
  if (markers.length === 0) return false;
  const haystack = texts
    .filter((text): text is string => typeof text === "string")
    .join("\n")
    .toLowerCase();
  return markers.some((marker) => haystack.includes(marker.toLowerCase()));
}

function mappedIssue(
  profile: ToolProfileV1,
  input: ProfileExecutionInput,
  events: unknown[],
  terminalStatus: string | null,
  providerErrorPresent: boolean,
  providerErrorText: string,
  terminalObserved: boolean,
): ProfileIssueCode {
  if (input.cancelled) return "cancelled";
  if (input.timedOut) return "deadline_exceeded";
  if (
    contextOverflowMatched(profile, [
      input.stderr,
      providerErrorText,
      terminalStatus,
    ])
  )
    return "context_limit_exceeded";
  for (const mapping of profile.errors.mappings) {
    const evidence = mapping.evidence;
    let matches = false;
    if (evidence.kind === "exit_code")
      matches = input.exitCode === evidence.value;
    else if (evidence.kind === "terminal_status")
      matches = terminalStatus === evidence.value;
    else if (evidence.kind === "missing_terminal") matches = !terminalObserved;
    else if (evidence.kind === "stderr_pattern")
      matches =
        stderrMatchers[evidence.patternId]?.test(
          providerErrorText || input.stderr || "",
        ) ?? false;
    else if (evidence.kind === "structured_provider_error") {
      matches =
        providerErrorPresent ||
        events.some(
          (event) => selectProfileValue(event, evidence.selector) !== undefined,
        );
    }
    if (matches) return mapping.issueCode;
  }
  return "provider_failure";
}

function failedResult(issueCode: ProfileIssueCode): NormalizedProfileResult {
  return {
    terminal: "failure",
    finalText: null,
    sessionId: null,
    terminalStatus: null,
    progress: [],
    issueCode,
  };
}

/** Pure Profile + provider-output interpreter. It never starts processes or reads files. */
export function interpretProfileExecution(
  profileInput: ToolProfileV1,
  input: ProfileExecutionInput,
): NormalizedProfileResult {
  const parsedProfile = validateToolProfileV1(profileInput);
  const profile = input.context.providerVersion
    ? resolveToolProfileCompatibility(
        parsedProfile,
        input.context.providerVersion,
      ).profile
    : parsedProfile;
  if (input.cancelled) return failedResult("cancelled");
  if (input.timedOut) return failedResult("deadline_exceeded");
  if (
    !Number.isSafeInteger(input.exitCode) ||
    input.exitCode < 0 ||
    input.exitCode > 255
  )
    return failedResult("provider_failure");
  try {
    validateContext(profile, input.context);
  } catch (error) {
    return failedResult(
      error instanceof ProfileInterpreterError
        ? error.issueCode
        : "provider_failure",
    );
  }
  let decoded: { events: unknown[]; plainText: string | null };
  try {
    decoded = parseOutput(profile, input.stdout);
  } catch (error) {
    return failedResult(
      error instanceof ProfileInterpreterError
        ? error.issueCode
        : "provider_failure",
    );
  }
  let finalText =
    decoded.plainText === null ? null : boundedText(decoded.plainText);
  let sessionId: string | null = null;
  let terminalStatus: string | null = null;
  let providerErrorPresent = false;
  let providerErrorText = "";
  let markSuccess = false;
  let markFailure = false;
  const progress: NormalizedProfileProgress[] = [];
  const recordSession = (value: unknown): boolean => {
    if (
      typeof value !== "string" ||
      value.trim().length === 0 ||
      value.length > PROFILE_INTERPRETER_LIMITS.sessionIdLength
    )
      return true;
    if (sessionId !== null && sessionId !== value) return false;
    if (
      input.context.sessionId &&
      profile.session.requireObservedIdMatch &&
      input.context.sessionId !== value
    )
      return false;
    sessionId = value;
    return true;
  };
  for (const event of decoded.events) {
    if (
      profile.session.supported &&
      profile.session.extract &&
      !recordSession(selectProfileValue(event, profile.session.extract))
    )
      return failedResult("session_resume_failed");
    for (const rule of profile.execution.events) {
      if (!matchesConditions(event, rule.when)) continue;
      for (const action of rule.actions) {
        if (action.type === "set_session") {
          const value = selectProfileValue(event, action.selector);
          if (!recordSession(value))
            return failedResult("session_resume_failed");
        } else if (action.type === "set_final_text") {
          const value = selectProfileValue(event, action.selector);
          if (typeof value === "string") finalText = boundedText(value);
        } else if (action.type === "append_final_text") {
          const value = selectProfileValue(event, action.selector);
          if (typeof value === "string")
            finalText = boundedText((finalText ?? "") + value);
        } else if (action.type === "clear_final_text") {
          finalText = null;
        } else if (action.type === "set_terminal_status") {
          const value = selectProfileValue(event, action.selector);
          if (typeof value === "string") terminalStatus = value.slice(0, 256);
        } else if (action.type === "set_provider_error") {
          const value = selectProfileValue(event, action.selector);
          if (
            value !== undefined &&
            value !== null &&
            value !== false &&
            value !== ""
          ) {
            providerErrorPresent = true;
            providerErrorText =
              typeof value === "string"
                ? value.slice(0, 4096)
                : "Provider reported a structured error";
          }
        } else if (action.type === "emit_progress") {
          progress.push({
            percentage: action.percentage,
            messageKey: action.messageKey,
          });
        } else if (action.type === "mark_success") {
          markSuccess = true;
        } else if (action.type === "mark_failure") {
          markFailure = true;
        }
      }
    }
    const progressRule = profile.progress.find((rule) =>
      matchesConditions(event, rule.when),
    );
    if (progressRule)
      progress.push({
        percentage: progressRule.percentage,
        messageKey: progressRule.messageKey,
      });
  }
  const terminalObserved =
    markSuccess ||
    markFailure ||
    terminalStatus !== null ||
    providerErrorPresent;
  const textValid = finalText !== null && finalText.length > 0;
  const implicitPlainTextSuccess =
    profile.execution.output.mode === "plain_text" && input.exitCode === 0;
  const successful =
    !input.cancelled &&
    !input.timedOut &&
    input.exitCode === 0 &&
    !markFailure &&
    !providerErrorPresent &&
    (markSuccess || implicitPlainTextSuccess) &&
    textValid;
  if (successful) {
    if (
      input.context.sessionPolicy === "durable" &&
      profile.session.requireObservedIdMatch
    ) {
      if (
        sessionId === null ||
        (input.context.sessionId !== undefined &&
          sessionId !== input.context.sessionId)
      )
        return failedResult("session_resume_failed");
    }
    return {
      terminal: "success",
      finalText,
      sessionId,
      terminalStatus,
      progress,
      issueCode: null,
    };
  }
  return {
    terminal: "failure",
    finalText,
    sessionId,
    terminalStatus,
    progress,
    issueCode: mappedIssue(
      profile,
      input,
      decoded.events,
      terminalStatus,
      providerErrorPresent,
      providerErrorText,
      terminalObserved,
    ),
  };
}
