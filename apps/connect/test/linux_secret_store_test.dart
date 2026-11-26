import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';

void main() {
  test(
    'migrates a file key, persists selection, and isolates rotation keys',
    () async {
      final dir = await Directory.systemTemp.createTemp('worker-secret-test-');
      addTearDown(() => dir.delete(recursive: true));
      final tool = File('${dir.path}/secret-tool');
      await tool.writeAsString('''#!/bin/sh
case "\$1" in
  lookup) if [ -f '${dir.path}/secret-'"\$5" ]; then cat '${dir.path}/secret-'"\$5"; else exit 1; fi;;
  store) cat > '${dir.path}/secret-'"\$7";;
  clear) rm -f '${dir.path}/secret-'"\$5";;
  *) exit 2;;
esac
''');
      await Process.run('chmod', ['700', tool.path]);
      final file = File('${dir.path}/identity/key.json');
      final marker = File('${dir.path}/identity/credential-store');
      final original = await generateAgentKey();
      await FileKeyStore(file).save(original);
      final store = LinuxSecretKeyStore(file, marker, executable: tool.path);
      expect((await store.load())!.publicKeyText, original.publicKeyText);
      expect(await file.exists(), isFalse);
      expect((await marker.readAsString()).trim(), 'secret-service');
      final pending = LinuxSecretKeyStore(
        File('${dir.path}/identity/key.next.json'),
        marker,
        executable: tool.path,
      );
      final next = await generateAgentKey();
      await pending.save(next);
      expect((await pending.load())!.publicKeyText, next.publicKeyText);
      expect((await store.load())!.publicKeyText, original.publicKeyText);
      await pending.delete();
      expect(await pending.load(), isNull);
      await store.delete();
    },
    skip: Platform.isWindows ? 'POSIX shell required for fake secret-tool' : false,
  );

  test('preserves the file when Secret Service fails', () async {
    final dir = await Directory.systemTemp.createTemp('worker-secret-fail-');
    addTearDown(() => dir.delete(recursive: true));
    final tool = File('${dir.path}/secret-tool');
    await tool.writeAsString('#!/bin/sh\necho unavailable >&2\nexit 1\n');
    await Process.run('chmod', ['700', tool.path]);
    final file = File('${dir.path}/identity/key.json');
    await FileKeyStore(file).save(await generateAgentKey());
    await expectLater(
      LinuxSecretKeyStore(
        file,
        File('${dir.path}/identity/credential-store'),
        executable: tool.path,
      ).load(),
      throwsStateError,
    );
    expect(await file.exists(), isTrue);
  }, skip: Platform.isWindows ? 'POSIX shell required for fake secret-tool' : false);
}
