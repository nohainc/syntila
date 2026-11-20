# Release notes: Worker-first

- **New:** the Syntila Worker Agent runs one Worker per computer, with its own key, folders and Work Root. Workers are chosen directly for Work; Workspaces are no longer needed.
- **New:** Work shows one timeline per Thread (request, answer, and a fixed notice when a request fails or is cancelled).
- **New:** steps hand over files as artifacts (checksum, size limits, 7-day retention, 15-minute download grants).
- **New:** one realtime protocol (`syntila.messaging/1`) for people and Workers; the event name `reconnect.required` is now `sync.required`.
- **Changed:** Workspace registration and the Workspace gateway are closed in stages ([LEGACY_CUTOVER.md](LEGACY_CUTOVER.md)). Existing Workspaces keep working until their step; convert with `syntila-worker import-workspace`.
- **Removed (after the rollback window):** the Workspace grant, selection and session paths, the compatibility bridge and the obsolete tables.
- **Upgrade steps:** regenerate nothing by hand; migrations 0026–0035 apply on deploy. Turn the flags on by cohort (see [FEATURE_FLAGS.md](FEATURE_FLAGS.md)), then follow the cutover steps.
