# First-Party Worker Testing

Provider integrations are tested through the generic CLI Worker Engine and
the current Worker Profiles defined by the V9 contract.

## Deterministic acceptance

The generic Engine tests use fixture CLIs and provider event fixtures. Run the
relevant suites with:

~~~sh
cd engines/cli_worker && dart test
cd packages/tool-profile && pnpm test
cd apps/connect && dart test
~~~

These tests do not require provider accounts or use provider allowance.

## Real provider acceptance

The opt-in Profile acceptance suite
uses the installed Codex and Antigravity CLIs. It writes digest-bound evidence
for passive/live probes, a Thread write, durable session start/resume,
timeout, and process-tree cancellation. Set only the corresponding opt-in
variable and an evidence directory when an operator is ready to run it:

~~~sh
SYNTILA_TEST_REAL_PROFILE_CHATGPT=1 \
SYNTILA_PROFILE_ACCEPTANCE_EVIDENCE_DIR=/path/to/evidence \
  dart test test/tool_profile_real_acceptance_test.dart

SYNTILA_TEST_REAL_PROFILE_GEMINI=1 \
SYNTILA_PROFILE_ACCEPTANCE_EVIDENCE_DIR=/path/to/evidence \
  dart test test/tool_profile_real_acceptance_test.dart
~~~

From `apps/connect`, the live assignment suite covers Chat and Work (`direct`) for the official logical Workers. It uses provider
allowance and does not replace the evidence-producing release acceptance
suite.

Chat adds a distinct read-only qualification requirement. Normal and compatibility
Profile layouts must preserve policy on both new and resumed conversations.
Fixture coverage is recorded in Chat/Work regression coverage;
it does not replace live-provider sandbox qualification. Historical evidence
continues to use the Workflow names and versions that were tested.

~~~sh
SYNTILA_TEST_ASSIGNMENT_PROFILE_CHATGPT=1 \
SYNTILA_TEST_ASSIGNMENT_PROFILE_GEMINI=1 \
  dart test test/tool_profile_assignment_acceptance_test.dart
~~~

Use Dart's standalone test runner for these Connect acceptance files. It
avoids Flutter test-runner service output being inherited by the Engine child
process, whose stdout is reserved for the local worker protocol.

Live-provider acceptance remains a release gate. The generic Engine fixture
suite provides deterministic coverage without provider accounts or allowance.
