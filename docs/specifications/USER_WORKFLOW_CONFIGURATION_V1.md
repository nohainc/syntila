# User Workflow Configuration v1

A Workflow definition is Syntila-owned; a configuration records a person's sparse
preferences for that definition. The latest definition validates Workflow and
step IDs. Definitions, prompts and signed Profiles are not copied into preferences.

```json
{
  "schemaVersion": 1,
  "workflowId": "research",
  "enabled": true,
  "defaults": { "worker": "worker-id", "model": "model-id", "effort": "high" },
  "stepOverrides": { "synthesis": { "worker": "review-worker-id" } }
}
```

Omitted model and effort values mean Auto. A step can inherit its Workflow's
selection or override it. Cloud validates the configuration against the definition
and checks that named Workers belong to the settings owner and have not been
revoked. Chat cannot be disabled. An unavailable saved Worker is omitted from the
returned selection and reported as a `worker_unavailable` issue; it is never
silently replaced by another Worker.

## Authenticated human API

- `GET /api/user/workflow-configurations` and
  `GET /api/user/workflow-configurations/:workflowId` read personal settings.
- `PUT` and `DELETE` on the individual Workflow route save or reset its settings.
- `GET /api/user/workflow-default` and `PUT /api/user/workflow-default` read or
  change the default Workflow.
- Equivalent `/api/spaces/:spaceId/workflow-configurations` and
  `/api/spaces/:spaceId/workflow-default` routes provide Space settings.

Requests are authenticated as the person; a user ID in a payload is not an
authority. Cloud validates every write. Direct Spaces use personal settings;
Space-level changes require the Space owner's authorization. A disabled Workflow
cannot be selected as the default. An unset default resolves to Chat.

## Worker selection

Selections name Worker IDs, not provider credentials or local paths. A Space's
configuration starts with its owner's personal settings and may replace an
individual Workflow with a Space override. The Space default similarly falls
back to the owner's default. A Space override replaces the entire configuration
for that Workflow. Removing it restores inheritance.

Configuration expresses intent; it does not promise execution. Work admission
and dispatch separately check the requester's authorization, Worker access,
Profile compatibility, readiness, and capacity. Model and effort choices are
validated against the selected Worker's available options. An accepted request
retains its execution snapshot when preferences subsequently change.

## Storage and ownership

Personal configurations are stored by user and Workflow in
`user_worker_workflow_configurations`; Space overrides are stored by Space and
Workflow in `space_workflow_configurations`. Defaults are stored separately in
`user_workflow_defaults` and `space_workflow_defaults`. The backend owns
persistence and validates state transitions. Connect supervises the selected
Worker and its generic CLI Worker Engine; provider credentials stay local.
