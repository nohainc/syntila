# Worker Profile V9

**Status:** Canonical contract, implemented
**Scope:** Syntila Cloud, Profile Lab, Connect, CLI Worker Engine, and the logical Worker catalog

This specification defines the identity, publication, verification,
activation, and execution-snapshot contract for Worker Profiles. There is one
current published Profile per Worker Type and no release channels.

The normative terms **MUST**, **MUST NOT**, **SHOULD**, and **MAY** describe
requirements for V9 implementation work.

## 1. Core decision

Syntila has exactly one centrally published Profile for each logical Worker.
That Profile is the authoritative JSON definition of the Worker's behavior.

```text
Profile Lab operator
        |
        | validate, test, publish request
        v
Syntila Cloud
        | one current published Profile + bounded history
        | atomic publication and authorization
        v
Syntila Connect / Service
        | fetch -> verify -> cache -> activate
        v
Generic CLI Worker Engine
        | interprets the execution snapshot
        v
Provider CLI
```

The Engine remains provider-independent. ChatGPT, Gemini, and future logical
Workers differ through Profile data and the provider CLI they describe, not
through provider-specific Engine executables or branches in Cloud or
Connect.

## 2. Shared identity model

| Concept | V9 meaning |
| --- | --- |
| Logical Worker | Stable product identity selected by AX, Workflows, Cloud, and Connect, such as `chatgpt` or `gemini`. |
| Profile | One canonical JSON behavior definition belonging to exactly one logical Worker. |
| Profile revision | Cloud-assigned monotonically increasing revision of the same logical Worker's published Profile. A revision is not an active release channel. |
| Profile digest | SHA-256 digest of the canonical Profile JSON. |
| Profile candidate | Unpublished JSON being edited and tested in Profile Lab. It is not a published Profile and is never admitted to normal Connect execution. |
| Profile snapshot | The verified Profile identity, revision, digest, and canonical JSON captured for one execution. It remains immutable until that execution completes. |
| Known-good history | Retained prior published snapshots used for audit or restoration. Historical snapshots are not separately active. |

The V9 contract uses one stable logical Worker identity and one current
published Profile identity. Storage may separate current state, audit history,
audit metadata and payload blobs, but those implementation details MUST NOT create
multiple active Profiles for one logical Worker.

## 3. Required invariants

1. **One current Profile:** Cloud MUST expose at most one current published
   Profile for each logical Worker, and a valid Worker MUST have exactly one
   when it is enabled for execution.
2. **Authoritative JSON:** The canonical Profile JSON is the source of truth
   for executable behavior. Identity, revision, digest, actor, and timestamps
   are metadata around that JSON, not competing
   behavior definitions.
3. **Authorized publication:** Only an authorized Profile Lab operator MAY
   publish or restore a Profile. AI assistance MAY edit a candidate but MUST
   NOT publish or activate it.
4. **Provider-independent Engine:** The generic CLI Worker Engine owns process
   supervision, protocol handling, limits, session integrity, and security
   invariants. Profiles select only behavior supported by its finite schema.
5. **Atomic publication:** Cloud MUST validate, canonicalize, digest, assign
   the next revision, persist the current Profile, and record audit evidence as
   one atomic state transition. A partial publication MUST NOT be
   observable as current state.
6. **Verified Connect activation:** Connect MUST fetch, verify, cache, and
   validate a Profile before activation. A failed candidate MUST NOT replace
   the active cached Profile.
7. **Stable execution snapshot:** An execution MUST use the Profile snapshot
   selected at activation/assignment time. Later publication, restoration, or
   cache refresh MUST NOT rewrite that execution's Profile identity.
8. **Multiple provider CLI versions:** Profiles support all provider CLI
   versions and omit `providerTool.supportedVersions`. Bounded version-specific
   overrides MAY adjust behavior using their own `providerVersion` ranges;
   unmatched versions use the base Profile. Test evidence records the exact
   tested version without defining a support range.
9. **Restoration is republishing:** A known-good historical Profile MAY be
   restored, but Cloud MUST publish it as a new current revision. History MUST
   NOT be exposed as a separate active release channel.
10. **No Profile channels:** V9 MUST NOT define or expose testing, beta, or
    stable Profile channels, channel pointers, promotion workflows, or channel
    rollback.

## 4. Profile JSON contract

The Profile JSON contains bounded execution behavior only. It MUST be valid
against the versioned Profile schema and MUST NOT contain provider credentials,
arbitrary code, shell command strings, or unconstrained expressions.

A Profile MAY include, subject to the Engine schema:

- provider executable candidates and version detection;
- supported provider CLI version ranges;
- bounded compatibility overrides for non-overlapping version ranges;
- authentication/readiness probes;
- structured execution arguments and prompt transport;
- output/event extraction and error mappings;
- model and session/resume mappings;
- progress and timeout behavior;
- provider environment allowlists and bounded permission mappings.

The shape below is illustrative; the schema version is independent of the V9
architecture version:

```json
{
  "schemaVersion": 1,
  "providerTool": {
    "name": "codex",
    "executableCandidates": ["codex"],
    "supportedVersions": [
      { "min": "0.180.0", "maxExclusive": "0.200.0" }
    ]
  },
  "execution": {
    "arguments": ["exec", "--json", "-"],
    "stdin": { "mode": "raw_text", "value": "{{prompt}}" }
  },
  "compatibilityOverrides": []
}
```

The Engine MUST detect the installed provider CLI version, select one
unambiguous compatible behavior, and fail closed with a diagnostic when the
version is unknown or unsupported.

## 5. Publication and restoration

Profile Lab owns the candidate workflow:

```text
edit candidate -> schema validation -> Engine/provider test -> operator review
       -> authorized Cloud publication request
```

The V9 Profile Lab authoring surface is editor-first. Selecting a Worker opens
its JSON candidate directly; Worker navigation remains a narrow collapsible
sidebar, while the Worker header is limited to identity, provider CLI, current
revision, and editing status. Testing and structured inspection are secondary
collapsible panels, with testing defaulting to a bottom panel so the JSON
editor retains most of the window. Focus mode may hide those auxiliary panels
and the sidebar without discarding unsaved text, cursor selection, or scroll
position for any Worker.

Profile Lab editing MUST keep local development state separate from publication:

- `Save` writes the validated candidate locally; it MUST NOT publish or sync to
  Cloud implicitly, including through the `⌘S` shortcut.
- Profile Lab MAY retain bounded, local recovery buffers, including incomplete
  JSON. Recovery buffers MUST remain outside the saved candidate and MUST NOT
  count as validation, test evidence, or publication input until explicitly
  restored and saved.
- The editor MUST expose independent `Saved/Unsaved`, `Valid/Invalid`, and
  `Tests Passed/Failed/Not Run` states. A candidate digest change invalidates
  digest-bound validation and test evidence immediately.
- Formatting, compare-with-current, restore, and AI repair are secondary
  actions. AI repair produces an editable candidate and MUST require the same
  validation, testing, and operator publication flow as manual edits.
- Syntax diagnostics SHOULD identify a line and column when the parser
  provides an offset; schema diagnostics without a source offset remain
  ordinary validation messages.

The test surface is a collapsible result panel, hidden until a run begins or
the operator opens it. It MUST summarize `Passed`, `Failed`, `Not Applicable`,
and `Not Run` checks, while retaining detailed provider logs, execution events,
error codes, and timing behind expandable results. Every result is bound to the
candidate digest; changing the candidate invalidates the result set. The main
editor toolbar owns the single `Publish` action, and the publication review
shows a compact current-versus-candidate comparison, including provider CLI,
environment, and security-sensitive changes.

For JSONL Workers, the panel also includes Event Mapping Replay. It applies the
candidate's declarative `activity.mappings` to sanitized Codex or agy fixtures,
including repeated tool calls and unknown events, and binds the result to the
candidate digest. Invalid selectors, unsupported mapping fields, and unsafe
detail extractors are rejected before publication. The legacy percentage
mapping remains only as a temporary compatibility path for older Connect
clients.

The V9 integration evidence also includes a real Engine-process harness with a
controlled fixture CLI. It verifies delayed and high-frequency JSONL activity,
large responses, provider failure and missing-terminal outcomes, and concurrent
Worker isolation. The harness is provider-shaped but credential-free; real
Codex and agy acceptance remains an explicit, locally authorized device test.

The V9 cleanup invariant is that no production Profile Lab route can reach a
draft-release, promotion, testing/beta/stable channel, or channel-browsing
screen. Diagnostic audit history, local recovery snapshots, test scenarios,
and Profile history remain available because they support operations;
none of them is an alternate active Profile state. The editor and its local
candidate state must survive Worker switching, panel resizing, focus mode, and
background test progress. Compact macOS windows must preserve readable JSON,
keyboard access, visible focus, sufficient contrast, and accessible labels.

Cloud owns the authoritative transition:

1. authenticate the Profile Lab audience and required operator permission;
2. verify the candidate's logical Worker identity and schema;
3. verify validation/test evidence is bound to the candidate digest;
4. canonicalize the JSON and calculate its digest;
5. allocate the next Cloud revision;
6. atomically replace the logical Worker's current published Profile and append
   audit/history metadata in one database transaction.

Cloud MUST NOT persist a snapshot until the revision, Worker identity, schema
version, and canonical payload digest checks succeed. The current row and its
prior-history append are one atomic operation; a failed conditional revision
update MUST leave both unchanged.

Publication requests MUST use optimistic concurrency against the current
revision or digest so that a stale candidate cannot silently overwrite a newer
publication.

Restoration uses the same path: the operator selects a retained known-good
snapshot, Profile Lab revalidates it, and Cloud publishes the same JSON as a
new revision. The restored historical revision remains history only. Profile
Lab history is therefore a comparison and recovery view, not a second
publication channel; restoration always creates a new current revision and
refreshes the synchronized editor state.

## 6. Connect verification, caching, and activation

An authenticated, non-revoked Connect runtime MAY fetch a catalog Worker's
current published Profile before configuring that Worker locally. The read
endpoint MUST NOT require a `worker_inventory` row: Profile sync
precedes local setup and inventory publication. Runtime authentication and
published Profile identity, schema and digest checks remain required. Profile
download alone does not configure, enable, or authorize execution of a Worker.
When a verified download cannot yet be probed because no local Worker record
exists, the Service reports the Profile as `staged` (`Downloaded`) and the
Worker as `Setup required`. It MUST NOT label that expected setup state a
Profile error or activate the staged payload before probing. Failed downloads,
invalid snapshots and incompatible Engines retain their actual failure states.

Connect MUST treat Cloud as the authority for the current Profile but MUST
remain able to operate from its verified local cache when synchronization is
temporarily unavailable.

For a newly fetched or refreshed Profile, Connect MUST:

1. verify the logical Worker identity, digest, and canonical JSON;
2. validate the Profile schema and Engine compatibility;
3. detect the installed provider CLI and validate the declared version range;
4. stage the verified payload in Profile-owned application data;
5. initialize/probe it through the generic Engine as required by the runtime;
6. atomically mark it current only after all admission checks pass;
7. retain the prior verified known-good snapshot for recovery and diagnostics.

Connect MUST repeat the canonical digest and schema verification locally.
A snapshot that fails any check MUST remain staged or be discarded and MUST
NOT become the active Profile.

Activation failure leaves the prior active cache entry unchanged. A revoked,
invalid, incompatible, or tampered Profile MUST fail closed and MUST NOT be
used for a new execution.

The on-disk V9 cache is keyed by logical Worker and contains only current and
last-known-good snapshot/payload pairs, plus bounded immutable revision payloads
needed by in-flight executions. Refresh is periodic or event-triggered, not
part of every assignment. A fetched snapshot is verified, staged, and then
activated for new executions; the resolver never searches a release list.

Explicit revocation of current must not fall back to last-known-good. Each execution
opens an immutable `revision-digest` payload, so activation of a later Profile
cannot rewrite the bytes used by an execution already in progress.

Connect's Worker management view is operational rather than publication-
oriented. It SHOULD show the logical Worker, provider tool and detected CLI
version, current Profile revision and status, enabled/disabled state,
readiness, and execution permissions. It MUST NOT expose Profile channels,
release promotion, or publication workflow details. A small update check and a
local Worker test remain available as user-facing actions.

## 7. Execution snapshots and continuity

When Connect admits an assignment, it binds the execution to a Profile
snapshot containing at least:

```text
logicalWorkerId
profileRevision
profileDigest
engineVersion
providerToolName
providerToolVersion
```

The Engine receives the canonical JSON for that snapshot and MUST NOT reload
the current Cloud or Connect Profile during the execution. New executions
may use a later revision only after Connect has verified and activated it.
Existing executions finish under their original snapshot, including retries
that are part of the same execution lifecycle.

The generic Engine input is limited to the resolved Profile JSON, its digest
and revision, the execution request, and the effective authorization policy.
The Engine does not interpret publication history, channels, qualification
evidence, or Profile Lab state. Provider CLI compatibility and argument
selection remain data-driven by the one admitted Profile, so ChatGPT, Gemini,
and fixture providers use the same execution pipeline.

## 8. Component ownership

| Component | V9 responsibility | V9 prohibition |
| --- | --- | --- |
| Cloud | Own logical Worker identity, current Profile, revision/digest metadata, bounded history, authorization, atomic publication, and audit. | Must not execute provider CLIs or expose multiple active channels. |
| Profile Lab | Edit candidates, validate, run Engine-backed provider tests, show diffs, request publication, and request known-good restoration. | Must not publish without operator authorization, store provider credentials, or make candidates active in Connect. |
| Connect / Service | Fetch, verify, cache, activate, snapshot, and supervise Profile-backed Engine executions. | Must not edit Profile JSON, select a channel, or use an unverified payload. |
| CLI Worker Engine | Interpret the finite Profile schema, supervise provider CLI processes, enforce limits/security/session integrity, and emit provider-neutral results. | Must not contain provider-specific Worker executables or bypass Profile/Connect admission. |
| AX / product workflows | Select logical Workers and display safe readiness/diagnostic metadata. | Must not edit or directly activate Profiles. |

## 9. Persistence contract

Cloud stores the current published state in one PostgreSQL `worker_profiles`
row keyed by `worker_type_id`. The row contains the canonical JSON, schema
version, Cloud revision, digest, publishing actor, and timestamp.

The Worker catalog also retains the configured Profile identity
(`profile_definition_id` and `provider_tool_name`). This metadata is needed
only while a Worker has no current Profile, so Profile Lab can create its
first local candidate without inventing provider-specific defaults. Once a
Profile is published, its JSON is authoritative for execution behavior.

Cloud stores prior published snapshots in `worker_profile_history`, keyed by
`(worker_type_id, revision)`, with the snapshot JSON, digest, actor, publication
timestamp, and optional restoration reason. History is for audit and
restoration only; it is never selected through a channel pointer. Migrations
are forward-only (see the backend migrations README).

## 10. Cloud API contract

The V9 Cloud API exposes one current Profile identity per logical Worker:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/admin/workers` | List managed Workers, configured authoring identity, and current Profile summaries. |
| `GET` | `/api/admin/workers/:id/profile` | Read the current published Profile. |
| `POST` | `/api/admin/workers/:id/profile/validate` | Validate candidate JSON and optional test evidence without publishing. |
| `PUT` | `/api/admin/workers/:id/profile` | Publish a tested candidate as the next revision. |
| `GET` | `/api/admin/workers/:id/profile/history` | Inspect retained previous snapshots. |
| `POST` | `/api/admin/workers/:id/profile/restore` | Republish a retained snapshot as a new revision. |
| `GET` | `/api/workers/:id/profile` | Return the verified current Profile to an authorized Connect runtime. |

The publish request MUST contain `expectedRevision`, `candidateDigest`, the
candidate `profile`, and recent `evidence`. `expectedRevision` is `0` only
for a Worker with no current Profile. Cloud recalculates the canonical digest,
validates the Profile schema and compatibility ranges, and checks evidence
identity and freshness. Client evidence demonstrates
what Profile Lab reported from its local Engine/CLI test; it is not treated as
cryptographic proof of local execution.

The endpoints accept no channel names, promotion actions, release statuses,
or draft-publication transitions.

## 11. Shared validation and interpretation

Cloud, Profile Lab, Connect, and the CLI Worker Engine MUST use the same
provider-neutral V9 validation contract. The shared contract is implemented by
the TypeScript `@syntila/tool-profile` package for Cloud-side validation and
the Dart `syntila_tool_profile_v1` package for Profile Lab, Connect, and
Engine runtime validation. Both implementations MUST remain semantically
aligned with the versioned Profile schema.

The Dart package owns the canonical V9 snapshot admission check used by both
Profile Lab and Connect. Each consumer supplies the expected Worker identity
and repeats digest/schema validation locally.

The validation contract MUST include:

- strict JSON schema validation, including rejection of unknown fields unless
  a versioned compatibility rule explicitly defines them;
- Engine version compatibility, provider executable discovery, provider CLI
  version ranges, argument expansion, standard-input configuration, model
  discovery/selection, session continuation/reconstruction, sandbox mappings,
  output event parsing, error classification, environment restrictions, and
  timeout/size limits;
- deterministic SemVer precedence and non-overlapping compatibility ranges;
- at most one matching compatibility override for an installed provider CLI;
- fail-closed behavior for unknown, unsupported, or ambiguously matched
  provider versions.

Compatibility resolution produces an effective interpretation of the same
Profile snapshot. It MUST NOT create a second Profile identity, revision, or
digest. Identity metadata continues to refer to the admitted canonical
snapshot while version-specific behavior is selected only after provider
version discovery.

## 12. Acceptance contract

The V9 contract is accepted when all four runtime/control-plane components
reference this specification and agree on these facts:

- the same stable logical Worker identity names the Profile in Cloud, Profile
  Lab, Connect, and Engine admission data;
- the same canonical JSON and digest identify the behavior being published,
  cached, activated, and executed;
- the same Cloud-assigned revision identifies the current published state;
- publication and restoration are operator-authorized and atomic;
- Connect activation and Engine execution use a verified immutable snapshot;
- no component requires Profile testing, beta, or stable channels.

## 13. Connect cache

Connect keeps only the verified current snapshot and one verified
last-known-good snapshot. A last-known-good snapshot is an offline recovery
cache, never a second release channel; explicit revocation still prevents its
activation.

Implementation changes to routes, storage, local caches, protocol frames, and
tests must trace back to this contract and must not introduce a second Profile
identity or lifecycle.
