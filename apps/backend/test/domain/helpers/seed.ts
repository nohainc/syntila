/** Minimal valid rows for the real PostgreSQL schema (fixtures used to rely on SQLite's loose ad-hoc tables). */
export const T0 = "2026-01-01T00:00:00.000Z";
const q = (v: string) => `'${v.replace(/'/g, "''")}'`;
export const user = (id: string, extra: { email?: string; name?: string } = {}) =>
  `INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(${q(id)},${q(extra.email ?? `${id}@test`)},${q(extra.name ?? id)},'${T0}','${T0}') ON CONFLICT DO NOTHING;`;
export const space = (id: string, owner: string, name = id) =>
  `INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES(${q(id)},${q(owner)},${q(name)},'${T0}','${T0}') ON CONFLICT DO NOTHING;`;
export const member = (spaceId: string, userId: string, role = "owner") =>
  `INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES(${q(`m-${spaceId}-${userId}`)},${q(spaceId)},${q(userId)},${q(role)},'${T0}','${T0}') ON CONFLICT DO NOTHING;`;
export const thread = (id: string, spaceId: string, lead: string, name = id) =>
  `INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES(${q(id)},${q(spaceId)},${q(name)},'active',${q(lead)},'${T0}','${T0}') ON CONFLICT DO NOTHING;`;
/** user + owned space + membership + thread in one go. */
export const basicThread = (o: { user: string; space: string; thread: string; spaceName?: string; threadName?: string }) =>
  [user(o.user), space(o.space, o.user, o.spaceName), member(o.space, o.user), thread(o.thread, o.space, o.user, o.threadName)].join("\n");
let seq = 0;
/** A completed chat Work Request; `inputJson` is bound as `?` when given as "?". */
export const workRequest = (threadId: string, userId: string, inputJson = "?", id = `wr-seed-${++seq}`) =>
  `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
   VALUES(${q(id)},${q(threadId)},${q(userId)},'stateless','chat',1,'{}','completed',${inputJson === "?" ? "?" : q(inputJson)},'${T0}','${T0}')`;
export const message = (threadId: string, authorId: string, attachmentsJson = "?", id = `dm-seed-${++seq}`) =>
  `INSERT INTO discussion_messages(id,thread_id,author_user_id,body,attachments_json,created_at)
   VALUES(${q(id)},${q(threadId)},${q(authorId)},'seed',${attachmentsJson === "?" ? "?" : q(attachmentsJson)},'${T0}')`;
export const workspace = (id: string, owner: string, name = id) =>
  `INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES(${q(id)},${q(owner)},${q(name)},'${T0}','${T0}') ON CONFLICT DO NOTHING;`;
