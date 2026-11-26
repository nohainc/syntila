# Connect and Worker readiness

Each Worker has its own credential, session, journal and readiness. Connect reports the Worker's readiness with its hello; unknown readiness is not reported as ready. Cloud checks the Worker's current session, availability, authorization, capabilities and model options at admission and dispatch. See [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md) and [ADR-035](../decisions/ADR-035-worker-targeted-execution.md).

An offline Worker is rejected rather than silently replaced or queued for later. Reconnection authenticates a fresh session, reconciles the local journal and resumes delivery under the current session fence. A stale session cannot commit a result. Worker readiness and provider availability are distinct from the Worker's identity.
