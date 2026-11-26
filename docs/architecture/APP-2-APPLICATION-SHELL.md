# APP-2: Application shell extraction

The Syntila application has an app-level shell boundary at
`apps/app/lib/src/app_shell.dart` and an app routing boundary at
`apps/app/lib/src/router.dart`.

`SyntilaAppShell` owns application lifecycle, authentication, shared stores,
browser history, and cross-feature coordination. Feature pages receive domain
models and callbacks instead of reaching into shell state directly.

The first extracted pages are:

- `features/spaces/spaces_pages.dart` for Spaces and Space overview;
- `features/workers/` for Workers management and settings.

The AX application shell and its domain models use current AX naming. Additional
feature pages should move behind the same boundary before new feature-specific
behavior is added to the shell.
