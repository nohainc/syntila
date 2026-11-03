import '../test/support/plugin_test_binaries.dart';

/// Builds the shared plugin test binaries before the test run starts.
Future<void> main() async {
  final binaries = await PluginTestBinaries.ensure();
  print('plugin test binaries ready: ${binaries.engine}');
}
