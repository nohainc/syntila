# MCP threat model (draft)

Assets: user files in the Thread directory, provider logins, MCP credentials and
OAuth tokens, model context integrity, Cloud data.

| # | Threat | Mitigation |
| --- | --- | --- |
| T1 | Tool poisoning: malicious description steers the model | Consent shows full definitions; hash pinning; drift blocks calls; descriptions length-capped |
| T2 | Rug pull: server changes tools after consent | `definition_changed` state, re-consent diff (MCP host §4) |
| T3 | Result-borne prompt injection | Results rendered as labelled untrusted data; size caps; never promoted to instructions |
| T4 | Exfiltration through tool arguments | Tools exposed per Step only; write/network tools need per-tool consent; no ambient exposure |
| T5 | Confused deputy / token theft (remote OAuth) | Tokens only in Service local store; per-server audience; never sent to Cloud or other servers |
| T6 | Malicious local server runs arbitrary code | Same model as ADR-027: digest pin, consent, limits, honest "no sandbox" |
| T7 | Remote server receives local data | No local paths to remote servers; explicit attachments only; Work-only, `restricted` default |
| T8 | Secret leakage in logs | Redactor on args/results/stderr; nothing stored by default |
| T9 | Resource exhaustion (huge frames, tool floods) | Frame/result/tool-count limits; concurrency caps; process limits |
| T10 | Spec/version confusion | Explicit supported-version list; refuse unknown |
| T11 | Duplicate side effects from retries | No auto-retry for write-capable tools |

Required tests (added in M1/M3/M5): drift blocks call; oversize rejected; no
sampling/roots honoured; token absent from Cloud payloads; untrusted label
present in rendered context; undeclared Step tools unreachable.
