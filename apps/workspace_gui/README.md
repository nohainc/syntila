# Syntila Workspace GUI

Desktop GUI (macOS, Linux and Windows) for the `syntila` management CLI. It contains no
command logic: at startup it runs `syntila --gui-manifest=1` and renders the
result with [gui-manifest](https://github.com/nohainc/gui-manifest)'s
`gui_manifest_flutter`, styled with `syntila_design` (Inter, JetBrains Mono,
Syntila light/dark themes). New CLI commands appear without changing this app.

## One folder with the CLI

Releases ship the GUI and the CLI side by side, so either runs on its own:

```text
dist/syntila/macos/syntila/            dist/syntila/linux-<arch>/
  syntila                                syntila
  assets/engines/syntila-agent           assets/engines/syntila-agent
  Syntila Workspace.app                  gui/syntila-workspace-gui
```

The platform build scripts build the CLI, Engine and GUI together. The macOS
archive contains the app; Linux provides matching `syntila` and `syntila-gui`
Debian packages. The Windows installer includes the GUI.

## Which `syntila` it runs

1. `SYNTILA_CLI` environment variable (development)
2. The sibling `syntila` in the shared folder
3. A CLI embedded by Debug builds (`Contents/Resources/syntila/syntila`)
4. `~/.local/bin`, `/opt/homebrew/bin` (macOS), `/usr/local/bin`, `/usr/bin` (Linux)
5. `syntila` on PATH

Debug builds embed the CLI through the Xcode build phase "Embed syntila CLI"
(`macos/scripts/embed_syntila_cli.sh`): it compiles `apps/workspace` (cached in
`build/syntila_cli`, rebuilt only when sources change) and copies it, plus the
Worker Engine when built, into the app, so `flutter run -d macos` works with no
installed CLI. Release builds skip it and use the sibling CLI.

The App Sandbox is disabled so the app can start the CLI.

## Status page

`status` uses a hand-built live dashboard (`lib/src/status_page.dart`,
registered through `commandPages`): it polls `syntila status --json` every
5 s and offers Connect/Disconnect, Pause/Resume and Start service. Every other
command uses a generated page that runs the CLI without `--json` and shows its original output.
The Workspace command metadata assigns sidebar section labels (`WORKSPACE`, `ACCOUNT & CLOUD`, and
`DIAGNOSTICS`); the GUI renders labels supplied by the CLI dynamically.
Sign in accepts an email and password in the form. The password is sent to the
CLI through standard input, never as a process argument. The CLI retains
interactive `syntila login`; scripts can pass `--email` and `--password-stdin`.
Set up also accepts a Workspace name and Cloud credentials in its form; it
starts the service after registration. Terminal setup retains its prompts.
Connect waits up to 20 seconds for a ready connection. Metrics and Slots use
Nano Markup by default; `--json` retains JSON output.

## Release build

```console
bash scripts/build-workspace.sh --local          # current host
bash scripts/build-workspace-macos.sh --prod     # macOS host
bash scripts/build-workspace-linux.sh --prod     # Linux host
bash scripts/build-workspace-windows.sh --prod   # Windows Git Bash
```

Use `--local` for an isolated local build and `--prod` for production. Flutter
desktop builds run on their target operating system. Release signing and package
publication run through the platform release workflows.

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
flutter run -d macos
flutter test
dart compile exe ../workspace/bin/syntila_workspace_cli.dart -o /tmp/syntila
SYNTILA_CLI=/tmp/syntila flutter test test/real_cli_smoke_test.dart
```
