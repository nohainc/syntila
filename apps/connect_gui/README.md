# Syntila Connect

A desktop app for the Syntila Connect CLI (`syntila-connect`, `apps/connect`).
The app holds no command list of its own. It runs `syntila-connect --gui-manifest=1`,
and the sidebar, forms, and result views come from that answer. The declaration
lives in `apps/connect/lib/src/gui_manifest.dart`.

Framework: [gui-manifest](https://github.com/nohainc/gui-manifest), pinned to
`242b71c88cc11c90a0fad0886467ae2db4a366ef` in `pubspec.yaml`.

## Run

```shell
# 1. Build or install the CLI, then point the GUI at it.
cd apps/connect && dart pub get
export SYNTILA_CONNECT_CLI="$PWD/bin/syntila_connect.dart"   # or the installed syntila-connect binary

# 2. Run the GUI.
cd apps/connect_gui
flutter pub get
flutter run -d macos    # or linux / windows
```

The GUI runs the CLI directly, never through a shell. Each command shows the
exact command line it runs. Results are kept for the session.

## Platform runners

This folder contains the Dart and Flutter sources only. Add the desktop
runners once, with `flutter create --platforms=macos,linux,windows --project-name syntila_connect_gui .`
Flutter keeps the existing `lib/` and `pubspec.yaml`.
