# Provider discovery and normalization — Phase 3

Implemented 2026-10-11. Architecture v8 and the Connect service ownership
boundary remain unchanged. Extends [Worker execution options v2](WORKER_EXECUTION_OPTIONS_V2.md)
and [Tool Profile v1](TOOL_PROFILE_V1.md).

## Derived efforts (Gemini / AGY)

`model.selectionMapping` is no longer used by the Gemini Profile. Models and
efforts come only from the CLI's own `models` output, so a new provider model
(for example Gemini 4 Argon) needs no Profile change. The Profile declares only
how a line is read, in `model.discovery.effortVariants`, which requires
`selectionMode: combined`, no `selectionMapping` and minimum Engine 1.3.0:

```json
{"source": "label_parenthesized_suffix", "separator": "-"}
```

A line `gemini-4-argon-high<TAB>Gemini 4 Argon (High)` yields effort `high` from
the lower-cased parenthesized label suffix, family ID `gemini-4-argon` by
removing `<separator><effort>` from the native ID, and family name
`Gemini 4 Argon`. Lines of one family are grouped, efforts are ordered
low to max, and the execution value is rebuilt as `<family><separator><effort>`
(an effort the CLI did not print cannot be selected). A line whose label or ID
does not follow the rule stays a plain model without an effort choice. No
default effort is inferred; a duplicate effort in one family fails discovery.
Claude keeps its Profile `catalog`; Codex reads models and efforts from its
app-server. The signed mapping below remains supported for providers whose
native IDs cannot be derived.

## Signed mapping

Optional `model.selectionMapping` schema version 1 is finite signed data. It
requires `model.selectionMode: combined`, discovery, model support, and minimum
Engine 1.2.0. It does not introduce a provider adapter or suffix heuristic.

```json
{
  "schemaVersion": 1,
  "models": [{
    "id": "gemini-3.8-flash",
    "name": "Gemini 3.8 Flash",
    "variants": [{
      "nativeId": "gemini-3.8-flash-low",
      "effort": "low",
      "providerVersion": {"min": "1.3.3", "maxExclusive": "1.3.4"}
    }]
  }]
}
```

Each family may declare an evidence-backed `defaultEffort`. Omission means no
known default. A selected combined family with efforts and no default requires
an explicit effort in Core, AX workflow validation and Engine execution. All-null
Auto selection continues to defer to the provider. There is no first-variant or
High fallback.

Bounds: 128 logical families, 128 native variants total, 16 distinct efforts per
family. Duplicate logical IDs, overlapping native ownership and overlapping
family/effort rows are rejected. Version intervals are semantic-version ranges,
minimum inclusive and maximum exclusive; absent intervals match every version.
Disjoint intervals may map renamed native IDs to the same logical selection.
An invalid default or inverted range invalidates the signed mapping.

## Discovery and execution

Codex remains app-server discovery. Actual model IDs, native `model` values,
per-model `supportedReasoningEfforts` and `defaultReasoningEffort` are preserved.
Execution uses the discovered native model and the signed separate effort
argument mapping. There is no shared GPT effort matrix.

For combined selections, the Engine intersects the signed exact native table
with this CLI version and this discovery response. Only present variants become
supported efforts. Empty families disappear. Unclassified native IDs remain
separate entries with their native identity and no inferred efforts. A collision
between a logical family and an unclassified ID fails discovery. A failed or
malformed discovery can use only the existing cache with the exact same Profile
digest and CLI version; absent CLI support cannot manufacture capabilities.

A selected logical pair resolves to one version-compatible signed native row.
The Engine emits `--model <nativeId>` through the existing Profile model argument
slot. Combined selection suppresses the separate `reasoningEffort` argument
context; no conflicting `--effort` is emitted. Unsupported pairs fail before
provider execution. Cloud additionally checks advertised combined efforts against
the signed versioned table and rejects widening or invented defaults.

Variant verification/availability is tracked in the local v2 catalog's private
`variantStatuses` map. Rejection disables only that effort; verified siblings
remain selectable. A family is unavailable when every variant is unavailable,
and verified when all available variants have executable success evidence.
Refresh preserves statuses only in the existing exact Profile/version cache
binding and only for still-discovered efforts. Connect strips both native ID
and variant status bookkeeping before inventory publication. Catalog revision
includes local binding and statuses, with stable ordering; public clients receive
only the existing opaque revision and aggregate public selection metadata.

## Installed AGY mapping

The current authoring candidate applies these exact rows to the AGY versions
admitted by the Profile (1.2.16 and 1.3.3). The mapping intentionally omits a
variant-level version bound because both admitted versions expose the same
native identifiers. The Profile's `supportedVersions` remains the outer gate;
future AGY versions require separate discovery evidence and a reviewed Profile
update before they can use these rows.

| Logical ID | Supported efforts | Native invocation | Default |
| --- | --- | --- | --- |
| gemini-3.8-flash | low, medium, high | `--model gemini-3.8-flash-<effort>` | Unknown; explicit effort required |
| gemini-3.7-flash | low, medium, high | `--model gemini-3.7-flash-<effort>` | Unknown; explicit effort required |
| gemini-3.6-flash | low, medium, high | `--model gemini-3.6-flash-<effort>` | Unknown; explicit effort required |
| gemini-3.1-pro | low, high | `--model gemini-3.1-pro-<effort>` | Unknown; explicit effort required |

The table abbreviates the eleven explicit signed rows; the Engine never constructs
native IDs using this display notation. Discovery evidence is retained in
[the Phase 1 audit](../architecture/MODEL_EFFORT_SELECTION_PHASE_1.md).

## Validation and rollout

The process fixture exercises all eleven pairs, rejects missing efforts, checks
exact native argv with no separate effort flag, rejects one variant and verifies
its siblings remain usable after discovery refresh. Unit coverage includes exact
installed discovery, duplicates, malformed output, missing/unsupported CLI,
versioned renames, version gates and unclassified ID collisions. Codex native
invocation and effort preservation have separate process-level coverage.

Engine version advances from 1.1.0 to 1.2.0; both canonical materializations are
rebuilt. Profiles without the optional mapping retain their existing behavior.
The candidate remains unsigned and inactive: no signed release, admission,
production deployment, persistent selection rewrite, or database migration is
performed. Existing saved native IDs remain distinct only while discovered and
unmapped; selecting newly grouped families requires an explicit reviewed pair.
A future activated Profile release must treat changed saved IDs as unsupported
and allow users to reselect, rather than guessing a migrated effort.

Validation record: all 46 Engine tests passed; worker protocol 27 and Dart Profile
25 passed during component validation; focused Cloud/Core/inventory tests passed;
AX model/workflow tests 15 passed. Type checks for Cloud, Core, Tool Profile and
runtime protocol passed. Broader Cloud/shared scope: 678 passed, one existing
fixture failure (`capabilities` forbidden in worker inventory). Engine component
validation stops on existing supervisor formatting; AX component validation stops
on existing app-state/cache formatting. These unrelated files were preserved.
Focused Connect registry/inventory coverage verifies private-field stripping.
No real provider inference was run: process fixtures prove parameter routing,
while the installed catalog establishes listed support. Provider-account execution
verification remains a separate release acceptance activity.

## Connect static model display and Gemini reversal (2026-10-13)

The Service projects filtered static model names and hasModelDiscovery from its
resolved Profile through existing local IPC. Worker cards use static names for
Profiles without discovery, including Claude with an empty runtime catalog.
Allowlist and availability filtering remain enforced; an empty discovered catalog
for a Profile with discovery stays authoritative. No discovery state is synthesized.

At the user's request, migration 0052 reverses the model mapping additions from
0050 and 0051. It restores the exact pre-change payload from immutable history
only for those two known digests, advances the revision, and preserves dynamic
CLI discovery and live-activity behavior. Applied migrations remain historical
records. Customized Profiles or missing restoration history are left untouched.
The added authoring candidate and Engine test changes are reverted; the Claude
display fix remains. Saved family selections introduced by the reverted mapping
may require reselection. Runtime refresh invalidates the prior catalog by digest.

Reversal verification: seven focused Cloud migration tests, thirteen Engine
discovery/execution tests, and two Connect static/empty-catalog regressions
passed. Production and the running Connect show the original digest at
revision 9; the live Gemini Worker Test passed and both Workers show Ready.
Cloud component validation stops on existing stale generated types; Engine
component validation stops on existing unrelated formatting violations.

## Catalog corrections — 2026-10-13

All Gemini/AGY runtime authoring templates now include exact mappings for the
observed `claude-opus-5-5` and `claude-sonnet-5-5` low/medium/high variants and
`gpt-oss-120b-medium`. Installed `agy models` returned these ten native rows
alongside Gemini 3.8 Flash on this date. Normalization still intersects exact
Profile data with discovery; absent variants and unknown IDs are never inferred.

The Claude Code template declares per-model effort options and an optional
`--effort {{reasoningEffort}}` invocation. Opus and Sonnet advertise low, medium,
high, xhigh and max; Haiku retains no efforts because the installed 2.1.287 CLI
predates the documented Haiku 5.5 support. No provider default is asserted.
The template requires Claude Code 2.1.287 or later. Source:
[Claude Code model configuration](https://code.claude.com/docs/en/model-config).
Local version/help inspection confirmed 2.1.287 and the effort argument; no
provider inference or account entitlement qualification was performed.

Migration `0053_correct_model_effort_profiles.sql` updates only exact known
canonical payload digests, records the previous Profile in history and increments
its revision. Customized Profiles are untouched and require the same reviewed
metadata update through Profile Lab. Saved native variant selections are not
rewritten; users must reselect the logical model/effort pair after activation.
The migration must be applied and updated Profiles refreshed before existing
installations display the corrected choices. No remote deployment is performed
by this source change.
