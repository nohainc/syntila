# AX Rendering Diagnostics V1

## Purpose

The AX Web App has one bounded, privacy-safe diagnostic reporter for Flutter
framework errors, uncaught asynchronous exceptions, realtime delivery, cache
mutations, notifier dispatches, and selected widget rebuilds. It is intended to
make lifecycle failures diagnosable before the rendering structure is changed.

The reporter retains recent metadata in memory and may be given a test or local
diagnostic sink. It does not persist prompts, model output, tool arguments,
credentials, or unrestricted provider payloads.

## Context contract

Records may include:

- `threadId`, `tab`, `eventType`, and `requestId`;
- `component` and operation;
- mounted/disposed state;
- UTC timestamp, event category, exception type, and bounded stack trace.

Realtime context is extracted from the event envelope and its payload. Missing
identifiers remain absent rather than being guessed.

## Exception categories

The reporter classifies the current audit targets as:

- `build_phase_notification`;
- `use_after_dispose`;
- `scroll_not_attached`;
- `layout_failure`;
- `duplicate_global_key`;
- `stale_index`;
- `framework_exception` and `async_exception` for uncategorized failures.

Every captured exception includes its available stack trace. Records are capped
at 256 entries and individual error text and stacks are bounded.

## Lifecycle audit changes

The Thread page now uses named, removable scroll listeners and checks controller
attachment before reading positions. Tab changes update diagnostic context.
The page marks its mounted/disposed state during initialization and disposal.
Composers size independently; the former cross-pane measurement keys and
alignment callback have been removed.

The realtime sync and activity store report cache and notifier operations, while
the app shell and Thread page report selected rebuilds. These records are
diagnostic observations only; Cloud lifecycle state remains authoritative for
execution status.

## Verification scope

`ax_render_diagnostics_test.dart` covers context and stack capture, all six
targeted exception signatures, redaction and retention bounds, and diagnostic
event categories. Existing AX realtime, activity, progress, notification, and
snapshot tests cover the affected event and cache paths.

The reporter currently has no remote telemetry backend. Production collection,
if needed, must be added through an explicit privacy-reviewed sink.
