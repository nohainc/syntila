import { renameArtifacts } from "./rename-hygiene.mjs";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { forbiddenArchitecture } from "./v8-architecture-rules.mjs";

const failures = [];

if (existsSync("workers")) {
  failures.push("The retired top-level workers/ runtime tree must be absent.");
}

function readRequired(file) {
  if (!existsSync(file)) {
    failures.push(`Required v8 architecture file is missing: ${file}`);
    return "";
  }
  return readFileSync(file, "utf8");
}

const assignment = readRequired("apps/workspace/lib/worker_executor.dart");
const runtime = readRequired("apps/workspace/lib/workspace_runtime.dart");
const catalogCoordinator = readRequired(
  "apps/workspace/lib/worker_catalog_coordinator.dart",
);
const _workspaceConfig = readRequired("apps/workspace/lib/workspace.dart");
const workspaceRegistration = readRequired(
  "apps/workspace/lib/workspace_configuration.dart",
);
const architecture = readRequired("ARCHITECTURE.md");
const architectureV8 = readRequired("docs/architecture/ARCHITECTURE_V8.md");
const schema = readRequired("apps/cloud/migrations-v8/0001_syntila_v8.sql");
const appRouter = readRequired("apps/cloud/src/routes/router.ts");
const axData = readRequired("apps/app/lib/src/ax/ax_data.dart");
const cloudWrangler = readRequired("apps/cloud/wrangler.jsonc");
const infraWrangler = readRequired("infra/cloudflare/app.wrangler.jsonc");
const packageJson = JSON.parse(readRequired("package.json") || "{}");
const ciWorkflow = readRequired(".github/workflows/ci.yml");
const deployCloud = readRequired(".github/workflows/deploy-cloud.yml");
const deploySite = readRequired(".github/workflows/deploy-site.yml");
const releaseMacos = readRequired(".github/workflows/release-macos.yml");
const nightlyWorkflow = readRequired(".github/workflows/nightly.yml");
const checkSiteAction = readRequired(".github/actions/check-site/action.yml");
const cloudPackage = JSON.parse(
  readRequired("apps/cloud/package.json") || "{}",
);
const workspacePackages = readRequired("pnpm-workspace.yaml");
const lockfile = readRequired("pnpm-lock.yaml");
const wranglerTypes = readRequired("apps/cloud/worker-configuration.d.ts");
const workspacePubspec = readRequired("apps/workspace/pubspec.yaml");
const workspaceRuntimePackage = JSON.parse(
  readRequired("packages/workspace-runtime-protocol/package.json") || "{}",
);

const canonicalExecutionPaths = [
  "AX → Cloud → Workspace → CLI Worker Engine → current Worker Profile → provider CLI",
  "Syntila → Cloud → Workspace → CLI Worker Engine → current Worker Profile → provider CLI",
];
const canonicalV8ExecutionPath =
  "AX → Cloud → Workspace → CLI Worker Engine → signed Tool Profile → provider CLI";
const architectureProhibitions = [
  [
    "provider-specific Worker executable",
    "provider_specific_worker_executable: true",
  ],
  ["browser/Web AI Worker", "browser_or_web_ai_worker: true"],
  ["Interactive Connector", "interactive_connector: true"],
  [
    "Syntila-managed provider credentials",
    "syntila_managed_provider_credentials: true",
  ],
  ["agent-managed runtime", "agent_runtime: true"],
  ["ConfiguredWorker product entity", "configured_worker_product_entity: true"],
  [
    "pre-v8 Goal/Phase/Task orchestration",
    "pre_v8_goal_phase_task_orchestration: true",
  ],
  [
    "compatibility API for unreleased architectures",
    "compatibility_api_for_unreleased_architecture: true",
  ],
];

if (!canonicalExecutionPaths.some((path) => architecture.includes(path))) {
  failures.push("ARCHITECTURE.md must state the canonical v8 execution path.");
}
if (
  !architecture.includes(
    "docs/architecture/ARCHITECTURE_V8.md#architecture-contract",
  )
) {
  failures.push(
    "ARCHITECTURE.md must link to the normative v8 architecture contract.",
  );
}
if (!architectureV8.includes(canonicalV8ExecutionPath)) {
  failures.push("Architecture v8 must state the canonical v8 execution path.");
}
for (const [label, declaration] of architectureProhibitions) {
  if (!architectureV8.includes(declaration)) {
    failures.push(`Architecture v8 is missing exclusion: ${label}.`);
  }
}

const sourceRoots = [
  "apps/cloud/src",
  "apps/cloud/migrations-v8",
  "apps/workspace/lib",
  "apps/app/lib",
  "engines/cli_worker/lib",
  "packages/core/src",
  "packages/protocol/src",
  "packages/workspace-runtime-protocol/src",
  "packages/dart/protocol/lib",
  "packages/security/src",
  "packages/tool-profile/src",
].filter(existsSync);
const sourceExtensions = new Set([
  ".dart",
  ".json",
  ".js",
  ".mjs",
  ".sql",
  ".ts",
  ".yaml",
  ".yml",
]);
if (existsSync("apps/host") || existsSync("packages/host-protocol")) {
  failures.push(
    "Host-named application or protocol package directories remain.",
  );
}
if (
  !workspacePubspec.includes("name: syntila_workspace") ||
  workspaceRuntimePackage.name !== "@syntila/workspace-runtime-protocol"
) {
  failures.push(
    "Workspace application and runtime protocol packages must use Workspace names.",
  );
}
if (
  !workspaceRegistration.includes("SYNTILA_WORKSPACE_RUNTIME_ID") ||
  !workspaceRegistration.includes("workspace-registration.json")
) {
  failures.push(
    "Workspace environment and persisted registration names must be canonical.",
  );
}

if (existsSync("apps/app/lib/src/studio")) {
  failures.push("The AX source tree must use current AX naming, not studio/.");
}
for (const [label, pattern] of forbiddenArchitecture.slice(0, 3)) {
  if (pattern.test(appRouter))
    failures.push(`${label} remains in Cloud routes.`);
}
for (const [label, pattern] of [
  forbiddenArchitecture[0],
  forbiddenArchitecture[1],
  forbiddenArchitecture[3],
]) {
  if (pattern.test(axData))
    failures.push(`${label} remains in the AX API client.`);
}

function* sourceFiles(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = `${directory}/${entry.name}`;
    if (entry.isDirectory()) yield* sourceFiles(path);
    else if (sourceExtensions.has(path.slice(path.lastIndexOf("."))))
      yield path;
  }
}

for (const root of sourceRoots) {
  for (const path of sourceFiles(root)) {
    const source = readFileSync(path, "utf8");
    for (const artifact of renameArtifacts(source)) {
      failures.push(
        `${path}:${artifact.line}: redundant operand: ${artifact.expression}`,
      );
    }
    for (const [label, pattern] of forbiddenArchitecture) {
      if (
        label === "Profile Lab draft class under Workspace" &&
        path === "apps/workspace/lib/development_tool_profiles.dart"
      )
        continue;
      if (
        (label === "Profile Lab import in Workspace or AX" ||
          label === "Profile Lab draft class under Workspace" ||
          label === "desktop application private key signing material") &&
        (path.startsWith("apps/cloud") ||
          path.startsWith("packages/security") ||
          path.startsWith("apps/profile_lab"))
      ) {
        continue;
      }
      if (pattern.test(source)) {
        failures.push(
          `${path} retains retired architecture reference ${label}.`,
        );
      }
    }
  }
}

const requiredAssignment = [
  ["logical Worker resolution", /resolveLogicalWorker/],
  ["Tool Profile assignment executor", /executeWithToolProfile/],
  ["required Profile resolution", /ToolProfileResolver\(/],
  ["CLI Worker Engine execution", /supervisor\.execute\(/],
];
for (const [label, pattern] of requiredAssignment) {
  if (
    !pattern.test(assignment) &&
    !pattern.test(runtime) &&
    !pattern.test(catalogCoordinator)
  ) {
    failures.push(`Workspace assignment path is missing ${label}.`);
  }
}

for (const [label, source] of [
  ["Workspace assignment handler", assignment],
  ["Workspace runtime", runtime],
]) {
  if (
    /resolveV7Adapter|V7AdapterPackageStore|WorkerProcessExecutor/.test(source)
  ) {
    failures.push(`${label} references a retired assignment executor.`);
  }
}

for (const [label, config] of [
  ["Cloud Wrangler configuration", cloudWrangler],
  ["production Wrangler configuration", infraWrangler],
]) {
  if (
    !/["']?migrations_dir["']?\s*:\s*["'][^"']*migrations-v8["']/.test(config)
  ) {
    failures.push(`${label} must select migrations-v8.`);
  }
}

for (const table of [
  "worker_scheduling",
  "worker_scheduling_audit",
  "workspace_releases",
  "tool_profile_releases",
]) {
  if (
    !new RegExp(`CREATE TABLE (?:IF NOT EXISTS )?${table}\\b`, "i").test(schema)
  ) {
    failures.push(`The v8 schema is missing ${table}.`);
  }
}
for (const retiredName of [
  "v7_worker_scheduling",
  "v7_worker_scheduling_audit",
  "host_releases",
  "worker_releases",
  "worker_versions",
  "allowed_configured_worker_ids_json",
  "credential_profiles",
  "ai_accounts",
  "host_workspace_bindings",
  "thread_checkouts",
  "thread_checkpoints",
  "thread_current_checkpoints",
  "thread_diff_artifacts",
  "workspace_pairing_intents",
  "workspace_enrollments",
  "checkout_id",
  "require_checkout",
]) {
  if (schema.includes(retiredName)) {
    failures.push(`The v8 schema retains historical name ${retiredName}.`);
  }
}

const scripts = packageJson.scripts ?? {};
// Follow local check composition without weakening the required leaf checks.
function expandCheck(name, active = new Set()) {
  if (active.has(name)) throw new Error(`Cyclic check script: ${name}`);
  const next = new Set([...active, name]);
  const command = scripts[name] ?? "";
  return command.replace(
    /\bpnpm (check(?::[\w-]+)?)(?![\w:-])/g,
    (match, child) => `${match} ${expandCheck(child, next)}`,
  );
}
const completeCheck = expandCheck("check");

if (!scripts["v8:architecture-check"]) {
  failures.push("package.json must expose v8:architecture-check.");
}
for (const step of ["pnpm v8:architecture-check", "pnpm build", "pnpm test"]) {
  if (!completeCheck.includes(step)) {
    failures.push(`pnpm check must include ${step}.`);
  }
}
for (const name of Object.keys(scripts)) {
  if (/^(?:v5:workspace-terminology|v6:|v7:)/.test(name)) {
    failures.push(
      `package.json retains a historical architecture check: ${name}.`,
    );
  }
}
for (const job of [
  "changes",
  "static",
  "cloud",
  "dart-packages",
  "app",
  "workspace",
  "profile-lab",
  "engine",
  "site",
  "ci-passed",
]) {
  if (!new RegExp(`^  ${job}:`, "m").test(ciWorkflow))
    failures.push(`CI workflow is missing ${job}.`);
}
if (
  /engine-tests|profile-fixture-tests|profile-security-tests|workspace-runtime-tests|v8-runtime-e2e|work-v1-e2e|v7-runtime-e2e|worker-adapters:test|v4-architecture-guard/.test(
    ciWorkflow,
  )
) {
  failures.push(
    "CI workflow retains a historical runtime or architecture gate.",
  );
}
for (const [workflowName, workflowContent, command] of [
  ["ci", ciWorkflow, "pnpm check:static"],
  ["ci", ciWorkflow, "pnpm check:typescript"],
  ["ci", ciWorkflow, "bash scripts/check-dart-packages.sh"],
  ["ci", ciWorkflow, "bash scripts/check-flutter-app.sh app"],
  ["ci", ciWorkflow, "bash scripts/check-flutter-app.sh workspace"],
  ["ci", ciWorkflow, "bash scripts/check-flutter-app.sh profile_lab"],
  ["ci", ciWorkflow, "bash scripts/validate-engine.sh"],
  ["ci", ciWorkflow, "uses: ./.github/actions/check-site"],
  ["check-site", checkSiteAction, "./node_modules/.bin/astro check"],
  ["check-site", checkSiteAction, "./node_modules/.bin/astro build"],
  ["check-site", checkSiteAction, "./node_modules/.bin/vitest run test"],
  [
    "nightly",
    nightlyWorkflow,
    "bash scripts/build-workspace-macos.sh --debug --prepared",
  ],
  [
    "nightly",
    nightlyWorkflow,
    "bash scripts/build-profile-lab-macos.sh --release --prepared",
  ],
]) {
  if (!workflowContent.includes(command))
    failures.push(
      `${workflowName} workflow is missing validation owner: ${command}.`,
    );
}
if (!ciWorkflow.includes("workflow_dispatch:")) {
  failures.push("CI workflow is missing workflow_dispatch.");
}
if (
  !deployCloud.includes("needs: require-ci") ||
  !deployCloud.includes("run: bash scripts/ci/require-ci-success.sh") ||
  !deployCloud.includes(
    "run: flutter build web --release --dart-define=SYNTILA_API_URL=/api",
  ) ||
  !deployCloud.includes(
    "run: node scripts/production-workspace-gateway-smoke.mjs --schema-only",
  ) ||
  !deployCloud.includes(
    "run: pnpm exec wrangler deploy --config ../../infra/cloudflare/app.wrangler.jsonc",
  )
) {
  failures.push(
    "The Cloud production deployment workflow must require CI gate, build web bundle, verify schema, and deploy with wrangler.",
  );
}
if (
  !releaseMacos.includes("needs: require-ci") ||
  !releaseMacos.includes("run: bash scripts/ci/require-ci-success.sh") ||
  !releaseMacos.includes("environment: workspace-release") ||
  !releaseMacos.includes("environment: profile-lab-release")
) {
  failures.push(
    "Workspace and Profile Lab releases must require CI gate, environment authorization, and require-ci-success.",
  );
}
if (
  !deploySite.includes("branches: [main]") ||
  !deploySite.includes('"apps/site/**"') ||
  !deploySite.includes("wrangler deploy --config wrangler.production.jsonc")
) {
  failures.push(
    "Public-site production deployment must trigger on main site changes and deploy wrangler.production.jsonc.",
  );
}

for (const check of [
  "pnpm cloud:schema-check",
  "pnpm v8:architecture-check",
  "pnpm protocol:check",
  "pnpm --dir apps/cloud types:check",
  "pnpm format:check",
  "pnpm lint",
  "pnpm build",
  "pnpm test",
  "pnpm check:dart",
  "pnpm check:fixture-e2e",
]) {
  if (!completeCheck.includes(check)) {
    failures.push(`pnpm check is missing required validation: ${check}.`);
  }
}
if (
  !/wrangler types --check --config wrangler\.jsonc/.test(
    cloudPackage.scripts?.["types:check"] ?? "",
  )
) {
  failures.push(
    "Cloud must verify generated Wrangler types without rewriting them.",
  );
}
if (!infraWrangler.includes('"name": "SYNTILA_THREAD_COORDINATOR"')) {
  failures.push(
    "Production Wrangler configuration is missing the Thread coordinator binding.",
  );
}
if (!infraWrangler.includes('"class_name": "ThreadExecutionCoordinator"')) {
  failures.push(
    "Production Wrangler configuration is missing the Thread coordinator class.",
  );
}
if (
  !infraWrangler.includes('"tag": "v9-thread-coordinator-rename"') &&
  !infraWrangler.includes('"tag": "v8-thread-coordinator"')
) {
  failures.push(
    "Production Wrangler configuration is missing its Thread coordinator migration.",
  );
}
for (const binding of [
  "SYNTILA_WORKSPACE_GATEWAY",
  "SYNTILA_REALTIME_GATEWAY",
  "SYNTILA_THREAD_COORDINATOR",
  "SYNTILA_RUN_WORKFLOW",
]) {
  if (!wranglerTypes.includes(binding)) {
    failures.push(`Generated Wrangler types are missing ${binding}.`);
  }
}
if (
  /SYNTILA_PLUGIN_PUBLISHER_EMAIL|SYNTILA_FORGE_EXECUTION|SYNTILA_FORGE_CALLBACK_TOKEN/.test(
    `${infraWrangler}\n${cloudWrangler}`,
  )
) {
  failures.push(
    "Wrangler configuration retains a retired plugin or Forge binding.",
  );
}
if (
  /forge-execution\.wrangler\.jsonc|forge-execution|SYNTILA_FORGE_/.test(
    deployCloud,
  )
) {
  failures.push(
    "Production deployment retains retired Forge deployment configuration.",
  );
}
if (
  /packages\/(?:orchestration|persistence|worker-manifest)/.test(
    workspacePackages,
  )
) {
  failures.push(
    "pnpm workspace still includes a package retained only for retired architecture.",
  );
}
if (
  /packages\/(?:orchestration|persistence|worker-manifest)\//.test(lockfile) ||
  /@syntila\/(?:orchestration|persistence|worker-manifest)/.test(
    `${JSON.stringify(packageJson)}\n${JSON.stringify(cloudPackage)}\n${lockfile}`,
  )
) {
  failures.push(
    "Package manifests or lockfile retain dependencies for retired architecture.",
  );
}
for (const file of [
  "apps/cloud/forge-execution.wrangler.jsonc",
  "packages/orchestration/package.json",
  "packages/persistence/package.json",
  "packages/worker-manifest/package.json",
]) {
  if (existsSync(file))
    failures.push(`Retired package or deployment file remains: ${file}.`);
}

// Phase 32 — Explicit Architecture Guards

// 1. Workspace and AX cannot import Profile Lab, admin APIs, or draft concepts
const desktopAppLibRoots = ["apps/workspace/lib", "apps/app/lib"].filter(
  existsSync,
);
const profileLabOrDraftPattern =
  /syntila_profile_lab|profile_lab|DraftProfileStore|LocalDraftProfileCandidate|DraftToolProfile|updateDraftToolProfilePayload|publishDraftToolProfileRelease|\/api\/admin\/workers\//;

for (const root of desktopAppLibRoots) {
  for (const path of sourceFiles(root)) {
    const source = readFileSync(path, "utf8");
    for (const artifact of renameArtifacts(source)) {
      failures.push(
        `${path}:${artifact.line}: redundant operand: ${artifact.expression}`,
      );
    }
    const permittedDevelopmentAdapter =
      path === "apps/workspace/lib/development_tool_profiles.dart";
    const restrictedSource = permittedDevelopmentAdapter
      ? source.replaceAll("LocalDraftProfileCandidate", "DevelopmentCandidate")
      : source;
    if (profileLabOrDraftPattern.test(restrictedSource)) {
      failures.push(
        `${path} improperly imports or references Profile Lab, admin APIs, or draft concepts.`,
      );
    }
  }
}

const workspacePubspecRaw = readRequired("apps/workspace/pubspec.yaml");
const appPubspecRaw = readRequired("apps/app/pubspec.yaml");
for (const [name, pubspec] of [
  ["Workspace", workspacePubspecRaw],
  ["AX App", appPubspecRaw],
]) {
  const dependenciesSection = pubspec.split("dev_dependencies:")[0] ?? "";
  if (dependenciesSection.includes("syntila_profile_lab")) {
    failures.push(
      `${name} pubspec.yaml includes Profile Lab as a direct runtime dependency.`,
    );
  }
}

// 2. Prohibit Profile Lab draft classes under apps/workspace
const workspaceLibFiles = Array.from(sourceFiles("apps/workspace/lib"));
for (const path of workspaceLibFiles) {
  const source = readFileSync(path, "utf8");
  if (
    /\bclass\s+(?:DraftProfileStore|LocalDraftProfileCandidate|DraftToolProfile|ProfileLabController)\b/.test(
      source,
    )
  ) {
    failures.push(
      `${path} declares a Profile Lab draft class under apps/workspace.`,
    );
  }
}

// 3. Prohibit signing private-key material anywhere under desktop apps
const allDesktopLibRoots = [
  "apps/workspace/lib",
  "apps/app/lib",
  "apps/profile_lab/lib",
].filter(existsSync);
const privateKeySigningPattern =
  /SYNTILA_WORKSPACE_ED25519_SEED|Ed25519PrivateKey|createPrivateKey\s*\(/;

for (const root of allDesktopLibRoots) {
  for (const path of sourceFiles(root)) {
    const source = readFileSync(path, "utf8");
    for (const artifact of renameArtifacts(source)) {
      failures.push(
        `${path}:${artifact.line}: redundant operand: ${artifact.expression}`,
      );
    }
    if (privateKeySigningPattern.test(source)) {
      failures.push(
        `${path} contains signing private-key material under a desktop application library.`,
      );
    }
  }
}

// 4. Prevent direct D1 access from Profile Lab
const profileLabLibFiles = Array.from(sourceFiles("apps/profile_lab/lib"));
const directD1Pattern =
  /\bD1Database\b|\bSYNTILA_DB\b|\bSELECT\s+[a-zA-Z0-9_*\s,.()`"]+\s+FROM\s+[a-zA-Z0-9_`"]+|\bINSERT\s+INTO\s+[a-zA-Z0-9_`"]+|\bUPDATE\s+[a-zA-Z0-9_`"]+\s+SET\b|\bDELETE\s+FROM\s+[a-zA-Z0-9_`"]+/;

for (const path of profileLabLibFiles) {
  const source = readFileSync(path, "utf8");
  if (directD1Pattern.test(source)) {
    failures.push(
      `${path} contains direct Cloud D1 database access or raw SQL inside Profile Lab.`,
    );
  }
}

// 5. Keep unpublished/local Draft objects separate from published Profile admissions
const profileReleaseSource = readRequired(
  "packages/tool_profile_v1/lib/src/tool_profile_release.dart",
);
if (
  /class\s+LocalDraftProfileCandidate\s+implements\s+ToolProfileReleaseAdmission\b/.test(
    profileReleaseSource,
  ) ||
  !/class\s+LocalDraftProfileCandidate\s+implements\s+ToolProfileCandidate\b/.test(
    profileReleaseSource,
  )
) {
  failures.push(
    "LocalDraftProfileCandidate must not implement ToolProfileReleaseAdmission.",
  );
}
if (
  !/class\s+ToolProfileReleaseAdmission\b[\s\S]*?bool\s+get\s+isPublished\s*=>\s*true;/.test(
    profileReleaseSource,
  ) ||
  !/class\s+LocalDraftProfileCandidate\b[\s\S]*?bool\s+get\s+isPublished\s*=>\s*false;/.test(
    profileReleaseSource,
  )
) {
  failures.push(
    "Published Profile admission types must require isPublished => true, and draft candidates must specify isPublished => false.",
  );
}

const developmentProfiles = readRequired(
  "apps/workspace/lib/development_tool_profiles.dart",
);
for (const required of [
  "releaseBuild ||",
  "'localhost', '127.0.0.1', '::1'",
  "profile.logicalWorkerTypeId != workerTypeId",
  "candidate.isPublished",
  "snapshotsRoot",
]) {
  if (!developmentProfiles.replace(/\s+/g, " ").includes(required)) {
    failures.push(
      `Unsigned development Profile boundary is missing ${required}`,
    );
  }
}

// Continuity responsibilities stay below Workflow planning and product UI.
const workflowRunner = readRequired("apps/cloud/src/workflow.ts");
if (
  /work-session-key|sessionPolicy\s*:|sessionKey\s*:|Process\.start|child_process/.test(
    workflowRunner,
  )
) {
  failures.push(
    "Workflow runner must delegate session/execution configuration to the Execution Engine.",
  );
}
for (const entry of [
  "prepareWorkerStepExecution",
  "completeWorkerStepExecution",
]) {
  if (!workflowRunner.includes(`${entry}(`))
    failures.push(`Workflow runner must use ${entry}.`);
}
const cliEngine = readRequired(
  "engines/cli_worker/lib/src/cli_worker_engine.dart",
);
if (
  cliEngine.includes(".deltaAfter(") ||
  !cliEngine.includes("router.prepare(")
) {
  failures.push(
    "CLI Worker Engine must delegate canonical prompt preparation to the Conversation Router.",
  );
}
for (const file of [
  "apps/app/lib/src/features/spaces/spaces_pages/thread_page.dart",
  "apps/app/lib/src/features/spaces/spaces_pages/thread_actions.dart",
  "apps/app/lib/src/features/spaces/spaces_pages/work_components.dart",
]) {
  const source = readRequired(file);
  if (
    /\[['"](?:worker_id|reasoning_effort)['"]\]|EngineSessionStore|nativeSessionId|Process\.start|syntila_cli_worker/.test(
      source,
    )
  ) {
    failures.push(
      `${file} must use canonical product choices, without legacy binding aliases or native execution state.`,
    );
  }
}

if (failures.length > 0) {
  console.error("Architecture v8 guard failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Architecture v8 guard passed.");
