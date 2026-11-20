import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late PluginAllowList list;
  final digest = 'a' * 64;
  const id = 'plugin-0123456789ab';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('syntila-plugins-');
    list = PluginAllowList(File('${dir.path}/approved-plugins.json'));
  });
  tearDown(() => dir.delete(recursive: true));

  test('nothing is approved until the owner approves an exact pin', () async {
    expect(await list.isApproved(id, '1.0.0', digest), isFalse);
    await list.approve(id, '1.0.0', digest);
    expect(await list.isApproved(id, '1.0.0', digest), isTrue);
    expect(await list.isApproved(id, '1.0.1', digest), isFalse);
    expect(await list.isApproved(id, '1.0.0', 'b' * 64), isFalse);
    expect(await list.isApproved('plugin-ffffffffffff', '1.0.0', digest), isFalse);
  });

  test('approving twice keeps one entry and remove revokes it', () async {
    await list.approve(id, '1.0.0', digest);
    await list.approve(id, '1.0.0', digest);
    expect(await list.list(), hasLength(1));
    expect(await list.remove(id, digest), isTrue);
    expect(await list.remove(id, digest), isFalse);
    expect(await list.isApproved(id, '1.0.0', digest), isFalse);
  });

  test('invalid pins are refused and a corrupt file approves nothing', () async {
    expect(() => list.approve('official-codex', '1.0.0', digest), throwsFormatException);
    expect(() => list.approve(id, '1.0', digest), throwsFormatException);
    expect(() => list.approve(id, '1.0.0', 'xyz'), throwsFormatException);
    await list.file.writeAsString('not json');
    expect(await list.list(), isEmpty);
    expect(await list.isApproved(id, '1.0.0', digest), isFalse);
  });
}
