# Echo plugin (Dart)

From this directory:

```sh
dart pub get
dart analyze
dart compile exe bin/echo_dart.dart -o echo
```

This example supports progress, cooperative cancellation and persisted session
resume. It echoes a bounded prefix of the prompt and uses no network service.
For packaging, create a package directory with `bin/echo` and `plugin.json`
using the manifest in the [author guide](../../../docs/specifications/WORKER_PLUGIN_AUTHOR_GUIDE.md).
Set `pluginId` to `echo-dart`, `version` to `1.0.0`, capabilities to
`{"progress":true,"sessionResume":true}`, and the platform artifact command to
`bin/echo` (`bin/echo.exe` for a Windows executable). Use the current platform
key, then run the SDK pack command from a project depending on the SDK.

The SDK test compiles this source, packages it and runs all 21 standalone
conformance cases. Service registration still requires a separate conformance
run through the Engine and a valid Plus entitlement.
