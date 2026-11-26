import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';

void main() {
  test(
    'migrates only after secure readback and refuses conflicting identities',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'worker-keychain-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final tool = File('${dir.path}/security');
      final stored = '${dir.path}/stored';
      await tool.writeAsString('''#!/bin/sh
case "\$1" in
  -i) read -r line; printf '%s' "\$line" | sed 's/^.* -X //' | xxd -r -p > '$stored';;
  find-generic-password) if [ -f '$stored' ]; then cat '$stored'; else exit 44; fi;;
  delete-generic-password) rm -f '$stored';;
  *) exit 1;;
esac
''');
      await Process.run('chmod', ['700', tool.path]);
      final file = File('${dir.path}/key.json');
      final legacy = FileKeyStore(file);
      final original = await generateAgentKey();
      await legacy.save(original);
      final store = MacKeychainKeyStore(file, executable: tool.path);
      expect((await store.load())!.publicKeyText, original.publicKeyText);
      expect(await file.exists(), isFalse);
      expect((await store.load())!.publicKeyText, original.publicKeyText);
      await legacy.save(await generateAgentKey());
      await expectLater(store.load(), throwsStateError);
      expect(await file.exists(), isTrue);
      await store.delete();
      expect(await file.exists(), isFalse);
    },
    skip: Platform.isWindows
        ? 'POSIX shell required for fake security tool'
        : false,
  );

  test('retains the legacy credential when secure storage fails', () async {
    final dir = await Directory.systemTemp.createTemp('worker-keychain-fail-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/key.json');
    await FileKeyStore(file).save(await generateAgentKey());
    await expectLater(
      MacKeychainKeyStore(file, executable: '/usr/bin/false').load(),
      throwsStateError,
    );
    expect(await file.exists(), isTrue);
  }, skip: Platform.isWindows ? 'POSIX /usr/bin/false required' : false);
}
