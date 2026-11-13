import { describe, expect, it } from "./helpers/vitest-compat";
import {
  handleCreateIssueReport,
  handleCreateAdminIssueReportGroup,
  handleGetAdminIssueReport,
  handleGetAdminIssueReportGroup,
  handleGetIssueReport,
  handleGetIssueReportForRequest,
  handleListAdminIssueReportGroups,
  handleListAdminIssueReports,
  handlePatchAdminIssueReport,
} from "../../src/domain/routes/issue-reports.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";
import { pruneExpiredIssueReports } from "../../src/domain/issue-report-retention.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

function seedExecution(sqlite: ReturnType<typeof sqliteD1>["sqlite"]) {
  sqlite.exec(`
    INSERT INTO users(id,email,display_name,status,created_at,updated_at)
      VALUES ('owner','owner@example.test','Owner','active','now','now'),
             ('outsider','outsider@example.test','Outsider','active','now','now'),
             ('support','support@example.test','Support','active','now','now');
    INSERT INTO spaces(id,name,owner_user_id,created_at,updated_at)
      VALUES ('space-1','Space','owner','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at)
      VALUES ('membership-owner','space-1','owner','owner','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at)
      VALUES ('thread-1','space-1','Thread','active','owner','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at)
      VALUES ('workspace-1','owner','Workspace','online','now','now');
    INSERT INTO workspace_runtime_identities(
      id,workspace_id,credential_token_hash,installation_id,created_at
    ) VALUES ('runtime-1','workspace-1','hash','install-1','now');
    INSERT INTO work_requests(
      id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,
      workflow_snapshot_json,status,primary_workspace_id,input_json,created_at,
      updated_at,snapshot_json
    ) VALUES (
      'request-1','thread-1','owner','stateless','direct',2,'{}','failed',
      'workspace-1','{}','now','now','{}'
    );
    INSERT INTO runs(id,space_id,thread_id,work_request_id,status,created_at,updated_at)
      VALUES ('run-1','space-1','thread-1','request-1','failed','now','now');
    INSERT INTO worker_assignments(
      id,space_id,run_id,thread_id,work_request_id,execution_workspace_id,
      runtime_identity_id,worker_type_id,status,created_at,updated_at,
      workspace_worker_id,task_id,attempt_id,engine_version,model,error_json,
      permission_snapshot_json,session_policy
    ) VALUES (
      'assignment-1','space-1','run-1','thread-1','request-1','workspace-1',
      'runtime-1','gemini','failed','now','now','worker-1','task-1','attempt-1',
      '1.3.0','gemini-pro','{"error":{"code":"provider_authentication_required","retryable":true,"details":{"diagnostic":"provider exited with token=secret at /Users/tester/provider.log"}}}',
      '{"profileDefinitionId":"gemini-antigravity","profileReleaseVersion":2,"reasoningEffort":"high"}',
      'stateless'
    );
    INSERT INTO workspace_worker_inventory(
      worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,
      readiness_state,local_concurrency_limit,revision,
      created_at,updated_at,last_seen_at,provider_tool_version
    ) VALUES (
      'worker-1','workspace-1','owner','gemini','enabled','ready',1,1,
      'now','now','now','1.3.3'
    );
  `);
}

function envFor(
  db: D1Database,
  userId: string,
  options: { support?: boolean; bucket?: R2Bucket } = {},
) {
  return {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    SYNTILA_ISSUE_SUPPORT_USER_IDS: options.support ? userId : "support",
    SYNTILA_ARTIFACTS: options.bucket,
    TEST_AUTHENTICATION: async () => ({
      userId,
      user: {
        id: userId,
        email: `${userId}@example.test`,
        displayName: userId,
        status: "active" as const,
      },
      spaceRoles: {},
      sessionId: `session-${userId}`,
      clientType: "web" as const,
    }),
  } as unknown as SecurityEnv;
}

describe("issue reports", () => {
  it("creates one trusted partial report and deduplicates repeated submission", async () => {
    const fixture = sqliteD1();
    seedExecution(fixture.sqlite);
    const bundles = new Map<string, string>();
    const bucket = {
      async put(key: string, value: string) {
        bundles.set(key, value);
      },
      async delete(key: string) {
        bundles.delete(key);
      },
    } as unknown as R2Bucket;
    const env = envFor(fixture.db, "owner", { bucket });
    const request = () =>
      new Request("https://syntila.test/api/issue-reports", {
        method: "POST",
        body: JSON.stringify({ requestId: "request-1" }),
        headers: { "content-type": "application/json" },
      });

    const first = await handleCreateIssueReport(request(), env);
    expect(first.status).toBe(201);
    const firstBody = (await first.json()) as {
      report: Record<string, unknown>;
    };
    expect(firstBody.report).toMatchObject({
      status: "open",
      diagnosticState: "partial",
    });
    expect(firstBody.report).not.toHaveProperty("failureDetail");
    expect(firstBody.report).not.toHaveProperty("fingerprint");
    expect(bundles.size).toBe(1);
    expect(
      (
        fixture.sqlite
          .prepare("SELECT bundle_key FROM issue_report_diagnostics")
          .get() as { bundle_key: string }
      ).bundle_key,
    ).toMatch(/^issue-reports\//);
    const persisted = await handleGetIssueReportForRequest(
      new Request(
        "https://syntila.test/api/issue-reports?requestId=request-1&assignmentId=assignment-1",
      ),
      env,
    );
    const persistedBody = (await persisted.json()) as {
      report: { id: string };
    };
    expect(persistedBody.report.id).toBe(firstBody.report.id);

    const duplicate = await handleCreateIssueReport(request(), env);
    expect(duplicate.status).toBe(200);
    const duplicateBody = (await duplicate.json()) as {
      report: Record<string, unknown>;
    };
    expect(duplicateBody.report.id).toBe(firstBody.report.id);
    expect(
      (
        fixture.sqlite
          .prepare("SELECT COUNT(*) AS count FROM issue_reports")
          .get() as { count: number }
      ).count,
    ).toBe(1);

    const admin = await handleGetAdminIssueReport(
      new Request("https://syntila.test/api/admin/issue-reports/x"),
      envFor(fixture.db, "support", { support: true }),
      String(firstBody.report.id),
    );
    expect(admin.status).toBe(200);
    const adminBody = (await admin.json()) as {
      diagnostics: { data: Record<string, unknown> };
    };
    const diagnosticText = JSON.stringify(adminBody.diagnostics.data);
    expect(diagnosticText).toContain("provider_authentication_required");
    expect(diagnosticText).toContain("1.3.3");
    expect(diagnosticText).toContain(
      "provider exited with token=[REDACTED] at [PATH]",
    );
    expect(diagnosticText).not.toContain("secret");
    expect(diagnosticText).not.toContain("Prompt");

    fixture.sqlite.exec(`
      INSERT INTO worker_assignments(
        id,space_id,run_id,thread_id,work_request_id,execution_workspace_id,
        runtime_identity_id,worker_type_id,status,created_at,updated_at,
        workspace_worker_id,task_id,attempt_id,engine_version,model,error_json,
        permission_snapshot_json,session_policy
      ) SELECT 'assignment-2',space_id,run_id,thread_id,work_request_id,
        execution_workspace_id,runtime_identity_id,worker_type_id,status,
        '2099-01-01T00:00:00Z','2099-01-01T00:00:00Z',workspace_worker_id,'task-2','attempt-2',engine_version,
        model,error_json,permission_snapshot_json,session_policy
      FROM worker_assignments WHERE id = 'assignment-1';
    `);
    const second = await handleCreateIssueReport(request(), env);
    expect(second.status).toBe(201);
    expect(
      (
        fixture.sqlite
          .prepare("SELECT COUNT(*) AS count FROM issue_reports")
          .get() as { count: number }
      ).count,
    ).toBe(2);
  });

  it("uses structured private Engine diagnostics for stage and Workspace evidence", async () => {
    const fixture = sqliteD1();
    seedExecution(fixture.sqlite);
    fixture.sqlite
      .prepare("UPDATE worker_assignments SET error_json = ? WHERE id = ?")
      .run(
        JSON.stringify({
          error: {
            code: "execution_failed",
            retryable: true,
            details: {
              diagnostic: JSON.stringify({
                schemaVersion: 1,
                component: "cli_worker_engine",
                stage: "session_lookup",
                errorCode: "session_resume_failed",
                providerStarted: false,
                recovered: true,
              }),
            },
          },
        }),
        "assignment-1",
      );
    const created = await handleCreateIssueReport(
      new Request("https://syntila.test/api/issue-reports", {
        method: "POST",
        body: JSON.stringify({ requestId: "request-1" }),
        headers: { "content-type": "application/json" },
      }),
      envFor(fixture.db, "owner"),
    );
    const createdBody = (await created.json()) as { report: { id: string } };
    const admin = await handleGetAdminIssueReport(
      new Request("https://syntila.test/api/admin/issue-reports/x"),
      envFor(fixture.db, "support", { support: true }),
      createdBody.report.id,
    );
    const body = (await admin.json()) as {
      report: Record<string, unknown>;
      diagnostics: { data: Record<string, Record<string, unknown>> };
      investigation: { workspace: Record<string, unknown> };
    };
    expect(body.report).toMatchObject({
      component: "cli_worker_engine",
      failureStage: "session_lookup",
    });
    expect(body.diagnostics.data.execution).toMatchObject({
      failureDetail: expect.stringContaining('"providerStarted":false'),
    });
    expect(body.investigation.workspace).toMatchObject({
      state: "diagnostics_unavailable",
      reason: "assignment_error_only",
    });
  });

  it("rejects browser-supplied authority and unauthorized report access", async () => {
    const fixture = sqliteD1();
    seedExecution(fixture.sqlite);
    const outsiderEnv = envFor(fixture.db, "outsider");
    await expect(
      handleCreateIssueReport(
        new Request("https://syntila.test/api/issue-reports", {
          method: "POST",
          body: JSON.stringify({
            requestId: "request-1",
            workspaceId: "workspace-1",
          }),
          headers: { "content-type": "application/json" },
        }),
        outsiderEnv,
      ),
    ).rejects.toMatchObject({ status: 400 });

    const ownerReport = await handleCreateIssueReport(
      new Request("https://syntila.test/api/issue-reports", {
        method: "POST",
        body: JSON.stringify({ requestId: "request-1" }),
        headers: { "content-type": "application/json" },
      }),
      envFor(fixture.db, "owner"),
    );
    const ownerBody = (await ownerReport.json()) as { report: { id: string } };
    await expect(
      handleGetIssueReport(
        new Request("https://syntila.test/api/issue-reports/x"),
        outsiderEnv,
        ownerBody.report.id,
      ),
    ).rejects.toMatchObject({ status: 403 });
  });

  it("keeps report diagnostics private and records support status changes", async () => {
    const fixture = sqliteD1();
    seedExecution(fixture.sqlite);
    const create = await handleCreateIssueReport(
      new Request("https://syntila.test/api/issue-reports", {
        method: "POST",
        body: JSON.stringify({ requestId: "request-1" }),
        headers: { "content-type": "application/json" },
      }),
      envFor(fixture.db, "owner"),
    );
    const body = (await create.json()) as { report: { id: string } };
    const supportEnv = envFor(fixture.db, "support", { support: true });
    await expect(
      handleListAdminIssueReports(
        new Request("https://syntila.test/api/admin/issue-reports"),
        envFor(fixture.db, "owner"),
      ),
    ).rejects.toMatchObject({ status: 403 });
    const patch = await handlePatchAdminIssueReport(
      new Request("https://syntila.test/api/admin/issue-reports/x", {
        method: "PATCH",
        body: JSON.stringify({
          status: "investigating",
          note: "Grouped for triage",
        }),
        headers: { "content-type": "application/json" },
      }),
      supportEnv,
      body.report.id,
    );
    expect(patch.status).toBe(200);
    const list = await handleListAdminIssueReports(
      new Request("https://syntila.test/api/admin/issue-reports"),
      supportEnv,
    );
    const listed = (await list.json()) as {
      reports: Array<{ status: string }>;
    };
    expect(listed.reports[0]?.status).toBe("investigating");
    expect(
      (
        fixture.sqlite
          .prepare(
            "SELECT COUNT(*) AS count FROM issue_report_events WHERE event_type = 'report.status_changed'",
          )
          .get() as { count: number }
      ).count,
    ).toBe(1);
  });

  it("retains reports until their private diagnostic attachment can be deleted", async () => {
    const fixture = sqliteD1();
    seedExecution(fixture.sqlite);
    const create = await handleCreateIssueReport(
      new Request("https://syntila.test/api/issue-reports", {
        method: "POST",
        body: JSON.stringify({ requestId: "request-1" }),
        headers: { "content-type": "application/json" },
      }),
      envFor(fixture.db, "owner"),
    );
    const body = (await create.json()) as { report: { id: string } };
    fixture.sqlite
      .prepare(
        "UPDATE issue_reports SET created_at = '2000-01-01T00:00:00.000Z'",
      )
      .run();
    expect(
      await pruneExpiredIssueReports(
        fixture.db,
        undefined,
        new Date("2026-01-01"),
      ),
    ).toBe(1);
    expect(
      fixture.sqlite
        .prepare("SELECT id FROM issue_reports WHERE id = ?")
        .get(body.report.id),
    ).toBeUndefined();
  });

  it("supports filtered investigation, timelines, status transitions and explicit groups", async () => {
    const fixture = sqliteD1();
    seedExecution(fixture.sqlite);
    const owner = envFor(fixture.db, "owner");
    const support = envFor(fixture.db, "support", { support: true });
    const created = await handleCreateIssueReport(
      new Request("https://syntila.test/api/issue-reports", {
        method: "POST",
        body: JSON.stringify({ requestId: "request-1" }),
        headers: { "content-type": "application/json" },
      }),
      owner,
    );
    const reportId = ((await created.json()) as { report: { id: string } })
      .report.id;
    const groupResponse = await handleCreateAdminIssueReportGroup(
      new Request("https://syntila.test/api/admin/issue-reports/groups", {
        method: "POST",
        body: JSON.stringify({
          label: "Provider authentication failures",
          fingerprint: "auth-group",
        }),
        headers: { "content-type": "application/json" },
      }),
      support,
    );
    expect(groupResponse.status).toBe(201);
    const groupId = ((await groupResponse.json()) as { group: { id: string } })
      .group.id;
    const investigating = await handlePatchAdminIssueReport(
      new Request("https://syntila.test/api/admin/issue-reports/x", {
        method: "PATCH",
        body: JSON.stringify({
          status: "investigating",
          groupId,
          note: "Correlate provider sign-in failures",
        }),
        headers: { "content-type": "application/json" },
      }),
      support,
      reportId,
    );
    expect(investigating.status).toBe(200);
    const filtered = await handleListAdminIssueReports(
      new Request(
        "https://syntila.test/api/admin/issue-reports?component=provider_cli&workerTypeId=gemini&status=investigating",
      ),
      support,
    );
    const filteredBody = (await filtered.json()) as {
      reports: Array<Record<string, unknown>>;
    };
    expect(filteredBody.reports).toHaveLength(1);
    expect(filteredBody.reports[0]).toMatchObject({
      workerTypeId: "gemini",
      status: "investigating",
      incidentGroup: { id: groupId, count: 1 },
      versions: { engine: "1.3.0", providerTool: "1.3.3" },
    });
    const detail = await handleGetAdminIssueReport(
      new Request("https://syntila.test/api/admin/issue-reports/x"),
      support,
      reportId,
    );
    const detailBody = (await detail.json()) as {
      timeline: Array<Record<string, unknown>>;
      investigation: {
        missingEvidence: string[];
        failure: { firstSignificantError: unknown };
      };
    };
    expect(detailBody.timeline.length).toBeGreaterThan(0);
    expect(detailBody.investigation.missingEvidence).toContain(
      "workspace_diagnostics",
    );
    expect(
      detailBody.investigation.failure.firstSignificantError,
    ).toMatchObject({
      errorCode: "provider_authentication_required",
    });
    const groups = await handleListAdminIssueReportGroups(
      new Request("https://syntila.test/api/admin/issue-reports/groups"),
      support,
    );
    expect(
      ((await groups.json()) as { groups: Array<Record<string, unknown>> })
        .groups[0],
    ).toMatchObject({
      id: groupId,
      reportCount: 1,
      affectedWorkerTypes: ["gemini"],
    });
    const groupDetail = await handleGetAdminIssueReportGroup(
      new Request("https://syntila.test/api/admin/issue-reports/groups/x"),
      support,
      groupId,
    );
    expect(
      ((await groupDetail.json()) as { group: { reports: unknown[] } }).group
        .reports,
    ).toHaveLength(1);
    await expect(
      handlePatchAdminIssueReport(
        new Request("https://syntila.test/api/admin/issue-reports/x", {
          method: "PATCH",
          body: JSON.stringify({ status: "open" }),
          headers: { "content-type": "application/json" },
        }),
        support,
        reportId,
      ),
    ).rejects.toMatchObject({ status: 409 });
  });

  it("keeps the report durable when R2 fails and enforces the per-user rate limit", async () => {
    const fixture = sqliteD1();
    seedExecution(fixture.sqlite);
    const failingBucket = {
      async put() {
        throw new Error("R2 unavailable");
      },
    } as unknown as R2Bucket;
    const env = envFor(fixture.db, "owner", { bucket: failingBucket });
    const created = await handleCreateIssueReport(
      new Request("https://syntila.test/api/issue-reports", {
        method: "POST",
        body: JSON.stringify({ requestId: "request-1" }),
        headers: { "content-type": "application/json" },
      }),
      env,
    );
    expect(created.status).toBe(201);
    expect(
      (
        fixture.sqlite
          .prepare("SELECT bundle_key FROM issue_report_diagnostics")
          .get() as { bundle_key: string | null }
      ).bundle_key,
    ).toBeNull();

    const now = new Date().toISOString();
    const insert = fixture.sqlite.prepare(
      `INSERT INTO issue_reports
         (id, public_reference, reporter_user_id, request_id, attempt_key,
          component, error_code, failure_stage, fingerprint, status,
          diagnostic_state, created_at, updated_at)
       VALUES (?, ?, 'owner', ?, ?, 'cloud', 'execution_failed', 'admission', ?, 'open', 'partial', ?, ?)`,
    );
    for (let index = 0; index < 19; index++) {
      insert.run(
        `issue-existing-${index}`,
        `ISS-EXISTING-${index}`,
        `request-existing-${index}`,
        `attempt-existing-${index}`,
        `fingerprint-existing-${index}`,
        now,
        now,
      );
    }
    fixture.sqlite.exec(`
      INSERT INTO worker_assignments(
        id,space_id,run_id,thread_id,work_request_id,execution_workspace_id,
        runtime_identity_id,worker_type_id,status,created_at,updated_at,
        workspace_worker_id,task_id,attempt_id,engine_version,model,error_json,
        permission_snapshot_json,session_policy
      ) SELECT 'assignment-rate-limit',space_id,run_id,thread_id,work_request_id,
        execution_workspace_id,runtime_identity_id,worker_type_id,status,
        '2099-01-02T00:00:00Z','2099-01-02T00:00:00Z',workspace_worker_id,'task-rate','attempt-rate',engine_version,
        model,error_json,permission_snapshot_json,session_policy
      FROM worker_assignments WHERE id = 'assignment-1';
    `);
    await expect(
      handleCreateIssueReport(
        new Request("https://syntila.test/api/issue-reports", {
          method: "POST",
          body: JSON.stringify({ requestId: "request-1" }),
          headers: { "content-type": "application/json" },
        }),
        env,
      ),
    ).rejects.toMatchObject({ status: 429 });
  });
});
