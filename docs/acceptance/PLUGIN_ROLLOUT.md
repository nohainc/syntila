# Custom Worker plugin rollout evidence

Recorded 2026-11-04. This is a rollout record, not end-to-end acceptance.

## Verified

- User reported applying migration `0101_worker_plugins.sql` remotely.
- [Main CI](https://github.com/nohainc/syntila/actions/runs/41833959014)
  passed for the plugin implementation at `061eed3d`.
- [Production Cloud deployment](https://github.com/nohainc/syntila/actions/runs/41840343536)
  succeeded from that commit. Production `/health` returned
  `{"ok":true,"environment":"production"}`.
- An unauthenticated POST to the production plugin entitlement endpoint returned
  HTTP 401. This proves authentication refusal, not successful lease issuance.
- Production Worker secret metadata lists `SYNTILA_ENTITLEMENT_KEY_ID` and
  `SYNTILA_ENTITLEMENT_SIGNING_KEY`. The matching public trust key is configured
  as GitHub variable `SYNTILA_ENTITLEMENT_TRUST_KEYS_JSON`. No private key is
  recorded here. Release workflow wiring is in `ed6ff4fc`, whose CI passed.
- The standalone macOS arm64 headless Workspace candidate built locally from
  `ed6ff4fc`, using the configured public release and entitlement trust variables.
  The compiled CLI's `--help` command succeeded. No installed service was replaced.

Local candidate checksums (not signed release identities):

```text
4f28b7717c92c8b4bc0d342436fae4ff2a106461dff2fbf3148cba4e81303cdd  dist/syntila/syntila
a7c4d36afef892d36ac7d6eb7c61de498f6728bc1d779432abd136c7c0a63f93  dist/syntila/assets/engines/syntila-agent
```

## Candidate builds requested

These runs use `publish=false`; inspect their final results and retained artifacts
before use. Starting a run is not evidence that the package passed acceptance.

- [macOS signed/notarized candidate](https://github.com/nohainc/syntila/actions/runs/41843300328)
- [Linux x64/arm64 candidates](https://github.com/nohainc/syntila/actions/runs/41843306548)
- [Windows signed installer candidate](https://github.com/nohainc/syntila/actions/runs/41843311781)

GitHub release signing credentials were absent when these runs were requested.
The local standalone candidate is unsigned. Public release publication has not
been requested. Do not replace existing immutable versioned release artifacts.

## Remaining acceptance

Use a dedicated test installation and an entitled owner. Do not copy production
credentials into scripts or evidence. With the candidate CLI and Service:

1. Connect through the normal authenticated setup flow; confirm the existing
   installation identity and Work Root are preserved when upgrading.
2. Import the harmless SDK echo plugin; run static validation and Engine-hosted
   conformance, then register and enable with each displayed consent hash.
3. Verify Cloud lease issuance and local signature acceptance, readiness and a
   complete Work assignment. Record safe IDs and outcomes, never lease tokens.
4. Check digest tampering refusal, disabled-worker scheduling refusal, service
   stop cleanup, restart recovery and credential-free export.
5. Verify lapsed entitlement blocks new starts and running work drains within
   the documented cap. Keep read-only Steps ineligible.

This record does not establish filesystem/network isolation, signed installation,
provider authentication, user-service lifecycle or successful paid execution.
See the [operations runbook](../operations/CUSTOM_WORKER_PLUGINS_OPERATIONS.md)
and [resource evidence](PLUGIN_RESOURCE_LIMITS.md).
