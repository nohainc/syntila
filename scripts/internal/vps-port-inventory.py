import re,glob,os,collections
src='apps/cloud/src'
files={f:open(f).read() for f in glob.glob(src+'/**/*.ts',recursive=True)}
rel=lambda f:f[len(src)+1:]
router=files[src+'/routes/router.ts']
handlers=sorted(set(re.findall(r'handlers\.(\w+)!',router))|set(re.findall(r'await (handle\w+)\(',router)))
defs={}
for f,t in files.items():
  for h in re.findall(r'export (?:async )?function (handle\w+)',t): defs.setdefault(h,rel(f))
SLICE=[ # (slice, file regex)
 ('6 Foundation (router)',r'^routes/router\.ts$'),
 ('8 Stays on Cloudflare',r'^backend-token\.ts$'),
 ('7.1 Identity & accounts',r'^(auth/|routes/(auth|profile|profile-lab-policy)\.ts|account-|routes/http-security|routes/handlers|people\.ts$)'),
 ('7.2 Spaces & people',r'^routes/(spaces|space-|people|notes|pins|notifications|home|user-files|workspace-invitations|workspace-people|conditional-read|mutation-idempotency)'),
 ('7.3 Threads & conversation',r'^(routes/(threads|thread-|conversation|reply-references|work-request-inputs)|thread-coordinator|collaboration-events|work-session-key)'),
 ('7.4 Execution & workflows',r'^(routes/(work|implement-plan|workflow|mcp-)|workflow|scheduler|assignment-|execution-|mcp-tool|worker-execution-options|upload-stream|attachment-storage)'),
 ('7.5 Workspace runtime',r'^(workspace-gateway|routes/workspace|routes/workspaces|routes/worker-plugins|routes/worker-output-images|workspace-audit|plugin-manifest)'),
 ('7.6 Catalog, releases & admin',r'^(routes/(profiles?|profile-admin|releases|issue-reports)|worker-profile-registry|tool-profile-validation|release-trust|issue-report|worker-activity|canonical-json)'),
 ('7.7 Realtime, cron & email',r'^(realtime-|event-publisher|observability|email/|invitation-email|avatar-storage|service-readiness|index\.ts)'),
]
def slice_of(path):
  for s,rx in SLICE:
    if re.search(rx,path): return s
  return '7.? unassigned'
schema=open('.development/d1-final-schema.sql').read()
tables=re.findall(r'CREATE TABLE "?(\w+)"?',schema)
triggers=re.findall(r'CREATE TRIGGER (\w+)\s+(?:BEFORE|AFTER)\s+(?:INSERT|UPDATE|DELETE)(?: OF [\w, ]+)? ON "?(\w+)',schema)
out=['# VPS port inventory (generated)','','Generated from `apps/cloud` and the final local D1 schema (migration 0114). Regenerate with `scripts/internal/vps-port-inventory.py`.','']
bysl=collections.defaultdict(list)
for f in sorted(files): bysl[slice_of(rel(f))].append(rel(f))
out+=['## Source files by port slice','','| Slice | Files | Lines |','| --- | --- | --- |']
for s in sorted(bysl):
  fl=bysl[s]; out.append(f"| {s} | {', '.join('`'+x+'`' for x in fl)} | {sum(files[src+'/'+x].count(chr(10)) for x in fl)} |")
out+=['','## Route handlers ('+str(len(handlers))+')','','| Handler | Defined in | Slice |','| --- | --- | --- |']
for h in handlers:
  d=defs.get(h,'?'); out.append(f"| `{h}` | `{d}` | {slice_of(d) if d!='?' else '?'} |")
out+=['','## Tables ('+str(len(tables))+')','','| Table | Referenced by | Port slice |','| --- | --- | --- |']
for t in tables:
  refs=[rel(f) for f,txt in files.items() if re.search(r'\b'+t+r'\b',txt)]
  sl=collections.Counter(slice_of(r) for r in refs).most_common(1)
  out.append(f"| `{t}` | {len(refs)} files | {sl[0][0] if sl else '— unused → drop'} |")
out+=['','## Triggers ('+str(len(triggers))+') → PL/pgSQL or application invariants','','| Trigger | Table |','| --- | --- |']+[f'| `{n}` | `{t}` |' for n,t in triggers]
iso=collections.Counter()
for f,t in files.items():
  n=len(re.findall(r"strftime\(|datetime\(|json_extract|INSERT OR (?:IGNORE|REPLACE)|json_each|json_group_array|json_object\(|randomblob|typeof\(|\blast_insert_rowid|ON CONFLICT[^;]*DO NOTHING",t))
  if n: iso[rel(f)]=n
out+=['','## SQLite-specific SQL to rewrite','','| File | Sites |','| --- | --- |']+[f'| `{f}` | {n} |' for f,n in iso.most_common()]
bind=collections.defaultdict(list)
for f,t in files.items():
  for b in ['SYNTILA_DB','SYNTILA_ARTIFACTS','SYNTILA_EMAIL','SYNTILA_WORKSPACE_GATEWAY','SYNTILA_REALTIME_GATEWAY','SYNTILA_THREAD_COORDINATOR','SYNTILA_RUN_WORKFLOW','waitUntil']:
    if b in t: bind[b].append(rel(f))
target={'SYNTILA_DB':'PostgreSQL via pg-d1 adapter','SYNTILA_ARTIFACTS':'Bun.S3Client → R2','SYNTILA_EMAIL':'Cloudflare email relay','SYNTILA_WORKSPACE_GATEWAY':'in-process WorkspaceGateway service','SYNTILA_REALTIME_GATEWAY':'in-process realtime gateway on Bun pub/sub','SYNTILA_THREAD_COORDINATOR':'in-process coordinator + PostgreSQL locks','SYNTILA_RUN_WORKFLOW':'PostgreSQL durable workflow runner','waitUntil':'tracked background promise queue'}
out+=['','## Cloudflare bindings → replacements','','| Binding | Used in files | Replacement |','| --- | --- | --- |']+[f'| `{b}` | {len(v)} | {target[b]} |' for b,v in bind.items()]
out+=['','## Scheduled jobs','','| Schedule | Jobs |','| --- | --- |','| every 5 min | recoverStaleAssignments, sweepUnsignaledTerminals, sweepStaleExecutionWaiters, sweepExpiredUploadReservations, sweepThreadRequestQueues |','| daily 03:17 UTC | + pruneExpiredRealtimeEvents, pruneWorkerActivityHistory, pruneExpiredIssueReports (and the rest of `index.ts` scheduled) |','']
open('docs/roadmaps/VPS_PORT_INVENTORY.md','w').write('\n'.join(out)+'\n')
print(len(handlers),len(tables),len(triggers),sum(iso.values()), dict(collections.Counter(slice_of(rel(f)) for f in files)))
unused=[t for t in tables if not any(re.search(r'\b'+t+r'\b',x) for x in files.values())]
print('unused:',unused)
