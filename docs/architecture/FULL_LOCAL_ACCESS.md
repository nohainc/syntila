# Full Local Access

Every configured CLI Worker always runs with the `full_access` execution
policy. There is no per-Worker toggle in the Workspace CLI and no Manager IPC
mutation for it.

The local Worker registry always reports `fullLocalAccessAuthorized: true`
(the stored value is ignored on load) and normalizes every Worker's local
permissions to include `repository:read`, `repository:write`,
`shell:execute`, and `network:use`. Cloud assignment payloads and Work
messages still cannot widen anything beyond this local ceiling.

For a non-read-only assignment with no explicit narrower policy, an authorized
Worker emits `full_access` through the Local Worker Protocol, including a
stateless request that still permits repository or shell operations. Explicit
read-only, `restricted`, and `provider_default` selections remain narrower. The
generic CLI Worker Engine passes the policy to the signed Tool Profile, which
owns the provider-specific command mapping. The checked Codex profile maps this
mode to
`--dangerously-bypass-approvals-and-sandbox`; Gemini profiles omit `--sandbox`
and pass `--dangerously-skip-permissions`. Active signed releases must be
verified against the installed provider versions before production rollout.
Codex rejects `--ask-for-approval` when it is combined with the unrestricted
flag, so that approval option belongs only to the restricted and
provider-default mappings.
The forward migration `0041_full_local_access_profile_mappings.sql` repairs
the Gemini authoring starter for databases that already ran the earlier
migrations. It does not rewrite an already published signed release: after
the migration, publish and promote a new Gemini release, then refresh the
Workspace profile catalog. A local app rebuild alone cannot change the active
signed profile.
The Codex flag conflict is repaired by
`0042_codex_full_access_approval_conflict.sql`; publish and promote the
updated ChatGPT release so existing Workers get the corrected mapping.

The Engine does not inherit the entire parent environment. It preserves the
profile allowlist and, in full-access mode, adds only the host variables needed
for normal Git, SSH-agent, credential-helper, proxy and XDG configuration. Secrets remain subject
to profile allowlists and diagnostic redaction.

Working directories continue to come from the Workspace Space/Thread
lifecycle. Full local access does not grant root privileges, bypass macOS
privacy controls, or make Cloud inventory authoritative for local permission
state. Revocation takes effect for subsequent assignments; an already-running
provider process is still governed by the existing cancellation and lifecycle
controls.

Workspace does not clone repositories automatically. A provider request that
needs a checkout runs normal host `git` in the resolved Space directory, so the
checkout is visible to later requests. Space identity markers and the private
directory registry preserve that location across display-name changes, service
restarts, and Workspace re-enrollment; Cloud never supplies an arbitrary CWD.

## Host acceptance

Phase 7 has an opt-in host acceptance test at
`apps/workspace/test/full_local_access_host_acceptance_test.dart`. It checks
DNS and HTTPS connectivity, `git ls-remote`, a real clone, repository read and
write, a local commit, installed provider versions, and reuse of the same
working directory by a restarted child process. It creates its checkout under a
temporary directory and never pushes to the remote repository.

Run it only on the designated Workspace machine:

```text
SYNTILA_TEST_FULL_LOCAL_ACCESS=1 \
SYNTILA_TEST_FULL_LOCAL_ACCESS_EVIDENCE_DIR=/tmp/syntila-phase7-evidence \
dart test test/full_local_access_host_acceptance_test.dart
```

The repository and general HTTPS targets can be overridden with
`SYNTILA_TEST_HOST_REPOSITORY` and `SYNTILA_TEST_HOST_URL`. The provider
commands checked by default are `agy,codex`; override them with
`SYNTILA_TEST_HOST_PROVIDER_COMMANDS` when a machine has a different approved
provider installation. Environment values and credentials are not written to
the evidence file.

If this test reports `Could not resolve host`, the failure is at the Workspace
machine's DNS/network boundary. The profile mapping can grant the provider
permission to invoke `git`, but it cannot repair an unavailable resolver or
firewall. The test should be run on the actual designated Workspace machine;
the development sandbox's network result is not evidence about that host.

The generic provider path remains covered by the opt-in real Profile acceptance
test (`tool_profile_real_acceptance_test.dart`), while
`scripts/internal/check-workspace-service.sh` verifies that the headless Workspace
Service can start headlessly. Closing the terminal and
reconnecting after a macOS restart require a device-level service test because
they depend on launchd, signing, and the host's login/session state.

To exercise the same host operations through the real provider CLI and the
generic Engine, add `SYNTILA_TEST_REAL_PROFILE_FULL_LOCAL_ACCESS=1` and enable
one provider profile, for example:

```text
SYNTILA_TEST_REAL_PROFILE_CHATGPT=1 \
SYNTILA_TEST_REAL_PROFILE_FULL_LOCAL_ACCESS=1 \
SYNTILA_PROFILE_ACCEPTANCE_EVIDENCE_DIR=/tmp/syntila-profile-evidence \
dart test test/tool_profile_real_acceptance_test.dart
```

Use `SYNTILA_TEST_REAL_PROFILE_GEMINI=1` instead for the Gemini profile. Live
assignment workflows in `test/tool_profile_assignment_acceptance_test.dart` use
separate `SYNTILA_TEST_ASSIGNMENT_PROFILE_CHATGPT=1` and
`SYNTILA_TEST_ASSIGNMENT_PROFILE_GEMINI=1` flags so release-evidence runs do
not trigger multi-step assignment suites implicitly. These real-provider checks
are intentionally opt-in and should run only on an explicitly designated
development machine.
