# ADR-015: First-Party Worker v1 Contract

**Status:** Accepted; current first-party logical Worker identity and catalog contract.
**Runtime implementation:** ADR-018.

## Context

Threads need stable user-facing Worker identities that survive provider CLI updates and Profile release changes. Product identity must remain independent of local runtime implementation.

## Decision

### Catalog and cardinality

Syntila v1 initially provisions these official Workers:

| Worker Type ID | Name | Official Profile | Provider CLI | Slots per Workspace |
| --- | --- | --- | --- | --- |
| `chatgpt` | ChatGPT | `chatgpt-codex` | Codex CLI (`codex`) | one |
| `gemini` | Gemini | `gemini-antigravity` | Antigravity CLI (`agy`) | one |

The official Worker Catalog is Cloud-managed and dynamically delivered.
Additional approved Worker Types can become available without a Workspace
application release when they can be expressed through an existing Engine
family and supported Tool Profile schema. These IDs are the initial product
identities used by AX, Cloud, Threads, scheduling, and history. Profile
IDs, Engine versions, and provider executable names are implementation details.

### Authentication and billing

Provider authentication and any provider subscription/API mode remain local to the provider CLI. Syntila does not collect provider credentials or choose a billing mode for the user.

### Readiness and activation

Workspace owns local Worker activation and readiness. Engine plus the admitted Profile perform provider discovery and readiness checks. Activation and readiness are independent: disabling a Worker does not erase its health result, and a disabled Worker may be tested explicitly.

Cloud receives only the safe Worker inventory projection. It owns scheduling state and Space/Thread authorization but cannot modify local activation, permissions, provider credentials, or local concurrency limits.

### Assignment behavior

Thread configuration binds logical Worker IDs to the fixed Work v1 Work (`direct`)/Step slots. A binding does not contain a provider executable path, Profile payload, secret, or runtime version. Workspace resolves the selected logical Worker to an admitted Profile and runs it through the generic Engine.

## Consequences

A Profile or provider CLI update does not change Thread Worker IDs. Normal users select ChatGPT or Gemini and see their readiness; the Engine, Profile release, and provider CLI details remain diagnostic information.

## References

- [First-Party Worker Catalog v1](../specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Tool Profile v1](../specifications/TOOL_PROFILE_V1.md)
- [Work v1 Contract](../specifications/WORK_V1_CONTRACT.md)
- Workspace UX and data contract
