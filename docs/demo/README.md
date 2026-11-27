# Northstar Studio demo

This is a fictional product-launch demonstration of Syntila. Northstar Studio
is preparing Fieldnotes, an imaginary app for collecting and organizing ideas.
The [scene script](scenes.md) is reusable; it is not evidence that an execution,
rehearsal, or capture exists.

Do not use or alter the existing personal account, its data, or its Connect
configuration. Use ordinary demo accounts and product workflows. 
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

Local rehearsal needs an isolated backend and separate demo Connect. Worker
execution additionally requires a verified current Profile, an available model,
provider CLI authentication, and readiness. ChatGPT and Gemini are documented
first-party Workers, not guaranteed available choices. Choose from the live
catalog; never claim an execution succeeded without observing it. Provider
sign-in and demo Connect preparation are separate actions; do not modify the
personal Connect.

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
   personal Connect. If a target cannot run, defer its captures.
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

Store screenshot requirements (formats, alpha, dimensions, minimum counts) change; check
the official App Store Connect and Play Console pages and measure each saved image at
capture time.

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

## Demo Connect and Worker

Use a separate demo Connect under an isolated OS user, never the personal one. Install
each provider CLI there and sign in with accounts you control; never copy personal CLI
credentials, tokens or sessions into the demo or these documents, and review provider
charges and limits before a live test. Pair a demo Worker with the current Connect
commands (`syntila-connect pair`, see [Connect CLI and services](../specifications/CONNECT_CLI_AND_SERVICES.md))
and confirm in the app that the Worker is enabled, its Profile is verified and its
provider CLI is signed in. Record only non-secret evidence (date, environment, Worker
and model names, readiness, blockers). Scenes 3 and 4 use read-only Chat and scene 5
uses Work; if no suitable Worker or second model is available, keep the scripted prompt
as a storyboard and defer that scene's execution screenshot rather than implying a
queued or failed run completed.
