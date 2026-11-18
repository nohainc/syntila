import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
      'macOS credential store restores an encrypted journal in a fresh process',
      () async {
    final root = await Directory.systemTemp.createTemp('provider-store-check-');
    final path = '${root.path}/journal.jsonl';
    final installation =
        'acceptance-$pid-${DateTime.now().microsecondsSinceEpoch}';
    final service = 'com.syntila.provider-failure-test.$installation';
    Future<void> probe(String action) async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=.dart_tool/package_config.json',
        'test/support/provider_failure_keychain_probe.dart',
        action,
        path,
        service,
        installation,
      ]);
      expect(result.exitCode, 0, reason: '$action failed: ${result.stderr}');
    }

    addTearDown(() async {
      try {
        await probe('delete');
      } finally {
        await root.delete(recursive: true);
      }
    });
    await probe('write');
    expect(await File(path).readAsString(),
        isNot(contains('journal keychain recovery fixture')));
    await probe('read');
  },
      skip: !Platform.isMacOS ||
          Platform.environment['SYNTILA_TEST_MACOS_KEYCHAIN'] != '1');
}
