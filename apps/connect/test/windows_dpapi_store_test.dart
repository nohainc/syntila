import 'dart:io';
import 'dart:convert';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';

List<int> _transform(
  List<int> bytes,
  String context, {
  required bool decrypt,
}) => bytes.map((value) => value ^ 0xa5).toList();

void main() {
  test(
    'migrates only after encrypted readback and retains mismatched files',
    () async {
      final dir = await Directory.systemTemp.createTemp('worker-dpapi-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/identity/key.json');
      final original = await generateAgentKey();
      await FileKeyStore(file).save(original);
      final store = WindowsDpapiKeyStore(file, transform: _transform);
      expect((await store.load())!.publicKeyText, original.publicKeyText);
      expect(await file.exists(), isFalse);
      expect(
        (await store.encryptedFile.readAsBytes()),
        isNot(containsAll(utf8.encode(original.publicKeyText))),
      );
      expect((await store.load())!.publicKeyText, original.publicKeyText);
      await FileKeyStore(file).save(await generateAgentKey());
      await expectLater(store.load(), throwsStateError);
      expect(await file.exists(), isTrue);
      await store.delete();
    },
  );

  test('preserves the legacy file when encryption fails', () async {
    final dir = await Directory.systemTemp.createTemp('worker-dpapi-fail-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/identity/key.json');
    await FileKeyStore(file).save(await generateAgentKey());
    List<int> fail(List<int> _, String __, {required bool decrypt}) =>
        throw StateError('unavailable');
    await expectLater(
      WindowsDpapiKeyStore(file, transform: fail).load(),
      throwsStateError,
    );
    expect(await file.exists(), isTrue);
  });
}
