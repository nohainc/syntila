# Input Delivery v1

Status: implemented. Owners: Cloud (`routes/work-request-inputs.ts`,
`workflow.ts` gate), Workspace Service (`input_delivery.dart`,
`work_request_input_staging.dart`), AX (`ax_input_delivery.dart`).

Input Delivery moves a Work Request's file inputs from AX to the Workspace
that runs the request, before any Worker starts. It replaces inline base64
file content in `assignment.start`, which bounded the total size of a
request's files by the WebSocket frame limit (32 MiB).

## Goals

- Send works like any message: the request is accepted at once and the
  composer unlocks; files move in the background.
- Uploads (AX → Cloud) and downloads (Cloud → Workspace) overlap: a file is
  downloadable as soon as it is uploaded, while the next one still uploads.
- No file content on the runtime WebSocket. Bytes stream over authenticated
  HTTPS straight from R2, so no frame limit applies and the HTTPS fallback
  transport works too.
- The Worker starts only when every file is verified on the Workspace; a file
  that cannot be delivered fails the request with its reason.
- A failed transfer restarts the whole file (no resume).
- One download serves every Workflow step and retry of the request.

Limits: 10 files per request; per-file and total-storage limits follow the
uploader's plan (Free 25 MB / 1 GB, Plus 100 MB / 25 GB, decimal bytes;
ADR-025). Uploads stream: Cloud never buffers a raw body, and the Workspace
streams the staged file into the execution directory, so a 100 MB file does
not sit in memory.

## Data model

`work_request_inputs` (migration `0088`), one row per file, keyed by the
Cloud-generated `fileId` (`wrf-<uuid>`, also the R2 key
`work-request-inputs/<fileId>`):

| state             | meaning                                                  |
| ----------------- | -------------------------------------------------------- |
| `awaiting_upload` | accepted in the manifest; no verified bytes yet           |
| `uploaded`        | bytes in R2 with SHA-256 `content_digest`; downloadable   |
| `delivered`       | the target Workspace stored and verified the bytes        |
| `failed`          | gave up uploading or delivering; fails the request        |

`upload_attempts` / `delivery_attempts` count whole-file attempts;
`error_message` is shown to the user. `workspace_id` is the request's
`primary_workspace_id`. `work_requests.input_json` stays immutable (the
existing trigger); the verified digest and display previews live on the row
and are merged into dispatch (`withInputFacts`) and history reads.

## Flow

1. **Accept.** AX submits the request with a manifest entry per picked file:
   `{kind: "file", name, mediaType, sizeBytes, delivery: "upload"}` (no
   bytes). Cloud assigns `fileId`s, checks quota against declared sizes,
   requires a target Workspace, and inserts the rows with the request in one
   batch. Files already uploaded (an existing `fileId`) start as `uploaded`.
2. **Upload.** AX uploads up to 3 files at once:
   `PUT /api/work-requests/:id/inputs/:fileId` (raw bytes, or multipart with
   a JPEG preview). Only the requester may upload; the size must match the
   manifest; uploaded/delivered files are immutable; uploads are refused once
   the request ended or was cancelled. A failure restarts the file from
   scratch (3 attempts). After the last one AX reports
   `POST /api/work-requests/:id/inputs/:fileId/failed {message}`.
3. **Wake.** After each upload Cloud sends the target Service
   `input.available` (empty payload) through the Workspace Gateway. It is
   only a hint.
4. **Download.** The Service lists
   `GET /api/workspace-runtime/inputs?workspaceRuntimeId=…` (runtime bearer
   credential; inputs of open requests on its Workspace, state `uploaded`),
   on wake-up, on session readiness, every 2 s while work is pending and
   every 30 s when idle. It downloads up to 3 files at once from
   `GET …/inputs/:fileId/content`, streaming to
   `<Application Support>/staged-inputs/<fileId>.partial` while hashing, and
   publishes the file atomically only if size and digest match. Then it
   confirms `POST …/inputs/:fileId/delivered {contentDigest}`. A failed
   attempt deletes the partial file and reports
   `POST …/inputs/:fileId/attempt {final: false, message}`; the third
   reports `final: true`, which marks the input `failed`.
5. **Gate.** The request's Workflow, after `work_request.started` and before
   dispatching any step, waits until every row is `delivered`
   (`waitForEvent("work-inputs")`, re-reading D1 at least every 30 s). It
   fails the request (first step `failed` with the input's reason) when a row
   is `failed`, or when no row changed for 10 minutes; it ends as cancelled
   on cancellation. Retries (`retryStepKind`) skip the gate.
6. **Run.** Dispatch is unchanged. Attachments carry `fileId` and
   `contentDigest`; the Service copies each verified file to
   `.syntila/inputs/<workRequestId>/file-NNN`. A copy missing from the store
   (retention, later retry) is downloaded again before the provider starts.

Downloaded files are kept 7 days and serve every step of the request.

## Progress

Cloud publishes `work_request.input_updated` and wakes the Workflow on every
state change. The detail response `GET /api/work-requests/:id` includes
`inputs: [{fileId, name, sizeBytes, state, uploadAttempts,
deliveryAttempts, errorMessage?}]`. The sending AX shows a CLI-like block on
the request card until all files are ready, for example:

```
Delivering files to the Workspace (1/3 ready)…
✓ spec.pdf — ready
↓ data.csv — downloading to the Workspace (attempt 2)
↑ photo.jpg — uploading
```

## Security

- Upload: authenticated user with execute access to the Thread who is the
  request's requester.
- Runtime endpoints: Workspace runtime credential; an input is visible only
  to the runtime of its `workspace_id`. Bytes are served only in `uploaded` or
  `delivered` state, and only if the R2 object's size and digest match the
  row.
- The Service accepts only `wrf-` identities and `sha256:` digests, never
  writes outside its store, and verifies the digest on write and read.
- `input.available` carries no identifiers or content.

## Known limits

- Upload progress is per file, not per byte.
- If the sender closes AX before its uploads finish, the request fails after
  the 10-minute idle limit; the user sends it again.
- Only the sending AX shows the progress block; other viewers see the
  request queued until it runs or fails.
- Chat (discussion) attachments still upload to Cloud before the message is
  posted; they share the same upload code (parallel, whole-file retries).
