# Northstar Studio demo

This is a fictional product-launch demonstration of Syntila. Northstar Studio
is preparing Fieldnotes, an imaginary app for collecting and organizing ideas.
The [scene script](scenes.md) is reusable; it is not evidence that an execution,
rehearsal, or capture exists.

Do not use or alter the existing personal account, its data, or its Workspace
configuration. Use ordinary demo accounts and product workflows. The initial
plan called for isolated rehearsal before production; the user subsequently
authorized creation of three production demo accounts and direct activation.

## Cast and prerequisites

- Maya Chen: demo owner and product lead; optional original illustrated portrait
  on teal.
- Leo Hart: collaborator and designer; optional original illustrated portrait on
  warm amber.
- Amara Vale: collaborator and marketing lead; optional original illustrated
  portrait on lavender.

Names and portraits are fictional display identities. The user must control
any addresses used for invitations; do not assume demo mailboxes exist. Use default avatars when suitable original artwork is unavailable.
Never put addresses, credentials, tokens, or sensitive local paths in this guide
or captured images.

Local rehearsal needs an isolated backend and separate demo Workspace. Worker
execution additionally requires a verified current Profile, an available model,
provider CLI authentication, and readiness. ChatGPT and Gemini are documented
first-party Workers, not guaranteed available choices. Choose from the live
catalog; never claim an execution succeeded without observing it. Provider
sign-in and demo Workspace preparation are separate actions; do not modify the
personal Workspace.

## Capture and refresh guide

Use the individual [scene recipes](scenes.md#refresh-and-capture-recipes) for
all six shots. Existing scene history is the starting point: navigate back to
the relevant Space and Thread, scroll to the desired message or result, and
reuse it if still suitable. Never delete, reset, or rewrite prior messages to
stage a screenshot. If content is missing or stale, use the approved demo
accounts and product flows to add the applicable scripted message or request;
review the new result and preserve the old history. Production actions must
remain within the user's existing authorization. If the required state or
execution is unavailable, record the blocker and defer that shot.

### Before each capture session

1. Choose the intended destination and scene, then check the current
   [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
   or [Google Play preview asset requirements](https://support.google.com/googleplay/android-developer/answer/9866151)
   for the actual listing, device category, locale, formats and dimensions.
   Requirements can change; this guide is not a substitute for checking them at
   capture and submission. Check other supported device categories as applicable.
2. Verify the chosen device or simulator and the actual native build can launch,
   connect to the intended environment, sign in to a demo account and show the
   relevant content. `xcrun simctl list devices available` lists installed iOS
   simulators; `adb devices -l` lists connected Android devices/emulators when
   Android platform tools are installed. Availability in a list does not prove
   that a build, runtime, connection or sign-in works. Use the build instructions
   in the [app README](../../apps/app/README.md); do not install or modify the
   personal Workspace. If a target cannot run, defer its captures.
3. For every image record in a non-secret capture log: date, scene number,
   destination, environment, build/version, device or simulator and OS, actual
   viewport and pixel dimensions, scale, theme, orientation, and reviewer. For
   web also record browser/version and viewport; choose a consistent desktop
   landscape viewport and theme for the set. For native store captures use the
   intended portrait device size and a consistent theme; measure the actual
   output pixels rather than assuming logical viewport points equal image pixels.
4. Hide unrelated notifications and close menus or dialogs not part of the
   scene. Use only demo sessions and inspect visible names, account identifiers,
   URLs, files, status bars and notification previews before capture.

### Platform recipes

| Destination | Capture and final size |
| --- | --- |
| Desktop website | Open the demo in a desktop browser; set and record the chosen landscape viewport, zoom and theme. Navigate to the scene and capture the application viewport without unrelated browser tabs or personal content. Record final pixel width and height and ensure text remains legible at the website's intended display size. Website dimensions are a project choice, not store requirements. |
| iPhone | Launch the actual iOS app build on the selected device or simulator in portrait. Restore the scene and use the device screenshot controls or Simulator's screenshot action. Inspect the resulting pixel dimensions against the current App Store Connect category before upload; capture a separate navigation view where the narrow layout cannot show navigation and conversation together. |
| Android | Launch the actual Android build on a device or emulator in portrait. Restore the scene and use device controls or Android Studio's screenshot action. Measure the saved image and check the current Play Console requirements; capture navigation separately when needed. |

As checked on 2026-11-11, Apple specifies JPEG or PNG without transparency and
at least one screenshot for the required iPhone category; its table lists
1179 × 2556 and 1206 × 2622 portrait among the medium Dynamic Island sizes.
Apple's requirements and scaling depend on the supported device categories.
Google specifies at least two screenshots for a listing, JPEG or 24-bit PNG
without alpha, dimensions from 320 to 3840 pixels, and a longest side at most
twice the shortest; additional recommendation and device-specific rules apply.
Consult the official pages above and the relevant consoles again at capture.

### Review and release

Inspect every image at full resolution and at intended display size. Verify the
correct scene, app/build, layout, attribution, legibility and consistent
fictional story; check AI content for inaccurate or unsupported claims. Check
for unrelated people, account identifiers, email addresses, passwords, tokens,
notifications, sensitive paths, browser chrome and personal data. Re-capture
if the image misrepresents a pending or failed run as complete. Check exact
pixel dimensions, format and alpha channel after any crop or conversion; do not
stretch the UI or conceal a failure. Store and share only reviewed images in
the approved destination. Record a pass or blocker for each shot and reviewer.

On 2026-11-11, `simctl` listed iOS simulators including iPhone 17 Pro and Pro
Max, all shut down; `adb` was not on the command path. No device was booted,
no native build or sign-in was verified, and no screenshot was captured. Repeat
all checks at capture time; this observation does not establish availability.

## Production action proposal — approval required

The user subsequently authorized direct creation and activation of the three
demo accounts in production. That action has been completed; the addresses
were marked verified in the database without mailbox verification. All three
password sign-ins succeeded; mail delivery was not verified. This document does not itself authorize further
actions. Review remaining actions, targets and costs with the user and respect
authorizations already given in the Thread. The user authorized sending and
accepting the invitations for these fictional accounts.

- [x] Create and activate three production demo accounts for Maya, Leo, and
  Amara, as explicitly requested. Email verification was set administratively;
  mailbox ownership remains unverified; all three password sign-ins succeeded.
- [x] Use default avatars. No existing personal profile was changed.
- [x] As Maya, create the Group Spaces **Northstar Studio** and **Fieldnotes
  Design**. Invite Leo and Amara to each with the approved permissions; accept
  each invitation as its intended recipient. No other recipients are invited.
- [x] Create **Launch plan**, **App Store copy**, **Website messaging**, and
  **Launch checklist** Threads in Northstar Studio, and **Visual direction** in
  Fieldnotes Design. Add the scripted fictional overview and human messages
  through the product as the respective demo participants.
- [ ] Prepare and connect a separate approved demo Workspace, verified current Worker
  Profiles, and provider CLI authentication; select available approved Workers
  and models. Do not change the existing personal Workspace or its credentials.
- [ ] Submit the two scripted Chat workflow prompts and the scripted Work
  execution prompt in their respective Threads. Review actual outputs and use
  only suitable completed results; no success is guaranteed.
- [ ] Capture and review the six scenes on approved devices, then store or share
  only the approved images at the approved destination. Exclude sensitive data.
- [ ] Decide and approve retention or cleanup of the demo accounts, Spaces,
  Workspace, provider sessions, and captures separately; do not delete or
  revoke anything merely because the demo is complete.

Approval of this proposal is not approval to perform production actions. Record
who approved which concrete targets and actions before proceeding; never record
credentials in the approval record.

## Phase 2 rehearsal record

The launcher defaults to isolated local D1, but it reuses local state and a
persistent browser profile; it does not create a clean demo environment. Do not
use `--proxy`, which reaches production. A safe rehearsal requires a separately
prepared local database, browser sessions for all three participants, and demo
Workspace, with no personal state or credentials. The launcher alone does not
provide those separate resources. Do not reset or migrate an existing local
database to make room for the demo.

On 2026-11-11, four focused Cloud fixture test files passed (34 tests):
`thread-read-model.acceptance`, `work-v1-v8-regression.acceptance`,
`space-invitation-identity-migration`, and `workflow-prompts`. They exercise
selected read models, invitation identity migration, workflow dispatch and
prompt contracts in test fixtures. They are not a live local-backend rehearsal,
UI capture, provider run, or evidence that all three demo accounts can interact.
No production interaction was performed during that fixture check. Production
demo accounts were created separately after the user changed direction. See the scene-by-scene record in
[scenes.md](scenes.md).

## Separate demo Workspace and Worker setup

This section is guidance, not a record that setup or sign-in occurred. Use a
separate demo machine, or an installation demonstrably isolated at the OS-user,
service registration, application state, secret store, provider CLI home,
sessions, and Work Root boundaries. A different folder or a second process alone
is not sufficient. If these boundaries cannot be established, stop and use a
separate machine. Do not run setup, login, register, reset, logout, disconnect,
or configuration changes on the existing personal installation. A local build's
separate application state alone does not isolate provider credentials or Work
Root; a local backend also cannot serve a production demo Workspace.

1. Before setup, the user records non-secret baseline evidence of the personal
   installation: machine/OS user, Workspace name and status, configured Work
   Root, registered service identity, and enabled Workers. Avoid credentials,
   token values and sensitive paths in shared notes. Do not stop or modify it.
   Identify the demo machine, OS user, separate Work Root, target Cloud, and
   intended demo owner; confirm they are distinct. If uncertain, stop.
2. On the isolated demo installation, the user signs in as the demo owner using
   `syntila login`, then registers with `syntila register`, or uses `syntila
   setup` for the guided lifecycle. Start the service and connect using the
   Workspace CLI guidance; set and verify a separate Work Root on the demo
   installation. Inspect `syntila status` and `syntila work-dir`. Check plan and
   account limits before registration; do not unregister another Workspace to
   make room. The user controls the sign-in and any credentials.
3. As the demo Space owner in Syntila, select the demo owner's Workspace in the
   Space **Workflows** tab and configure the needed workflows and Workers. The
   selection creates or repairs the internal execution grant; this is not a
   separate member permission or personal Workspace sharing grant. Confirm the
   actual controls and effective authorization during approved setup; this flow
   has not been rehearsed here. See [Workspace Space Grants](../specifications/WORKSPACE_SPACE_GRANTS.md).
4. Install each provider CLI separately on the demo machine under the isolated
   OS user, following the provider's current instructions. The user signs in
   separately to Codex CLI for ChatGPT and Antigravity CLI for Gemini, if used,
   with accounts they control. Never copy personal CLI credentials, tokens,
   sessions, or subscription details into the demo or these documents. Review
   provider access, applicable charges and usage limits before a live test.
5. On the demo installation inspect `syntila workers catalog`, add an available
   Worker with `syntila workers add TYPE`, and use `syntila workers` and the
   relevant `workers check` / `workers test` help and status. The service must
   be connected; the Worker must be enabled, its current published Profile
   fetched, verified and activated, the provider CLI detected and authenticated,
   and readiness reported. Resolve failures through normal diagnostics, never by
   bypassing Profile validation. A live test may use provider resources.
6. At setup time record only non-secret evidence: date, target environment,
   demo Workspace identity, Space selection/grant outcome, each available Worker
   and model name, readiness, and any blocker. Prefer ChatGPT and Gemini if both
   are available and suitable. Otherwise use two supported models if available;
   defer scene 4 if there is no second suitable choice. Model availability is
   dynamic, and catalog presence alone does not prove execution readiness.
   Chat requires a Profile admitted for read-only Chat: the current Antigravity
   starter is not verified for that capability. Do not assume Gemini can run
   Chat; see [Chat acceptance](../acceptance/CHAT_WORKFLOW.md).
7. In the demo Thread select the eligible Worker/model and workflow. Scenes 3
   and 4 use read-only Chat; scene 5 uses Work. A successful scene 5 produces a
   concise checklist grouped by owner with store copy, visual review,
   accessibility, release readiness and a definition of done. Review actual
   output for fictional consistency, unsupported claims, omissions, and sensitive
   information before capture. Do not imply a failure or queued run completed.
   If execution is unavailable, retain the scripted prompt as a storyboard,
   document the non-secret blocker, and defer the execution screenshot.
8. Compare the personal installation's non-secret baseline with a read-only
   status review after demo setup, where safe and available. Confirm identity,
   Work Root, service state and Worker configuration match; if they cannot be
   verified, record that limitation rather than claiming preservation. Never
   reset or change the personal installation to perform this comparison.

Actual grant selection, Worker/model inventory, provider sign-in and execution
have not been observed in this phase. Record their outcomes at approved setup;
no credentials or account details belong in the evidence.

## Phase 5 production setup status and outstanding decisions

The three fictional accounts were created and activated at the user's explicit
request. Their verification flags were set directly, not by mailbox verification;
all three password sign-ins succeeded, but mailbox delivery has not been verified. They are Maya Chen
(`maya.chen@nohainc.com`), Leo Hart (`leo.hart@nohainc.com`), and Amara Vale
(`amara.vale@nohainc.com`). Their credentials are not recorded here. The prior
local rehearsal did not exercise the complete UI, and no production scene or
capture is evidenced by that rehearsal.

The remaining concrete proposal uses default avatars, avoiding avatar uploads:
Maya owns **Northstar Studio** and **Fieldnotes Design**; Leo and Amara join
both as collaborators with Chat and Work permissions, subject to the owner's
actual authorization controls. Maya creates **Launch plan**, **App Store copy**,
**Website messaging**, **Launch checklist**, and **Visual direction** in the
Spaces indicated in [the script](scenes.md). Each participant posts only their
scripted messages; the owner submits the three exact prompts in that script.
Maya selects an independently isolated demo Workspace for the Space Workflows;
the user signs in to any provider CLIs. Use the available eligible Worker and
model for Chat, a second available Worker or model for the second Chat scene,
and a ready Worker for the Work checklist. Capture and review the six scenes as
described in the capture guide, deferring unavailable execution scenes.

On 2026-11-11 the user explicitly authorized invitations and actions with the
demo accounts. Through product APIs, Maya created both Spaces and all five
Threads. Leo and Amara were invited and accepted membership in both Spaces;
all three accounts signed in. The scripted overview, three discussion messages,
and visual direction message were posted by the intended participants. The
invitation endpoints succeeded; delivery to a mailbox was not verified. Default
avatars were retained. No personal account or Workspace was used for these
operations.

Still pending: an independently isolated demo machine or installation and Work
Root, demo-owner Workspace registration and authorization, user-controlled
provider sign-ins, actual Worker/model readiness, the three AI requests, and
reviewed captures. No provider sign-in, Workspace setup, AI execution or capture
was performed in this phase. Account and provider plan eligibility and costs
remain to be checked. Continue to keep the existing personal account, its data,
Workspace and provider sessions unchanged.
