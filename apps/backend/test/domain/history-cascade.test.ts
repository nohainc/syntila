/** Work history follows its Thread and Space (migration 0014). */
import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";

function seed() {
  const fixture = pgD1();
  fixture.sqlite.exec(`
    INSERT INTO users(id,email,display_name,status,created_at,updated_at) VALUES ('owner','owner@test','Owner','active','now','now');
    INSERT INTO spaces(id,name,owner_user_id,created_at,updated_at) VALUES ('space-1','Space','owner','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES ('m-1','space-1','owner','owner','now','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES
      ('thread-1','space-1','One','active','owner','now','now'), ('thread-2','space-1','Two','active','owner','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES ('ws-1','owner','Workspace','online','now','now');
    INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES ('rt-1','ws-1','hash','inst-1','now');
  `);
  for (const thread of ["thread-1", "thread-2"]) {
    fixture.sqlite.exec(`
      INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,primary_workspace_id,input_json,created_at,updated_at,snapshot_json)
        VALUES ('req-${thread}','${thread}','owner','stateless','direct',2,'{}','completed','ws-1','{}','now','now','{}');
      INSERT INTO runs(id,space_id,thread_id,work_request_id,status,created_at,updated_at) VALUES ('run-${thread}','space-1','${thread}','req-${thread}','completed','now','now');
      INSERT INTO workflow_tasks(id,work_request_id,step_instance_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
        VALUES ('task-${thread}-a','req-${thread}','a','plan','stateless_read',1000,'plan:v1','completed','now','now'),
               ('task-${thread}-b','req-${thread}','b','plan','stateless_read',1000,'plan:v1','completed','now','now');
      INSERT INTO workflow_task_dependencies(task_id,depends_on_task_id) VALUES ('task-${thread}-b','task-${thread}-a');
      INSERT INTO worker_assignments(id,space_id,run_id,thread_id,work_request_id,execution_workspace_id,runtime_identity_id,worker_type_id,status,created_at,updated_at,workspace_worker_id,task_id,attempt_id,engine_version,model,permission_snapshot_json,session_policy)
        VALUES ('asg-${thread}','space-1','run-${thread}','${thread}','req-${thread}','ws-1','rt-1','gemini','completed','now','now','w-1','task-${thread}-a','att-1','1.0.0','m','{}','stateless');
    `);
  }
  return fixture;
}

const count = (sqlite: ReturnType<typeof pgD1>["sqlite"], table: string, where = "TRUE") =>
  Number((sqlite.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${where}`).get() as { n: number }).n);

describe("work history cascades", () => {
  it("deleting a Thread removes its requests, tasks, assignments and runs, and nothing of other Threads", () => {
    const { sqlite } = seed();
    sqlite.prepare("DELETE FROM threads WHERE id = ?").run("thread-1");
    for (const table of ["work_requests", "runs", "workflow_tasks", "worker_assignments"])
      expect(count(sqlite, table, "id LIKE '%thread-1%'")).toBe(0);
    expect(count(sqlite, "workflow_task_dependencies", "task_id LIKE '%thread-1%'")).toBe(0);
    for (const table of ["work_requests", "runs", "worker_assignments"])
      expect(count(sqlite, table, "id LIKE '%thread-2%'")).toBe(1);
  });

  it("deleting a Space removes everything below it in one statement", () => {
    const { sqlite } = seed();
    sqlite.prepare("DELETE FROM spaces WHERE id = ?").run("space-1");
    for (const table of ["threads", "work_requests", "runs", "workflow_tasks", "worker_assignments", "space_memberships"])
      expect(count(sqlite, table)).toBe(0);
    expect(count(sqlite, "execution_workspaces")).toBe(1);
  });

  it("an assignment cannot point at a task that does not exist", () => {
    const { sqlite } = seed();
    expect(() => sqlite.exec(`UPDATE worker_assignments SET task_id = 'missing' WHERE id = 'asg-thread-1'`)).toThrow(/foreign key/i);
  });
});
