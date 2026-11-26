# Thread execution operations

A person sends a message or explicitly asks a Worker to run. Plain messages do not start AI work. For an AI request, the composer selects a Worker and may specify a model and reasoning effort. Cloud validates the requester's Thread rights, Worker access, readiness and model options at admission and again at dispatch. An offline or unauthorized Worker is not silently replaced. See [ADR-035](../decisions/ADR-035-worker-targeted-execution.md).

## Request files and stateful work

Attachments upload to R2 before Steps start. Each Worker on the request downloads and verifies its authorized inputs. Failures are shown on the request; provider credentials and local paths do not go to Cloud. See [Input Delivery](../specifications/INPUT_DELIVERY_V1.md).

Stateful work requires a Thread lease. Cloud issues a fencing token and Connect refuses stale tokens; Connect also applies the local folder permissions. A lease can remain held until expiry or release after disconnect. Switching Workers does not move local files; use an authorized artifact or repository handoff. See [ADR-040](../decisions/ADR-040-stateful-workflows-on-worker-agents.md) and [ADR-037](../decisions/ADR-037-files-and-artifacts.md).

## Diagnosing and recovery

Check the request and Worker status, the owner's sharing and model settings, Connect service status and its local readiness diagnostics. Ensure the provider CLI is installed and signed in on the Worker's computer. Avoid sharing credentials or local paths in reports. Accepted request snapshots record the selected Worker and configuration; changing a preference does not rewrite them.

Connect journals assignments before acknowledging them. After a restart it reconciles with Cloud; an attempt that may already have started is not launched a second time. Cloud handles any retry as a new attempt. See [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md). Real-provider and device tests are still needed for installed-release acceptance.

## Worker usage

The owner can request provider usage for a Worker from the Workers page. Connect runs the signed Profile's usage command through the Engine, and Cloud relays the result to the owner. The report is not persisted. See [ADR-035](../decisions/ADR-035-worker-targeted-execution.md#provider-usage).
