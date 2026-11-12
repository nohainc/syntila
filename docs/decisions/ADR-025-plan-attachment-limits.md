# ADR-025: Plan-based attachment storage and file limits

Status: accepted. Extends [ADR-022](ADR-022-account-plans.md).

## Policy (decimal bytes)

|                        | Free              | Syntila Plus        |
| ---------------------- | ----------------- | ------------------- |
| Total uploaded storage | 1 GB (1,000,000,000)  | 25 GB (25,000,000,000) |
| Individual file size   | 25 MB (25,000,000)    | 100 MB (100,000,000)   |

**Unit change.** The earlier limits were binary: 1 GiB (1,073,741,824 bytes)
total and 10 MiB (10,485,760 bytes) per file. Free's total is therefore about
7% *smaller* than before (a Free account that used between 1,000,000,000 and
1,073,741,824 bytes is now over quota and is treated as an existing over-quota
account, below) and its file limit is larger. UI sizes use decimal units too
(`formatFileSize`: kB, MB, GB). The 10-attachments-per-submission cap and the
separate Worker artifact-upload limits are unchanged.

The policy lives in `account-plan.ts` (`ATTACHMENT_LIMITS`) with the other plan
rules; the plan comes from the **uploader's** effective entitlement (expiry and
`past_due` grace as in ADR-022), never from the Space owner. A Free member of a
Plus-owned Space has Free limits; a Plus uploader in a Free Space has Plus
limits. `GET /api/me/plan` returns `attachments { maxFiles, maxFileBytes,
storageBytes }` and `GET /api/files` returns `usage { usedBytes, fileCount,
reservedBytes, quotaBytes, maxFileBytes }`; the web app loads limits from them.

Generated files collected from an assignment's output directory use the same
storage and per-file limits, reservations, My Files records, sync and deletion
as request attachments. Their owner and quota account are the Space owner,
including when another member requested the work or another Workspace ran it.
The Workspace collects at most ten non-empty regular files per assignment;
files rejected by storage limits are not attached. Images retain inline previews
and other files appear as downloadable attachment cards. Existing generated
images stored before this policy are not automatically imported.

## Accounting
- Usage is the sum of the uploader's `user_files` rows: actual retained bytes,
  wherever the file lives (archived Spaces and Threads included).
- A reference (a message or Work Request citing a `fileId`) owns no bytes, so
  reuse costs nothing; an independently uploaded copy is another row and costs
  its size. There is no cross-account deduplication.
- Storage is freed only when the object is removed (`DELETE /api/files/:id`
  deletes the R2 objects first, then the row) or confirmed absent
  (`POST /api/files/sync`), never by dropping a reference.
- `POST /api/files/sync` reconciles rows with R2 (imports unrecorded objects,
  corrects sizes, removes rows whose object is gone). Run it per account when
  usage looks wrong.

## Enforcement
Every upload path (`POST /api/threads/:id/work-request-files` for Message and
Ask AI pre-uploads, and `PUT /api/work-requests/:id/inputs/:fileId` for Input
Delivery) goes through `storeWorkRequestFile`:
1. **Reserve** - `reserveUpload` inserts into `user_file_reservations` only if
   the size is within the uploader's per-file limit and retained bytes plus
   other live reservations plus this file fit the total allowance (one atomic
   statement; the file's own earlier reservation/row is excluded, so retries
   are idempotent). A refusal returns HTTP 413 with a stable code:
   `file_too_large` or `storage_quota_exceeded`.
2. **Store** - the body is streamed to R2 (below); the byte count is enforced
   exactly against the declared `Content-Length`, so a false declared size is
   rejected (`upload_size_mismatch`) and nothing is kept.
3. **Finalize** - the stored size is read back (`head`), entitlement and quota
   are rechecked (excluding the upload's own reservation), and the `user_files`
   row is written while the reservation is deleted in one batch.
Any failure deletes the partial object and releases the reservation.
Reservations expire after one hour and then count for nothing; the 5-minute
cron also deletes expired rows. Work Request acceptance checks the declared
per-file size and the total early (non-binding); the upload reserves atomically.

Referencing a file that is already stored is never limited by the current plan
or quota: a downgraded or over-quota account keeps every file, its downloads
and its deletion, and nothing is deleted automatically. Only new uploads are
refused.

## Large-file delivery
The previous path buffered the body (`arrayBuffer`, `formData`) and the digest
input, which does not fit a 128 MB Worker for a 100 MB file. Now:
- **Raw bodies stream.** `Content-Length` is required (411
  `content_length_required`). The body is counted, tee'd into R2
  (`FixedLengthStream`) and a `DigestStream` (SHA-256); memory stays at a few
  chunks. The digest of a streamed object is known only afterwards, so it is
  kept in a small `<key>/meta` sidecar (older objects keep it in R2 metadata);
  `storedFileDigest` reads either.
- **Multipart bodies are buffered**, so they are accepted only up to the Free
  file size (25 MB); larger files must be raw (413 `upload_requires_raw_body`)
  and carry no preview image. Text previews are taken from the first bytes.
- The Workspace stages downloads by streaming (`stageStream`) and now copies the
  verified staged file into the execution directory by streaming
  (`copyTo`); a retry compares a streamed digest instead of reading bytes. Its
  per-file sanity bound is 100,000,000 bytes.
- **Evidence** (`apps/cloud/scripts/large-upload`, real workerd via
  `wrangler dev --local`): a 100,000,000-byte raw upload stored all bytes with a
  matching SHA-256; workerd peaked at about +40-50 MB over idle, versus about
  +270 MB for the previous buffering approach on the same file.
- **Edge limit.** Cloudflare caps request bodies by zone plan (100 MB on Free
  and Pro zones, more on Business/Enterprise). 100,000,000 bytes fits, but the
  deployed zone's plan was not verified here; confirm it before relying on the
  Plus limit in production.

## Upload allowance versus Worker capability
An upload being stored says nothing about whether a Worker can read the file.
The composers state this beside "Add files" and Syntila does not claim
processing support; whether a given Worker/provider handles a large or unusual
file is not verified by this change.

## User experience
My Files shows usage against the allowance and the per-file limit, warns from
80%, and when full explains that new uploads are blocked while existing files
stay downloadable and deletable. Composers give per-file feedback before upload
("too large" versus "storage is full"). There is no upgrade action to link yet
and no checkout flow; the copy only names Syntila Plus.

## Rollout
- Apply migration `0098_user_file_reservations.sql` before deploying Cloud.
- Deploy Cloud, the web app and the Workspace together: an older Workspace
  rejects inputs over 10 MiB, an older web app sends the old limits and reads
  `usage` without the new fields.
- Existing Free accounts between 1,000,000,000 and 1,073,741,824 bytes become
  over quota; they keep all files and cannot upload until under 1 GB.

## Limitations
- The web client still reads a picked file fully into browser memory (and as
  base64); a 100 MB file is held several times over while uploading.
- The Workspace Service still buffers a downloaded file once for the digest on
  `read` (used by older callers); the execution path streams.
- Reservations are not restored by the cron if a Worker dies mid-upload until
  they expire (one hour), though they never block beyond that.
