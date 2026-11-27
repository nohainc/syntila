# Tool Profile Evidence-Bound Promotion Contract

**Status:** Promotion and Evidence Specification  
**Decisions:** ADR-018, ADR-019  
**Lifecycle Contract:** Tool Profile Lifecycle  
**Authority:** Cloud Evidence Validator (`apps/backend/src/domain/tool-profile-validation.ts`) and the PostgreSQL qualification/acceptance evidence tables

**Manual Profile lifecycle: COMPLETE** for the implemented control path and
fixture-backed acceptance. This status does not assert deployed Cloud or
real-provider rollout completion. Stored evidence is a digest-bound
authenticated assertion, not remote attestation of local execution.

---

## 1. Motivation & Problem Statement

In automated, AI-assisted, and distributed engineering workflows, claims such as *"tests passed"* or *"verified for release v19"* need a bounded contract that Cloud can validate and bind to the exact payload digest.

If testing evidence were associated merely with a human-readable identifier (such as `chatgpt-codex v19`):
1. An operator or AI model could run tests on candidate $A$, then modify a single argument or timeout value to produce candidate $B$, and promote candidate $B$ without re-testing.
2. An autonomous AI repair loop could iterate through multiple patches, conflate test results across iterations, and promote a candidate whose actual payload never passed live testing.
3. A client could submit a fabricated scenario claim or reuse a contract for a different payload unless Cloud checks the identity and digest.

Syntila enforces **digest-bound lifecycle records**: each accepted contract is bound to a canonical Profile digest and immutable release identity. This prevents a record for one payload from being reused for a different payload. The contract remains an authenticated Profile Lab assertion: Cloud does not remotely observe the local Engine or provider process and does not cryptographically attest that the submitted scenarios actually ran.

---

## 2. The Identity Triplet & Payload Digest

Every piece of testing evidence must be permanently bound to an immutable **Identity Triplet**:

```text
( profileDefinitionId, releaseVersion, payloadDigest )
```

### 2.1 Canonical Payload Serialization
Before computing the cryptographic digest, the Profile payload must be normalized into its canonical JSON form:
1. **Key Sorting:** Object keys are sorted lexicographically at every nesting depth.
2. **Whitespace:** Compact representation without pretty-printing indentations or trailing whitespace.
3. **Encoding:** Strict UTF-8 character encoding.
4. **Implementation:** The same canonical form is computed by Cloud and verified by Connect and Profile Lab.

### 2.2 Canonical Payload Digest Calculation
The canonical digest is the SHA-256 cryptographic hash of the canonical payload bytes:

$$\text{payloadDigest} = \text{SHA-256}(\text{canonicalPayloadJson})$$

Format:
- Exact 64 lowercase hexadecimal characters (e.g. `7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069`).
- Enforced at the database layer via:
  ```sql
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64)
  ```

---

## 3. The Evidence Staleness Invariant

> **The Canonical-Digest Invariant:**
> A change to the canonical Profile JSON changes its SHA-256 `payloadDigest`. A prior evidence contract remains bound to its original digest and cannot qualify a release with a different digest.

```text
Draft v19 (Payload A)
  digest: 7f83b1...
  Test Suite: ALL PASSED (evidence bound to 7f83b1...)
       |
  Edit 1 byte (e.g., timeout changed from 30 to 60)
       |
       v
Draft v19 (Payload B)
  digest: a4e892...
  Prior Evidence Status: STALE (bound to 7f83b1..., expected a4e892...)
  Promotion Status: BLOCKED until test suite re-runs on a4e892...
```

### Staleness Rules:
1. **No Cross-Digest Reuse:** Profile Lab associates local results with the candidate digest. Cloud checks submitted evidence identity and digest against the current draft or immutable release before storing or using the record.
2. **Draft → Testing Blocker:** Before publication, Profile Lab submits its complete local execution contract to `POST /api/admin/tool-profiles/{definitionId}/releases/{version}/qualification`. Cloud accepts qualification only while the exact release remains a mutable draft and the evidence identity, digest, Engine/provider version ranges, freshness, and contract-derived scenarios all validate against the stored draft.
3. **Publication Blocker:** `publishDraftToolProfileRelease` requires a `qualificationEvidenceId`. Cloud reloads that immutable record and repeats all qualification checks against the current draft digest in the signing operation. Missing, stale, mismatched, incomplete, or malformed qualification blocks signature generation and publication.
4. **Promotion Blocker:** Syntila Cloud accepts only an `acceptanceEvidenceId` that names a separately submitted immutable post-publication record for the same release and payload digest. Promotion requests never contain evidence JSON.

---

## 4. Normalized Evidence Schema

Local qualification and post-publication acceptance use the same shape validated by `ToolProfileAcceptanceEvidence` in `apps/backend/src/domain/tool-profile-validation.ts`. It retains all eight scenario keys. Cloud derives applicability from the actual signed execution contract: supported scenarios must be `passed`, while unsupported or untestable scenarios must be `not_applicable`. Failed or incomplete run details stay in the local Test Workbench result and are never submitted as qualification or acceptance evidence.

```json
{
  "formatVersion": 2,
  "profileDefinitionId": "chatgpt-codex",
  "releaseVersion": 19,
  "profileReleaseVersion": "19",
  "logicalWorkerTypeId": "chatgpt",
  "profileDigest": "7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069",
  "engineVersion": "1.2.0",
  "providerToolName": "codex",
  "providerToolVersion": "0.187.1",
  "acceptedAt": "2026-10-03T00:30:15.240Z",
  "scenarios": {
    "activity_mapping": "passed",
    "passive_probe": "passed",
    "usage_check": "passed"
  }
}
```

Cloud intentionally stores only this bounded contract for both local qualification and post-publication acceptance. The local ladder's stage durations, issue codes, and diagnostic messages remain outside the Cloud evidence object. Qualification and acceptance use separate immutable Cloud tables and IDs. A later fresh run can qualify after an earlier record expires. Cloud validates the submitted metadata and scenario statuses; it cannot independently verify the local process, provider version, or execution result, so these values are not remote device attestation.

Version 2 adds `not_applicable` status semantics. Cloud rejects version 1 evidence for new validation; historical version 1 rows remain stored unchanged.

The scenario set was reduced on 2026-10-21 to `activity_mapping`, `passive_probe` and `usage_check`; no scenario calls a model. Engine and CLI version ranges, the representative write, session create/resume, cancellation and timeout are no longer part of the evidence: version ranges are enforced by Connect readiness on the user's machine, and cancellation and timeout are Engine behavior covered by Engine and supervisor tests. Evidence submitted with the earlier scenario set is rejected for new validation.

Local qualification, publication, acceptance, and promotion are separate requests:

```text
POST /api/admin/tool-profiles/{definitionId}/releases/{version}/qualification
{ "evidence": { ...complete formatVersion 2 contract... } }
-> { "qualificationEvidenceId": "<immutable ID>" }

POST /api/admin/tool-profiles/{definitionId}/releases/{version}/publish
{ "qualificationEvidenceId": "<ID returned by qualification>" }

POST /api/admin/tool-profiles/{definitionId}/releases/{version}/evidence
{ "evidence": { ...complete formatVersion 2 contract... } }

POST /api/admin/tool-profiles/{definitionId}/releases/{version}/promote
{ "channel": "stable", "acceptanceEvidenceId": "<ID returned by evidence submission>" }
```

The publish endpoint rejects client signature/key fields and requires a stored local qualification ID. The promotion endpoint rejects `acceptanceEvidence` JSON. Cloud resolves each ID within the same release and digest and revalidates its immutable record before the transition.

### 4.1 Required Metadata Attributes:

| Field | Type | Description |
| :--- | :--- | :--- |
| `formatVersion` | `2` | Schema version of the execution evidence format. |
| `profileDefinitionId` | `string` | Target Profile Definition identifier (e.g. `chatgpt-codex`). |
| `releaseVersion` | `integer` | Target integer release version (e.g. `19`). |
| `profileReleaseVersion` | `string` | Decimal representation of `releaseVersion`. |
| `profileDigest` | `string` | Exact 64-character SHA-256 hash of the canonical payload. |
| `logicalWorkerTypeId` | `string` | Logical worker identity (e.g. `chatgpt`). |
| `engineVersion` | `string` | Semver of the CLI Worker Engine used during testing. |
| `providerToolName` | `string` | Binary name of the provider CLI (e.g. `codex`). |
| `providerToolVersion`| `string` | Semver of the installed provider CLI tool tested against. |
| `acceptedAt` | `ISO 8601` | Client-reported UTC completion time for required scenarios. Cloud checks its format and freshness. |
| `scenarios` | `map<string, "passed" | "not_applicable">` | Exactly the eight Cloud scenarios. Statuses must match the signed execution contract derived by Cloud. |

---

## 5. Normalized Issue Codes

When tests fail or encounter warnings, errors must be mapped to normalized issue codes rather than dumping raw, variable terminal strings:

| Issue Code | Category | Meaning |
| :--- | :--- | :--- |
| `NONE` | Success | Scenario completed successfully. |
| `SCHEMA_VIOLATION` | Static Validation | Payload fails JSON Schema or exceeds machine bounds. |
| `ENGINE_INCOMPATIBLE`| Engine Compatibility| Installed CLI Worker Engine is outside supported semver range. |
| `CLI_NOT_FOUND` | Discovery | Provider executable candidates could not be located on disk. |
| `CLI_VERSION_UNSUPPORTED`| Version | Detected provider CLI version is outside supported version range. |
| `AUTH_PROBE_FAILED` | Passive Probe | Provider CLI is not logged in or passive check failed. |
| `LIVE_PROBE_FAILED` | Live Probe | Live model inference ping failed or returned provider error. |
| `PARSE_ERROR` | Execution | Engine could not parse provider output / stream events. |
| `SESSION_START_FAILED`| Sessions | Provider CLI failed to emit a valid session identifier. |
| `SESSION_RESUME_FAILED`| Sessions | Resuming existing session failed or started fresh session. |
| `TIMEOUT_EXPIRED` | Timing | Process exceeded the configured test deadline. |
| `PROCESS_LEAK` | Process Safety | Child process did not terminate cleanly upon cancellation. |

---

## 6. Promotion Gates and Evidence Validation

Promotion through the lifecycle channels requires meeting specific evidence criteria:

```text
[ Draft Candidate ]
       |
       | Local Sandbox Test Suite
       v
+-------------------------------+
| Gate 1: Publish to Testing    | ---> Requires complete local Engine qualification
+-------------------------------+      bound to profileDigest; optional scenarios may be not_applicable
       |
       v
[ Testing Channel ]
       |
       | Multi-Connect Canary
       v
+-------------------------------+
| Gate 2: Promote to Beta       | ---> Requires testing channel verification & operator authorization
+-------------------------------+
       |
       v
[ Beta Channel ]
       |
       | Full Real-Provider Acceptance Suite
       v
+-------------------------------+
| Gate 3: Promote to Stable     | ---> Requires a complete Cloud-validated acceptance contract:
+-------------------------------+      - profileDigest match
                                       - engineVersion within supported range
                                       - providerToolVersion within supported range
                                       - acceptedAt within 90 days
                                       - required scenarios "passed" and optional scenarios "not_applicable" according to the Profile
                                       - explicit human confirmation
```

Cloud's gate validates the submitted contract's shape, identity, digest,
version claims, freshness, and contract-derived statuses. It does not verify
the local executable, observe the test process, or provide device attestation.
The Profile Lab client enforces the supported execution flow by producing a
contract only after its sandbox scenarios pass; a caller with API access can
still submit a contract directly. Treat stored evidence IDs as immutable,
digest-bound records of an authenticated assertion, not independent proof of
local execution.

### Gate 1: Draft → Testing local qualification

Profile Lab emits qualification only after the full Test Ladder reports overall
pass. The ladder has six stages: schema validation, event mapping replay,
executable discovery, CLI version command (the command must succeed and print
something; the value is recorded, not compared), passive probe, and provider
usage check. No stage calls a model. The scenarios are:

- `passive_probe` is always required and must be `passed`;
- `usage_check` is always required and must be `passed`; it runs the
  Profile's `usage` command and calls no model. A Profile without a `usage`
  command fails this stage and Cloud refuses to publish it;
- `activity_mapping` must be `passed` when the Profile has JSONL activity
  mappings, otherwise `not_applicable`.

The sandbox emits the evidence contract only after its real Engine scenarios
pass, and Profile Lab submits that contract to Cloud before publication. Cloud
checks the current draft digest and identity, that Engine and provider
versions are present, the 90-day freshness bound, and all three scenario statuses. It stores qualification in
`tool_profile_local_qualification_evidence`; publication must reference that
stored ID and Cloud repeats validation immediately before signing. This
server-side gate validates the submitted contract; the local sandbox is the
execution authority in the supported Profile Lab flow and emits no contract
after a failed or incomplete run. The Cloud API accepts authenticated contract
submissions and does not prove which client produced them or observe a provider
CLI on the operator's machine. This workflow is not device attestation.

### Gate 3: Stable Promotion Validation Invariants
As enforced by `validateToolProfileAcceptanceEvidence()` in `apps/backend/src/domain/tool-profile-validation.ts`:
1. **Digest Equality:** `evidence.profileDigest === release.payload_digest`.
2. **Identity Alignment:** Definition ID, release version, and logical worker type must match the database record.
3. **Engine Version Recorded:** `evidence.engineVersion` must be a non-empty string. It is not compared with `profile.engineCompatibility`; Connect enforces that range at runtime.
4. **Tool Version Recorded:** `evidence.providerToolVersion` must be a non-empty string. It is not compared with `profile.providerTool.supportedVersions`; Connect enforces those ranges at runtime.
5. **Freshness:** `acceptedAt` timestamp must not be in the future (within clock skew) and must be $\le 90\text{ days}$ old.
6. **Contract-Derived Scenarios:** Cloud expects every scenario key and derives applicable statuses from the signed Tool Profile:
   - `activity_mapping` (`passed` when the Profile has JSONL activity mappings; otherwise `not_applicable`)
   - `passive_probe`
   - `usage_check` (always `passed`; Cloud also rejects publication of a Profile without a `usage` command)
7. **Database Persistence:** Evidence is stored immutably in `tool_profile_acceptance_evidence` when submitted, separately from promotion. Multiple immutable records may exist for one release digest.

---

## 7. AI Automation Invariants

When AI models participate in Profile maintenance (e.g. self-healing Profiles when a provider CLI updates):

1. **Proposal Is Not Evidence:** The model-backed Draft proposal flow cannot submit qualification or acceptance records. The supported Profile Lab test path emits a contract only after its Engine scenarios pass. Cloud validates the record shape and digest binding but does not independently attest to local execution.
2. **Digest Binding after AI Edits:** When an operator applies a model proposal to a Draft, the candidate digest is recomputed when saved. Evidence for the previous digest cannot qualify the changed payload.
3. **Closed-Loop AI Verification:** An automated AI repair cycle must follow:
   $$\text{Failing Test} \longrightarrow \text{AI Generates Draft Patch} \longrightarrow \text{Re-calculate Digest} \longrightarrow \text{Run Sandbox Tests} \longrightarrow \text{Digest-Bound Evidence Recorded}$$
4. **Local Proposal Provenance:** Profile Lab stores proposal provenance in local Draft metadata. Cloud lifecycle audit records publication and channel transitions; they do not currently attest to or store the model name, prompt hash, or local execution transcript.
