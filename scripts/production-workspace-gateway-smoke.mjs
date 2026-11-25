import { execFileSync } from "node:child_process";
import { createHash, createHmac, randomBytes, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { once } from "node:events";
import { connect as connectTls } from "node:tls";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  productionSmokeSchemaIssues,
  requiredProductionSmokeColumns,
  requiredProductionSmokeIndexes,
  requiredProductionSmokeTableDefinitions,
} from "./production-workspace-gateway-smoke-schema.mjs";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const wrangler = join(repositoryRoot, "node_modules/.bin/wrangler");
const config = join(repositoryRoot, "infra/cloudflare/app.wrangler.jsonc");
const hostname = "syntila.app";
const runId = process.env.GITHUB_RUN_ID
  ? `${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT ?? "1"}`
  : (process.env.SYNTILA_SMOKE_RUN_ID ?? randomUUID());
const ownerId = `gateway-smoke-user-${runId}`;
const authSessionId = `gateway-smoke-auth-session-${runId}`;
const workspaceClientName = `Syntila Workspace Production Smoke ${runId}`;
const profileLabClientName = `Syntila Profile Lab Production Smoke ${runId}`;
const authSessionToken = randomBytes(32).toString("base64url");
const installationUuid = createHash("sha256")
  .update(`syntila-production-workspace-smoke:${runId}`)
  .digest("hex")
  .slice(0, 32)
  .split("");
installationUuid[12] = "4";
installationUuid[16] = "8";
const installationId = `install_${installationUuid
  .join("")
  .replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, "$1-$2-$3-$4-$5")}`;
let workspaceId;
let runtimeId;
let runtimeToken;
let workspaceHumanCredential;

function sqlString(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function executeD1(sql) {
  const output = execFileSync(
    wrangler,
    [
      "d1",
      "execute",
      "syntila",
      "--remote",
      "--yes",
      "--config",
      config,
      "--command",
      sql,
      "--json",
    ],
    {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  return JSON.parse(output);
}

function rowsFromD1(result) {
  if (Array.isArray(result)) {
    return result.flatMap((statement) => statement?.results ?? []);
  }
  return result?.results ?? [];
}

function verifyProductionSchema() {
  const tableRows = rowsFromD1(
    executeD1("SELECT name, sql FROM sqlite_master WHERE type = 'table'"),
  );
  const tableNames = tableRows.map((row) => row.name);
  const definitionsByTable = Object.fromEntries(
    tableRows.map((row) => [row.name, row.sql]),
  );
  const indexRows = rowsFromD1(
    executeD1(
      "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL",
    ),
  );
  const indexesByName = Object.fromEntries(
    indexRows.map((row) => [row.name, row]),
  );
  const columnsByTable = Object.fromEntries(
    Object.keys(requiredProductionSmokeColumns).map((table) => [
      table,
      rowsFromD1(executeD1(`PRAGMA table_info(${table})`)).map(
        (column) => column.name,
      ),
    ]),
  );
  const issues = productionSmokeSchemaIssues(
    tableNames,
    columnsByTable,
    definitionsByTable,
    indexesByName,
  );
  if (issues.length > 0) {
    throw new Error(
      `Production D1 schema preflight failed: ${issues.join("; ")}`,
    );
  }
  console.log(
    `PASS production D1 schema preflight: ${Object.keys(requiredProductionSmokeColumns).length} required tables, ${Object.keys(requiredProductionSmokeTableDefinitions).length} critical table definitions, and ${Object.keys(requiredProductionSmokeIndexes).length} required indexes match the Gateway/auth contract`,
  );
}

class SocketReader {
  constructor(socket) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.pending = [];
    socket.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      for (const resolve of this.pending.splice(0)) resolve();
    });
    socket.on("close", () => {
      for (const resolve of this.pending.splice(0)) resolve();
    });
  }

  async readUntil(marker, timeoutMs) {
    const delimiter = Buffer.from(marker);
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const index = this.buffer.indexOf(delimiter);
      if (index >= 0) {
        const value = this.buffer.subarray(0, index + delimiter.length);
        this.buffer = this.buffer.subarray(index + delimiter.length);
        return value;
      }
      await this.waitForData(deadline);
    }
  }

  async readBytes(length, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (this.buffer.length < length) await this.waitForData(deadline);
    const value = this.buffer.subarray(0, length);
    this.buffer = this.buffer.subarray(length);
    return value;
  }

  async waitForData(deadline) {
    if (this.socket.destroyed) throw new Error("Gateway closed the socket");
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("Timed out waiting for Gateway data");
    await new Promise((resolve, reject) => {
      const onData = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        this.pending = this.pending.filter((pending) => pending !== onData);
        reject(new Error("Timed out waiting for Gateway data"));
      }, remaining);
      this.pending.push(onData);
    });
  }
}

function maskedFrame(value, opcode = 0x1) {
  const payload = Buffer.from(value);
  const extendedLength = payload.length >= 126;
  const header = Buffer.alloc(extendedLength ? 4 : 2);
  header[0] = 0x80 | opcode;
  if (extendedLength) {
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header[1] = 0x80 | payload.length;
  }
  const mask = randomBytes(4);
  const masked = Buffer.from(payload);
  for (let index = 0; index < masked.length; index += 1) {
    masked[index] ^= mask[index % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

async function readServerFrame(reader, timeoutMs) {
  const base = await reader.readBytes(2, timeoutMs);
  const opcode = base[0] & 0x0f;
  let length = base[1] & 0x7f;
  if (length === 126) {
    length = (await reader.readBytes(2, timeoutMs)).readUInt16BE(0);
  } else if (length === 127) {
    const extended = await reader.readBytes(8, timeoutMs);
    const wideLength = extended.readBigUInt64BE(0);
    if (wideLength > 1024n * 1024n) {
      throw new Error("Gateway sent an unexpectedly large WebSocket frame");
    }
    length = Number(wideLength);
  }
  const payload = await reader.readBytes(length, timeoutMs);
  return { opcode, payload };
}

async function waitForProtocolMessage(socket, reader, expectedType) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const remaining = deadline - Date.now();
    const frame = await readServerFrame(reader, remaining);
    if (frame.opcode === 0x8)
      throw new Error(`Gateway closed before ${expectedType}`);
    if (frame.opcode === 0x9) {
      socket.write(maskedFrame(frame.payload, 0xa));
      continue;
    }
    if (frame.opcode !== 0x1) continue;
    const message = JSON.parse(frame.payload.toString("utf8"));
    if (message.type === expectedType) return message;
    if (message.type === "error") {
      throw new Error(`Gateway rejected the ${expectedType} exchange`);
    }
  }
  throw new Error(`Timed out waiting for ${expectedType}`);
}

async function connectAndHello() {
  const socket = connectTls({
    host: hostname,
    port: 443,
    servername: hostname,
    ALPNProtocols: ["http/1.1"],
  });
  const reader = new SocketReader(socket);
  try {
    await once(socket, "secureConnect");
    const webSocketKey = randomBytes(16).toString("base64");
    socket.write(
      [
        `GET /api/workspace-gateway/connect?workspaceRuntimeId=${encodeURIComponent(runtimeId)} HTTP/1.1`,
        `Host: ${hostname}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${webSocketKey}`,
        "Sec-WebSocket-Version: 13",
        `Authorization: Bearer ${runtimeToken}`,
        `Origin: https://${hostname}`,
        "",
        "",
      ].join("\r\n"),
    );
    const responseHeaders = (
      await reader.readUntil("\r\n\r\n", 15_000)
    ).toString("latin1");
    const statusLine = responseHeaders.split("\r\n", 1)[0];
    if (!/^HTTP\/1\.1 101(?: |$)/.test(statusLine)) {
      throw new Error(`Production Gateway handshake returned ${statusLine}`);
    }
    const expectedAccept = createHash("sha1")
      .update(`${webSocketKey}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");
    const acceptHeader = responseHeaders
      .match(/^Sec-WebSocket-Accept:\s*(.+)$/im)?.[1]
      ?.trim();
    if (acceptHeader !== expectedAccept) {
      throw new Error(
        "Production Gateway returned an invalid WebSocket accept key",
      );
    }

    const hello = {
      protocol: "syntila.worker-agent-protocol",
      protocolVersion: "5.1",
      messageId: `gateway-smoke-hello-${runId}`,
      timestamp: new Date().toISOString(),
      type: "workspace.hello",
      executionWorkspaceId: workspaceId,
      workspaceRuntimeId: runtimeId,
      payload: {
        platform: "linux",
        architecture: "x64",
        hostname: "github-actions-production-smoke",
        appVersion: "0.0.0-smoke",
        runtimeCapabilities: ["gateway-smoke"],
      },
    };
    socket.write(maskedFrame(JSON.stringify(hello)));
    const acknowledgement = await waitForProtocolMessage(
      socket,
      reader,
      "workspace.hello.ack",
    );
    if (
      acknowledgement.executionWorkspaceId !== workspaceId ||
      acknowledgement.workspaceRuntimeId !== runtimeId ||
      acknowledgement.correlationId !== hello.messageId
    ) {
      throw new Error(
        "Production Gateway hello acknowledgement identity mismatch",
      );
    }
    const syncRequestId = `gateway-smoke-sync-${runId}`;
    socket.write(
      maskedFrame(
        JSON.stringify({
          protocol: "syntila.worker-agent-protocol",
          protocolVersion: "5.1",
          messageId: syncRequestId,
          timestamp: new Date().toISOString(),
          type: "workspace.sync.request",
          executionWorkspaceId: workspaceId,
          workspaceRuntimeId: runtimeId,
          payload: {},
        }),
      ),
    );
    const syncResult = await waitForProtocolMessage(
      socket,
      reader,
      "workspace.sync.result",
    );
    if (
      syncResult.executionWorkspaceId !== workspaceId ||
      syncResult.workspaceRuntimeId !== runtimeId ||
      syncResult.correlationId !== syncRequestId
    ) {
      throw new Error("Production Gateway sync response identity mismatch");
    }
    return socket;
  } catch (error) {
    socket.destroy();
    throw error;
  }
}

async function waitForSessionRecord() {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const result = executeD1(
      `SELECT id FROM workspace_sessions WHERE workspace_id = ${sqlString(workspaceId)} AND runtime_identity_id = ${sqlString(runtimeId)} AND disconnected_at IS NULL LIMIT 1`,
    );
    if (rowsFromD1(result).length > 0) return;
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  throw new Error(
    "Gateway connected but did not persist its production session row",
  );
}

async function createDisposableWebSession() {
  const now = new Date().toISOString();
  const email = `gateway-smoke-${runId}@example.invalid`;
  executeD1(
    `INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES (${sqlString(ownerId)}, ${sqlString(email)}, 'Production Desktop Auth Smoke', 'active', ${sqlString(now)}, ${sqlString(now)});
     INSERT INTO auth_sessions (id, user_id, token, expires_at, created_at, updated_at, user_agent) VALUES (${sqlString(authSessionId)}, ${sqlString(ownerId)}, ${sqlString(authSessionToken)}, '9999-12-31T23:59:59.999Z', ${sqlString(now)}, ${sqlString(now)}, 'Syntila production desktop auth smoke');`,
  );
}

function disposableApprovalCookie() {
  const secret = process.env.BETTER_AUTH_SECRET;
  if (!secret) {
    throw new Error(
      "BETTER_AUTH_SECRET is required to approve the disposable Profile Lab auth intent",
    );
  }
  const signature = createHmac("sha256", secret)
    .update(authSessionToken)
    .digest("base64");
  const signedValue = encodeURIComponent(`${authSessionToken}.${signature}`);
  return `__Secure-better-auth.session_token=${signedValue}; better-auth.session_token=${signedValue}`;
}

function removeDisposableRuntime() {
  executeD1(
    `DELETE FROM workspace_sessions
      WHERE workspace_id IN (
        SELECT workspace_id FROM workspace_installations
        WHERE installation_id = ${sqlString(installationId)}
      ) OR workspace_id IN (
        SELECT id FROM execution_workspaces WHERE owner_user_id = ${sqlString(ownerId)}
      );
     DELETE FROM workspace_runtime_facts
      WHERE workspace_id IN (
        SELECT workspace_id FROM workspace_installations
        WHERE installation_id = ${sqlString(installationId)}
      ) OR workspace_id IN (
        SELECT id FROM execution_workspaces WHERE owner_user_id = ${sqlString(ownerId)}
      );
     DELETE FROM workspace_runtime_identities
      WHERE workspace_id IN (
           SELECT workspace_id FROM workspace_installations
           WHERE installation_id = ${sqlString(installationId)}
         ) OR workspace_id IN (
           SELECT id FROM execution_workspaces WHERE owner_user_id = ${sqlString(ownerId)}
         );
     DELETE FROM workspace_installations
      WHERE installation_id = ${sqlString(installationId)}
         OR workspace_id IN (
           SELECT id FROM execution_workspaces WHERE owner_user_id = ${sqlString(ownerId)}
         );
     DELETE FROM execution_workspaces WHERE owner_user_id = ${sqlString(ownerId)};
     DELETE FROM desktop_auth_intents WHERE client_name IN (${sqlString(workspaceClientName)}, ${sqlString(profileLabClientName)}) OR approved_user_id = ${sqlString(ownerId)};
     DELETE FROM auth_sessions WHERE id = ${sqlString(authSessionId)};
     DELETE FROM desktop_human_sessions WHERE user_id = ${sqlString(ownerId)};
     DELETE FROM users WHERE id = ${sqlString(ownerId)};`,
  );
}

async function verifyWorkspaceAuth() {
  const intentResponse = await fetch(
    `https://${hostname}/api/desktop-auth/intents`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        clientName: workspaceClientName,
        contractVersion: "1.1",
        audience: "syntila.desktop.management",
      }),
    },
  );
  const intent = await intentResponse.json().catch(() => null);
  if (
    intentResponse.status !== 201 ||
    !intent ||
    typeof intent.intentId !== "string" ||
    typeof intent.pollToken !== "string" ||
    intent.audience !== "syntila.desktop.management"
  ) {
    throw new Error(
      `Production Workspace auth intent failed with HTTP ${intentResponse.status}${typeof intent?.error === "string" ? `: ${intent.error}` : ""}`,
    );
  }

  const storedIntent = rowsFromD1(
    executeD1(
      `SELECT audience, approved_user_id, claimed_at FROM desktop_auth_intents WHERE id = ${sqlString(intent.intentId)}`,
    ),
  )[0];
  if (
    storedIntent?.audience !== "syntila.desktop.management" ||
    storedIntent?.approved_user_id !== null ||
    storedIntent?.claimed_at !== null
  ) {
    throw new Error(
      "Production Workspace auth intent was not stored as a pending Workspace audience intent",
    );
  }

  const approveResponse = await fetch(
    `https://${hostname}/api/desktop-auth/intents/${encodeURIComponent(intent.intentId)}/approve`,
    {
      method: "POST",
      headers: {
        Cookie: disposableApprovalCookie(),
        Origin: `https://${hostname}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    },
  );
  const approval = await approveResponse.json().catch(() => null);
  if (
    approveResponse.status !== 200 ||
    approval?.approved !== true ||
    approval?.user?.userId !== ownerId
  ) {
    throw new Error(
      `Production Workspace auth approval failed with HTTP ${approveResponse.status}${typeof approval?.error === "string" ? `: ${approval.error}` : ""}`,
    );
  }

  const claimResponse = await fetch(
    `https://${hostname}/api/desktop-auth/intents/${encodeURIComponent(intent.intentId)}/claim`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pollToken: intent.pollToken }),
    },
  );
  const claimed = await claimResponse.json().catch(() => null);
  if (
    claimResponse.status !== 200 ||
    claimed?.audience !== "syntila.desktop.management" ||
    claimed?.user?.userId !== ownerId ||
    typeof claimed?.sessionId !== "string" ||
    typeof claimed?.credential !== "string" ||
    !claimed.credential.startsWith("syntila_dhs_")
  ) {
    throw new Error(
      `Production Workspace auth claim failed with HTTP ${claimResponse.status}${typeof claimed?.error === "string" ? `: ${claimed.error}` : ""}`,
    );
  }

  const [claimedIntent, storedSession] = [
    rowsFromD1(
      executeD1(
        `SELECT audience, approved_user_id, claimed_at, claimed_session_id FROM desktop_auth_intents WHERE id = ${sqlString(intent.intentId)}`,
      ),
    )[0],
    rowsFromD1(
      executeD1(
        `SELECT user_id, audience, token_hash, revoked_at FROM desktop_human_sessions WHERE id = ${sqlString(claimed.sessionId)}`,
      ),
    )[0],
  ];
  const claimedTokenHash = createHash("sha256")
    .update(claimed.credential)
    .digest("hex");
  if (
    claimedIntent?.audience !== "syntila.desktop.management" ||
    claimedIntent?.approved_user_id !== ownerId ||
    typeof claimedIntent?.claimed_at !== "string" ||
    claimedIntent?.claimed_session_id !== claimed.sessionId ||
    storedSession?.user_id !== ownerId ||
    storedSession?.audience !== "syntila.desktop.management" ||
    storedSession?.token_hash !== claimedTokenHash ||
    storedSession?.revoked_at !== null
  ) {
    throw new Error(
      "Production Workspace auth claim did not persist a matching audience-scoped session",
    );
  }

  const sessionResponse = await fetch(
    `https://${hostname}/api/desktop-auth/session`,
    { headers: { Authorization: `Bearer ${claimed.credential}` } },
  );
  const session = await sessionResponse.json().catch(() => null);
  if (
    sessionResponse.status !== 200 ||
    session?.audience !== "syntila.desktop.management" ||
    session?.user?.userId !== ownerId ||
    session?.sessionId !== claimed.sessionId
  ) {
    throw new Error(
      `Production Workspace session validation failed with HTTP ${sessionResponse.status}${typeof session?.error === "string" ? `: ${session.error}` : ""}`,
    );
  }

  console.log(
    "PASS production Workspace auth: create, approve and claim; stored audience/session; session validation",
  );
  return claimed.credential;
}

async function verifyProfileLabAuth(workspaceCredential) {
  const intentResponse = await fetch(
    `https://${hostname}/api/desktop-auth/intents`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        clientName: profileLabClientName,
        contractVersion: "1.1",
        audience: "syntila.profile-lab.management",
      }),
    },
  );
  const intent = await intentResponse.json().catch(() => null);
  if (
    intentResponse.status !== 201 ||
    !intent ||
    typeof intent.intentId !== "string" ||
    typeof intent.pollToken !== "string" ||
    intent.audience !== "syntila.profile-lab.management"
  ) {
    throw new Error(
      `Production Profile Lab auth intent failed with HTTP ${intentResponse.status}${typeof intent?.error === "string" ? `: ${intent.error}` : ""}`,
    );
  }

  const storedIntent = rowsFromD1(
    executeD1(
      `SELECT audience, approved_user_id, claimed_at FROM desktop_auth_intents WHERE id = ${sqlString(intent.intentId)}`,
    ),
  )[0];
  if (
    storedIntent?.audience !== "syntila.profile-lab.management" ||
    storedIntent?.approved_user_id !== null ||
    storedIntent?.claimed_at !== null
  ) {
    throw new Error(
      "Production Profile Lab auth intent was not stored as a pending Profile Lab audience intent",
    );
  }

  const approveResponse = await fetch(
    `https://${hostname}/api/desktop-auth/intents/${encodeURIComponent(intent.intentId)}/approve`,
    {
      method: "POST",
      headers: {
        Cookie: disposableApprovalCookie(),
        Origin: `https://${hostname}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    },
  );
  const approval = await approveResponse.json().catch(() => null);
  if (
    /"SYNTILA_PROFILE_LAB_OWNER_EMAIL"\s*:\s*"[^"\s]+"/.test(
      readFileSync(config, "utf8"),
    )
  ) {
    if (
      approveResponse.status !== 403 ||
      approval?.error !==
        "Profile Lab is restricted to its verified owner account"
    ) {
      throw new Error(
        "Production Profile Lab must reject the disposable non-owner identity",
      );
    }
    const deniedIntent = rowsFromD1(
      executeD1(
        `SELECT approved_user_id, claimed_at FROM desktop_auth_intents WHERE id = ${sqlString(intent.intentId)}`,
      ),
    )[0];
    if (
      deniedIntent?.approved_user_id !== null ||
      deniedIntent?.claimed_at !== null
    ) {
      throw new Error(
        "Rejected Profile Lab intent must remain unapproved and unclaimed",
      );
    }
    const deniedClaim = await fetch(
      `https://${hostname}/api/desktop-auth/intents/${encodeURIComponent(intent.intentId)}/claim`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pollToken: intent.pollToken }),
      },
    );
    if (deniedClaim.status !== 409)
      throw new Error("Rejected Profile Lab intent must remain unclaimable");
    const deniedAdmin = await fetch(`https://${hostname}/api/admin/workers`, {
      headers: { Authorization: `Bearer ${workspaceCredential}` },
    });
    if (deniedAdmin.status !== 403)
      throw new Error("Workspace credentials must not administer Profile Lab");
    console.log(
      "PASS: Profile Lab rejects non-owner browser approval and Workspace credentials",
    );
    return;
  }

  if (
    approveResponse.status !== 200 ||
    approval?.approved !== true ||
    approval?.user?.userId !== ownerId
  ) {
    throw new Error(
      `Production Profile Lab auth intent approval failed with HTTP ${approveResponse.status}${typeof approval?.error === "string" ? `: ${approval.error}` : ""}`,
    );
  }

  const approvedIntent = rowsFromD1(
    executeD1(
      `SELECT audience, approved_user_id, approved_at, claimed_at FROM desktop_auth_intents WHERE id = ${sqlString(intent.intentId)}`,
    ),
  )[0];
  if (
    approvedIntent?.audience !== "syntila.profile-lab.management" ||
    approvedIntent?.approved_user_id !== ownerId ||
    typeof approvedIntent?.approved_at !== "string" ||
    approvedIntent?.claimed_at !== null
  ) {
    throw new Error(
      "Production Profile Lab auth intent approval did not persist the disposable test identity",
    );
  }

  const claimResponse = await fetch(
    `https://${hostname}/api/desktop-auth/intents/${encodeURIComponent(intent.intentId)}/claim`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pollToken: intent.pollToken }),
    },
  );
  const claimed = await claimResponse.json().catch(() => null);
  if (
    claimResponse.status !== 200 ||
    claimed?.audience !== "syntila.profile-lab.management" ||
    claimed?.user?.userId !== ownerId ||
    typeof claimed?.sessionId !== "string" ||
    typeof claimed?.credential !== "string" ||
    !claimed.credential.startsWith("syntila_dhs_")
  ) {
    throw new Error(
      `Production Profile Lab auth claim failed with HTTP ${claimResponse.status}${typeof claimed?.error === "string" ? `: ${claimed.error}` : ""}`,
    );
  }

  const [claimedIntent, storedSession] = [
    rowsFromD1(
      executeD1(
        `SELECT audience, approved_user_id, claimed_at, claimed_session_id FROM desktop_auth_intents WHERE id = ${sqlString(intent.intentId)}`,
      ),
    )[0],
    rowsFromD1(
      executeD1(
        `SELECT user_id, audience, token_hash, revoked_at, expires_at FROM desktop_human_sessions WHERE id = ${sqlString(claimed.sessionId)}`,
      ),
    )[0],
  ];
  const claimedTokenHash = createHash("sha256")
    .update(claimed.credential)
    .digest("hex");
  if (
    claimedIntent?.audience !== "syntila.profile-lab.management" ||
    claimedIntent?.approved_user_id !== ownerId ||
    typeof claimedIntent?.claimed_at !== "string" ||
    claimedIntent?.claimed_session_id !== claimed.sessionId ||
    storedSession?.user_id !== ownerId ||
    storedSession?.audience !== "syntila.profile-lab.management" ||
    storedSession?.token_hash !== claimedTokenHash ||
    storedSession?.revoked_at !== null
  ) {
    throw new Error(
      "Production Profile Lab auth claim did not persist a matching audience-scoped session",
    );
  }

  const sessionResponse = await fetch(
    `https://${hostname}/api/desktop-auth/session`,
    { headers: { Authorization: `Bearer ${claimed.credential}` } },
  );
  const session = await sessionResponse.json().catch(() => null);
  if (
    sessionResponse.status !== 200 ||
    session?.audience !== "syntila.profile-lab.management" ||
    session?.user?.userId !== ownerId ||
    session?.sessionId !== claimed.sessionId
  ) {
    throw new Error(
      `Production Profile Lab session validation failed with HTTP ${sessionResponse.status}${typeof session?.error === "string" ? `: ${session.error}` : ""}`,
    );
  }

  const profileAdminResponse = await fetch(
    `https://${hostname}/api/admin/workers`,
    { headers: { Authorization: `Bearer ${claimed.credential}` } },
  );
  const profileAdminResult = await profileAdminResponse
    .json()
    .catch(() => null);
  if (
    profileAdminResponse.status !== 403 ||
    profileAdminResult?.error !== "The profiles:admin permission is required"
  ) {
    throw new Error(
      `Production Profile Lab session did not reach the Profile-admin permission boundary as the disposable non-admin identity (HTTP ${profileAdminResponse.status})`,
    );
  }

  const workspaceRegistrationResponse = await fetch(
    `https://${hostname}/api/workspace-runtime/register`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${claimed.credential}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        contractVersion: "1.0",
        installationId,
        proposedWorkspaceName: "Profile Lab Audience Isolation Probe",
        hostname: "production-auth-smoke",
        platform: "linux",
        architecture: "x64",
        appVersion: "0.0.0-smoke",
        runtimeCapabilities: {
          os: "linux",
          arch: "x64",
          appVersion: "0.0.0-smoke",
          supportedRuntimes: ["auth-smoke"],
          maxConcurrentWorkers: 1,
        },
      }),
    },
  );
  const workspaceRegistration = await workspaceRegistrationResponse
    .json()
    .catch(() => null);
  if (
    workspaceRegistrationResponse.status !== 403 ||
    typeof workspaceRegistration?.error !== "string" ||
    !workspaceRegistration.error.includes("syntila.profile-lab.management")
  ) {
    throw new Error(
      `Production Profile Lab session was not rejected by Workspace registration audience isolation (HTTP ${workspaceRegistrationResponse.status})`,
    );
  }

  const workspaceProfileAdminResponse = await fetch(
    `https://${hostname}/api/admin/workers`,
    { headers: { Authorization: `Bearer ${workspaceCredential}` } },
  );
  const workspaceProfileAdminResult = await workspaceProfileAdminResponse
    .json()
    .catch(() => null);
  if (
    workspaceProfileAdminResponse.status !== 403 ||
    workspaceProfileAdminResult?.error !==
      "The profiles:admin permission is required"
  ) {
    throw new Error(
      `Production Workspace session crossed the Profile Lab administration boundary (HTTP ${workspaceProfileAdminResponse.status})`,
    );
  }

  const runtimeResponse = await fetch(
    `https://${hostname}/api/workspace-runtime/sessions`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${claimed.credential}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ workspaceRuntimeId: "profile-lab-smoke-runtime" }),
    },
  );
  const runtimeResult = await runtimeResponse.json().catch(() => null);
  if (
    runtimeResponse.status !== 401 ||
    runtimeResult?.error !== "Runtime session not found or credential revoked"
  ) {
    throw new Error(
      `Production Profile Lab session was not rejected by Workspace runtime transport (HTTP ${runtimeResponse.status})`,
    );
  }
  console.log(
    "PASS production Profile Lab auth: create, approve and claim; stored audience/session; Profile-admin authorization; mutual exclusion from Workspace registration and Profile Lab administration",
  );
}

async function registerDisposableWorkspace() {
  const appVersion = "0.0.0-smoke";
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const response = await fetch(
      `https://${hostname}/api/workspace-runtime/register`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${workspaceHumanCredential}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          proposedWorkspaceName: "Production Workspace Registration Smoke",
          hostname: "github-actions-production-smoke",
          platform: "linux",
          architecture: "x64",
          appVersion,
          runtimeCapabilities: {
            os: "linux",
            arch: "x64",
            appVersion,
            supportedRuntimes: ["gateway-smoke"],
            maxConcurrentWorkers: 1,
          },
        }),
      },
    );
    const result = await response.json().catch(() => null);
    if (
      response.status === 201 &&
      result &&
      typeof result.workspaceId === "string" &&
      typeof result.workspaceRuntimeId === "string" &&
      typeof result.runtimeCredential === "string" &&
      result.ownerUserId === ownerId
    ) {
      workspaceId = result.workspaceId;
      runtimeId = result.workspaceRuntimeId;
      runtimeToken = result.runtimeCredential;
      return;
    }
    const details = result ? JSON.stringify(result) : "non-JSON response";
    lastError = new Error(
      `Production Workspace registration failed with HTTP ${response.status}: ${details}`,
    );
    if (result?.code === "registration_conflict" && attempt < 3) {
      console.warn(
        `Registration conflict on attempt ${attempt}, retrying in 1s...`,
      );
      await new Promise((resolve) => setTimeout(resolve, 1000));
      continue;
    }
    throw lastError;
  }
  throw lastError;
}

async function main() {
  if (process.argv.includes("--cleanup-only")) {
    if (!process.env.GITHUB_RUN_ID && !process.env.SYNTILA_SMOKE_RUN_ID) {
      throw new Error(
        "Set SYNTILA_SMOKE_RUN_ID to the original smoke run ID for cleanup-only mode",
      );
    }
    removeDisposableRuntime();
    return;
  }

  if (process.argv.includes("--schema-only")) {
    verifyProductionSchema();
    return;
  }

  verifyProductionSchema();

  let socket;
  let setupAttempted = false;
  try {
    removeDisposableRuntime();
    setupAttempted = true;
    await createDisposableWebSession();
    const webSessionResponse = await fetch(`https://${hostname}/api/session`, {
      headers: { Cookie: disposableApprovalCookie() },
    });
    const webSession = await webSessionResponse.json().catch(() => null);
    if (
      webSessionResponse.status !== 200 ||
      webSession?.authenticated !== true ||
      webSession?.user?.id !== ownerId
    ) {
      throw new Error(
        `Production web session validation failed with HTTP ${webSessionResponse.status}`,
      );
    }
    console.log(
      "PASS production web authentication: cookie session resolved through /api/session",
    );
    workspaceHumanCredential = await verifyWorkspaceAuth();
    await verifyProfileLabAuth(workspaceHumanCredential);
    await registerDisposableWorkspace();
    socket = await connectAndHello();
    await waitForSessionRecord();
    console.log(
      "PASS production Workspace smoke: authenticated /register, HTTP 101, hello.ack, sync result, session persisted",
    );
  } finally {
    socket?.end(maskedFrame(Buffer.from([0x03, 0xe8]), 0x8));
    if (setupAttempted) removeDisposableRuntime();
  }
}

main().catch((error) => {
  console.error(`FAIL production Workspace Gateway smoke: ${error.message}`);
  process.exitCode = 1;
});
