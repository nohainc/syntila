# Input Delivery v1

Request files and handoffs use R2 so Workers running on different computers do not need a shared filesystem. [ADR-037](../decisions/ADR-037-files-and-artifacts.md) defines the authorization and transfer boundary; [ADR-044](../decisions/ADR-044-device-folders-and-space-folders.md) keeps local paths on the device.

## Request files

A person's attachments are uploaded before any Step starts. Cloud stores Work Request input metadata and R2 object references; the Worker uses its own fenced session to download inputs for a request on which it has a Step. A Worker without a Step on the request cannot download them. Connect verifies size and SHA-256, keeps a private copy and places files under `.syntila/inputs/<work-request-id>/file-NNN` in the working directory. Retries can reuse a verified local copy. File bodies do not travel in the realtime envelope.

If placement fails before the provider starts, Connect sends a safe, path-free failure description, including an HTTP status when available. The description follows the encrypted storage and authorized-read rules in [ADR-036](../decisions/ADR-036-canonical-thread-timeline-and-attribution.md).

## Handoffs and outputs

Steps hand off artifacts through R2 using artifact IDs and scoped download grants. A local path is not a handoff between computers. Worker-created output media is uploaded with the result and presented to authorized Thread participants using short-lived links where applicable. Storage limits, checksums and retention apply.

## Security and acceptance

Cloud authorizes every transfer and never receives a local directory path. The connected computer's owner controls local folder access. Tests cover the Cloud routes and Connect input staging; they do not by themselves establish real-provider or multi-device acceptance. See [ADR-037](../decisions/ADR-037-files-and-artifacts.md) for the current transfer contract.
