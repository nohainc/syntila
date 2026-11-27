# Provider discovery and normalization

How the generic Engine turns a provider CLI's own model output into the public
catalog described in [Worker execution options v2](WORKER_EXECUTION_OPTIONS_V2.md).
Profile fields are defined in [Tool Profile v1](TOOL_PROFILE_V1.md#model-effort-and-discovery);
the Gemini/AGY specifics are in [Gemini / AGY Profile](../architecture/GEMINI_AGY_PROFILE.md).

## Principles

- The runtime catalog is the only source of choices for a discovery-backed Profile.
  The Profile carries no fallback catalog or guessed effort rules (the exception is
  the ID-only formats named in Tool Profile v1, where the Profile supplies efforts).
- Nothing is inferred: absent variants, unknown IDs and defaults the provider did
  not report are never invented. Unclassified native IDs stay separate entries with
  their own identity and no efforts.
- A failed or malformed discovery may fall back only to the cache bound to the exact
  same Profile digest and CLI version; missing CLI support cannot manufacture
  capabilities.
- Native IDs and variant bookkeeping never leave the machine (Connect strips them
  before inventory publication).

## Derived efforts (Gemini / AGY)

Models and efforts come only from the CLI's `models` output, so a new provider model
needs no Profile change. The Profile declares only how a line is read, in
`model.discovery.effortVariants`; it requires `selectionMode: combined`, no
`selectionMapping`, and Engine 1.3.0 or newer:

```json
{"source": "label_parenthesized_suffix", "separator": "-"}
```

A line `gemini-4-argon-high<TAB>Gemini 4 Argon (High)` yields effort `high` from the
lower-cased parenthesized label suffix, family ID `gemini-4-argon` by removing
`<separator><effort>` from the native ID, and family name `Gemini 4 Argon`. Lines of
one family are grouped, efforts are ordered low to max, and the execution value is
rebuilt as `<family><separator><effort>`, so an effort the CLI did not print cannot be
selected. A line whose label or ID does not follow the rule stays a plain model
without an effort choice. No default effort is inferred, and a duplicate effort in one
family fails discovery.

Codex reads models and efforts from its app-server (`id` is the logical selection,
`model` the native identity, plus `supportedReasoningEfforts` and
`defaultReasoningEffort`; there is no shared GPT effort matrix). Other providers use
the formats listed in Tool Profile v1 (`tsv`, `clap_possible_values`, `indented_list`,
`copilot_sdk_rpc`, `claude_models_api`, optional `effortProbe`).

## Signed mapping

`model.selectionMapping` (schema version 1, Engine 1.2.0 or newer) remains available
for providers whose native IDs cannot be derived from the CLI output. It is finite
signed data and requires `selectionMode: combined`, discovery and model support; it
adds no provider adapter or suffix heuristic.

```json
{
  "schemaVersion": 1,
  "models": [{
    "id": "family-id", "name": "Family name",
    "variants": [{
      "nativeId": "family-id-low", "effort": "low",
      "providerVersion": {"min": "1.3.3", "maxExclusive": "1.3.4"}
    }]
  }]
}
```

A family may declare an evidence-backed `defaultEffort`; omission means no known
default. A selected combined family with efforts and no default requires an explicit
effort in Core, the app's workflow validation and the Engine; an all-null Auto
selection defers to the provider. There is no first-variant or "High" fallback.
Bounds: 128 families, 128 native variants in total, 16 efforts per family. Duplicate
logical IDs, overlapping native ownership and overlapping family/effort rows are
rejected, as are an invalid default and an inverted range. Version intervals are
semantic-version ranges (minimum inclusive, maximum exclusive; absent matches every
version), and disjoint intervals may map renamed native IDs to one logical selection.

## Execution and availability

- **Combined selections.** The Engine intersects the signed or derived native table
  with this CLI version and this discovery response; only present variants become
  supported efforts and empty families disappear. A collision between a logical family
  and an unclassified ID fails discovery. A selected pair resolves to one
  version-compatible native row and the Engine emits `--model <nativeId>` through the
  Profile's model argument slot; the separate `reasoningEffort` argument is
  suppressed, so no conflicting effort flag is sent. Unsupported pairs fail before the
  provider runs. Cloud checks advertised combined efforts against the signed table and
  rejects widened or invented defaults.
- **Separate selections** (Codex and others) pass the discovered native model and the
  signed separate effort argument mapping.
- **Variant availability** is tracked in the local catalog's private `variantStatuses`.
  A rejection disables only that effort; verified siblings stay selectable. A family
  is unavailable when every variant is, and verified when every available variant has
  executable success evidence. A refresh keeps statuses only inside the exact
  Profile/CLI binding and only for efforts still discovered. The catalog revision
  includes the binding and statuses in a stable order; public clients receive only the
  opaque revision and aggregate selection metadata.

## Display in Connect

The Service projects filtered static model names and `hasModelDiscovery` from the
resolved Profile through local IPC. Worker cards use static names for Profiles without
discovery (for example Claude with an empty runtime catalog). Allowlist and
availability filtering still apply, and an empty discovered catalog for a Profile with
discovery stays authoritative; no discovery state is synthesized.

## Verification

Engine process fixtures exercise exact native arguments with no separate effort flag,
rejection of a missing or unsupported effort, sibling variants staying usable after
one is rejected, versioned renames, version gates, duplicate and malformed output, and
unclassified ID collisions (`engines/cli_worker/test/combined_model_execution_test.dart`,
`model_discovery_test.dart`, `native_model_execution_test.dart`). Fixtures prove
parameter routing; real provider execution is separate, opt-in acceptance.
