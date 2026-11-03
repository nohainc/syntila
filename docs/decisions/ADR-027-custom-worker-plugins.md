# ADR-027: Custom Worker plugins (Syntila Plus)

**Status:** Proposed (Phase 0 design; no runtime code)
**Date:** 2026-11-03
**Amends:** [Architecture v8](../architecture/ARCHITECTURE_V8.md#architecture-contract) execution path and the `provider_specific_worker_executable` exclusion
**Builds on:** [ADR-018](ADR-018-generic-cli-worker-engine-and-tool-profiles.md), [ADR-021](ADR-021-workspace-service-linux-windows.md), [ADR-022](ADR-022-account-plans.md)
**Details:** [Architecture](../architecture/CUSTOM_WORKER_PLUGINS.md), [Plugin protocol](../specifications/WORKER_PLUGIN_PROTOCOL_V1.md), [Management IPC](../specifications/WORKER_PLUGIN_MANAGEMENT_IPC_V1.md), [Plan and open decisions](../roadmaps/CUSTOM_WORKER_PLUGINS_PLAN.md)

## 1. Context

Every executable Worker today is an official Logical Worker: Cloud's
`worker_catalog` names it, one Cloud-published Profile describes it, and the
generic CLI Worker Engine runs a provider CLI under that Profile. Users cannot
add their own Worker (an in-house model gateway, a local-model wrapper, a
domain tool). Syntila Plus users want to import such Workers as separate
executables in any language and have them appear in the normal Workers list and
Work flow.

Architecture v8 excludes `provider_specific_worker_executable`, and AGENTS.md
rule 5 forbids introducing provider-specific Worker executables. A plugin is an
executable that Syntila does not ship, so the exclusion has to be read
carefully rather than waived.

## 2. Decision

1. **A plugin executor path is added below the Engine, not beside it.** The
   generic CLI Worker Engine gains a second *executor kind*, `plugin`, next to
   `profile`. The path becomes:

   ```text
   AX → Cloud → Workspace Service → CLI Worker Engine
        ├─ executor=profile → current Worker Profile → provider CLI   (unchanged)
        └─ executor=plugin  → pinned plugin digest   → plugin process (new)
   ```

   The Service still spawns only the Engine. The Engine, as the existing
   separately supervised child, spawns and supervises the plugin process and
   speaks the [Worker Plugin Protocol](../specifications/WORKER_PLUGIN_PROTOCOL_V1.md)
   to it, translating to the existing Local Worker Protocol frames
   (`execute.request`, `progress`, `activity`, `result`, `error`) upward. The
   Engine reuses its process-tree cleanup, Windows Job Object, environment
   builder, cancellation and redaction. Local Worker Protocol advances to a
   backward-compatible 4.2 that adds an optional `executor` object; 4.0 and 4.1
   peers are unchanged.

2. **Official Workers are untouched.** They keep the shared Engine and the
   current Worker Profile. There is no Profile editor, no public Profile
   schema, and no way to express an official Worker as a plugin: plugin type
   IDs live in a reserved `plugin-` namespace that Profile Lab and the official
   catalog cannot publish into.

3. **The `syntila` CLI never executes a plugin.** Import, validate, conformance
   test, register, export, enable/disable and remove are authenticated IPC
   commands to the Service. The CLI reads and displays results. A plugin file is
   copied into Service-owned storage by the Service, not by the CLI.

4. **A plugin is data to Syntila, not provider knowledge.** Core, Cloud,
   Workspace and the Engine contain no branch on any plugin's identity or on a
   provider. A plugin is identified by `(pluginId, version, digest, origin)`.
   Cloud schedules it like any Logical Worker through a catalog row, and the
   assignment snapshot pins its digest.

5. **Plugins are a Syntila Plus feature, gated by Cloud.** A new paid feature
   `workers.custom_plugins` uses the ADR-022 mechanism (`PAID_FEATURES`,
   `requirePaidFeature`, `paidOwnerSql`). Cloud decides on import, enablement,
   assignment admission and Workspace start-up; local state is a UX hint. See
   [Entitlement design](../architecture/CUSTOM_WORKER_PLUGINS.md#3-entitlement-design).

6. **A process boundary is not a sandbox.** A plugin runs as the logged-in user,
   under the user's own provider logins and file permissions, like the provider
   CLIs. Syntila adds consent, digest pinning, limits and best-effort platform
   isolation. It does not claim containment.

## 3. Why this does not violate the exclusion

The exclusion in v8 §"Architecture contract" exists to keep three properties:

| Property the rule protects | How the plugin path keeps it |
| --- | --- |
| Syntila Core, Cloud, Workspace and AX stay provider-independent: no `if (provider == …)` in Syntila code. | No Syntila code names a plugin or provider. Plugin identity is data (`plugin-<slug>`), resolved through the same catalog/inventory/snapshot columns as any Worker. |
| Provider behaviour is not hard-coded into a bespoke Syntila-shipped binary per provider that bypasses the Profile's permission mapping and event normalisation. | Syntila ships no plugin and no provider adapter. The only Syntila-shipped executables stay the Service and the one generic Engine. The plugin host in the Engine is provider-neutral and has no plugin-specific code path. |
| One audited execution path with one supervisor, one cancellation story and one place that applies policy. | The Engine remains the single process host. Plugins add an executor kind, not a second runtime. |

What the rule does **not** cover, and this ADR does not claim it does: executables
authored by the user. The prohibition is therefore kept verbatim and a scoped
clarification is added when this ADR is accepted:

```yaml
prohibitions:
  provider_specific_worker_executable: true # Syntila-authored; see ADR-027 for user-imported plugins
```

The literal `provider_specific_worker_executable: true` line must remain in
`ARCHITECTURE_V8.md` because `scripts/verify-v8-architecture.mjs` checks it. On
acceptance (P1 exit) the only edits to normative text are: this clarification
beside that line, the second branch in the execution-path diagram, and one
sentence in AGENTS.md rule 5 ("user-imported plugins run only through the
Engine's plugin host per ADR-027"). Until acceptance those files are unchanged.

### Honest differences from Profile execution

A plugin has no Profile, so the guarantees a Profile provides do not carry over
automatically, and the design says so rather than papering over it:

- Profiles map `restricted` / `provider_default` to a CLI's sandbox flags. A
  plugin has no such mapping. The execution policy is *sent* to the plugin, which
  must honour it. Syntila enforces it only where the platform isolation tier
  actually does (§4 of the architecture document). Read-only Steps are scheduled
  to a plugin only when the Service reports enforced read-only for that plugin on
  that host.
- V9 Profiles are authenticated by Cloud authorisation and canonical digest, not
  signatures. Plugins are user-supplied, so the digest *pin* plus explicit user
  consent is the baseline trust anchor; signatures are optional and additive.

## 4. Alternatives considered

| Alternative | Verdict |
| --- | --- |
| Service spawns the plugin directly | Rejected. Duplicates process supervision, Job Object and cancellation logic in the service process, and puts untrusted-code lifecycle next to Cloud credentials. The Engine already exists to isolate this. |
| CLI spawns the plugin for `test` | Rejected. Violates "CLI must never execute a plugin". |
| Plugin as a Tool Profile pointing at the plugin binary | Rejected. Would make the Profile schema user-authored and public, requires a Profile editor, and Profiles allow no arbitrary executables by design. |
| In-process plugins (Dart isolates, WASM) | Not "any language"; deferred, not excluded. The protocol is transport-neutral enough for a later WASI host. |
| Cloud-hosted plugin execution | Rejected. Secrets and provider logins are local; Cloud must not run user code or see secrets. |

## 5. Consequences

- Engine gains a plugin host and Local Worker Protocol 4.2 (additive). Engine
  version bump to 1.4.0 is expected in P2.
- Cloud gains a plugin library, per-Workspace enablement, catalog `origin` and
  inventory executor columns, one paid feature, and a scheduler admission branch.
  Existing official-Worker rows, Profile joins and the Profile registry remain
  valid because plugin rows are excluded by an explicit `origin` filter. The
  full list of changed and preserved contracts is in the architecture document.
- Cloud never stores or sees credentials or secrets; export excludes them.
- A new class of local risk exists: arbitrary code under the user's account.
  Consent, pinning, limits and honest isolation reporting are the mitigations;
  they are not a containment guarantee.
- Downgrade pauses plugins and never deletes them; exports stay available.
- Running work behaviour on downgrade follows ADR-022 ("Work already admitted
  finishes") with a hard cap; see the architecture document.
- Items that need device evidence before being claimed: per-platform isolation
  tiers, Job Object memory limits, Windows restricted-token behaviour, macOS
  `sandbox-exec` availability, and Linux user-namespace availability in
  containers.

## 6. Out of scope

Plugin marketplace or public registry; Cloud-hosted execution; plugin access to
Cloud APIs; managed credentials of any kind; a Workspace GUI; a Profile editor;
changes to the per-installation lock, `service stop` or Disconnect Cloud.
