# Issue Reporting v1

Issue reporting lets an authenticated user report a failed Work request with
one request. Cloud derives the report from the authoritative failed execution;
the browser cannot provide or override the account, Workspace, assignment,
diagnostics, or provider details.

## User and support APIs

The public routes are:

- `POST /api/issue-reports` with `{ "requestId": "..." }`.
- `GET /api/issue-reports/:id` for the reporter or another user who can view
  the referenced thread.
- `GET /api/issue-reports?requestId=...&assignmentId=...` to restore the
  reporter's status for a particular failed attempt.

Creation requires an authenticated session and a failed Work request. The
request owner is checked directly; other users must pass the existing thread
view policy. Repeating the same failed attempt for the same user returns the existing
report (`UNIQUE (reporter_user_id, attempt_key)`). A retry with a new
assignment has a new attempt key and can produce a separate report. The
response contains only the public reference, status, diagnostic state, and
timestamps.

Support routes are protected by the configured
`SYNTILA_ISSUE_SUPPORT_USER_IDS` allowlist:

- `GET /api/admin/issue-reports`
- `GET /api/admin/issue-reports/:id`
- `PATCH /api/admin/issue-reports/:id` with a status, optional bounded note,
  and optional incident-group assignment
- `GET /api/admin/issue-reports?status=...&component=...&errorCode=...&workerTypeId=...&createdAfter=...&createdBefore=...`
- `GET /api/admin/issue-reports/groups`
- `POST /api/admin/issue-reports/groups` to create an investigator-managed group
- `GET /api/admin/issue-reports/groups/:id`

Support responses may include sanitized diagnostics and the audit event list.
They never expose prompts, response content, credentials, arbitrary provider
stderr, environment variables, or local filesystem paths.

The Workspace assignment error has two channels. Its `error.message` is the
stable, user-facing execution message. An optional
`error.details.diagnostic` is a bounded, redacted technical detail used only
when Cloud assembles private issue-report evidence; it is not copied into the
Work result, public report response, or AX UI. Cloud sanitizes this field again
before persistence.

The [provider failure details contract](../roadmaps/PROVIDER_FAILURE_DETAILS_PLAN.md)
adds a separate Work-visible channel when Cloud encryption is configured. It
does not add provider text or failed-run responses to support reports or their
diagnostics; the private diagnostic channel above remains separate.

The Profile Lab's Issues area is the internal investigation console. It is
shown only to users with the issue-support permission and provides report
filtering, worker/model/effort and version evidence, a chronological
correlated timeline, missing-evidence indicators, internal notes, and status
management. Normal AX users do not receive these routes or UI controls.

Issue status transitions are bounded: `open` may remain open or move to
`investigating`; `investigating` may remain investigating or move to
`resolved`/`dismissed`; terminal statuses cannot be reopened through this
surface. Every view, status change, note, and group change is recorded in
`issue_report_events`.

## Work tab behavior

The Work tab shows `Report issue` only for an authoritative failed request.
Submitting it sends only the Work request reference, disables the action while
the request is in flight, and replaces it with a `Reported` indicator and a
short confirmation after durable storage succeeds. A reporting failure leaves
the execution and its Retry action unchanged and shows `Couldn't send the
report. Try again.` The client loads the reporter's existing report state when
failed history is refreshed, so navigation and reloads do not reset the
indicator. A retry with a new assignment is treated as a separate reportable
attempt while the reports retain the same Work request relationship.

## Storage and assembly

Migration `0039_issue_reports.sql` creates:

- `issue_reports` for the durable report identity, execution correlation,
  normalized failure classification, attempt idempotency key, grouping
  fingerprint, lifecycle status, and diagnostic completeness.
- `issue_report_diagnostics` for a bounded sanitized diagnostic document and an
  optional private R2 object reference and digest.
- `issue_report_events` for creation, views, status transitions, and support
  audit information.

Migration `0040_issue_report_investigation.sql` adds denormalized worker/model,
effort, application/Engine/Profile/provider version fields for safe filtering and creates
`issue_report_groups`. Groups are investigator-managed and may combine or
split reports independently of the diagnostic fingerprint; the fingerprint is
only a useful grouping signal, not a root-cause claim. Group list responses
include report count, first/last occurrence, and affected worker, Engine,
Profile, and provider versions.

Cloud assembles a report from the failed `work_requests` row, its latest run and
assignment, the assignment permission/profile snapshot, the latest
Workspace inventory provider version. The fingerprint contains only technical
attributes: component, normalized error code, failure stage, engine/profile
versions, and provider version. It never contains prompts or user IDs.

When available, the report's private diagnostic document also includes the
sanitized Workspace failure detail under `execution.failureDetail`. It is
bounded evidence for triage, not a promise that the full provider or process
log is available.

D1 metadata and the sanitized diagnostic document are written in one batch
before the optional R2 upload. If R2 is unavailable, the report remains
durable and is marked `partial`; a later enrichment process may add the bundle.
Workspace evidence distinguishes a disconnected or never-observed Workspace
(`state: disconnected`, `reason: assignment_not_observed`) from a Workspace
that returned a bounded assignment error but whose local diagnostic store was
not attached (`state: diagnostics_unavailable`). A connected Workspace may
therefore contribute the exact early Engine failure detail without implying
that a complete local log export was available.

The admin detail response exposes a normalized `investigation` summary and a
timeline made from sanitized diagnostic events and report audit events. It
identifies the first significant error when available and explicitly lists
missing evidence such as disconnected Workspace diagnostics or an unknown
provider version. This keeps a report useful when local evidence cannot be
retrieved.

The investigation console does not turn every server-side failure into a
full user report. Any future anonymous failure counters can be added as a
separate minimized aggregation path without changing report creation or the
diagnostic bundle contract.

## Retention and safety

Report bodies are capped at 4 KiB, support notes at 1,000 characters, and
report creation is rate-limited per authenticated user. R2 objects are stored
under a private `issue-reports/<report-id>/` key and are never returned to the
browser. Reporter deletion nulls the reporter reference while retaining the
execution evidence required for support audit; report and attachment retention
and account-erasure jobs apply the product's configured retention policy. The
Cloud scheduled retention task removes reports older than 30 days and deletes
their private R2 attachment first; if the attachment cannot be removed, the
report is retained for a later retry.
