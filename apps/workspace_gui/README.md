# Syntila Workspace GUI

macOS desktop GUI for the `syntila` management CLI. It contains no command
logic: at startup it runs `syntila --gui-manifest=1` and renders the result
with [gui-manifest](https://github.com/nohainc/gui-manifest)'s
`gui_manifest_flutter`, styled with `syntila_design` (Inter, JetBrains Mono,
Syntila light/dark themes). New CLI commands appear without changing this app.

## Which `syntila` it runs

1. `SYNTILA_CLI` environment variable (development)
2. `Syntila Workspace.app/Contents/Resources/syntila/syntila` (bundled)
3. `~/.local/bin/syntila`, `/opt/homebrew/bin/syntila`, `/usr/local/bin/syntila`
4. `syntila` on PATH

The App Sandbox is disabled so the app can start the CLI.

## Development

`gui_manifest_flutter` is a git dependency. To work against a local
checkout, create the untracked `pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  gui_manifest_flutter:
    path: /path/to/gui-manifest/gui/flutter
  gui_manifest:
    path: /path/to/gui-manifest/sdk/dart
```

```console
flutter test
dart compile exe ../workspace/bin/syntila_workspace_cli.dart -o /tmp/syntila
SYNTILA_CLI=/tmp/syntila flutter test test/real_cli_smoke_test.dart
SYNTILA_CLI=/tmp/syntila flutter run -d macos
```

Not yet done: bundling the CLI into `Contents/Resources/bin` during release
builds, signing/notarization, and a hand-built Status screen (registered via
`GuiManifestApp.builtins`).
