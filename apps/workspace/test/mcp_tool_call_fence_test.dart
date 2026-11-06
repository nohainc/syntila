import 'dart:io';

import 'package:syntila_workspace/durable_sync.dart';
import 'package:syntila_workspace/mcp_tool_call_fence.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('mcp-fence-test-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('concurrent instances and restart allow only one claim', () async {
    final dir = Directory('${root.path}/claims');
    final attempts = await Future.wait([
      for (var i = 0; i < 16; i++) McpToolCallFence(dir).claim('run/step'),
    ]);
    expect(attempts.where((value) => value), hasLength(1));
    expect(await McpToolCallFence(dir).claim('run/step'), isFalse);
    expect(await McpToolCallFence(dir).claim('run/another-step'), isTrue);
    expect(dir.listSync().map((entry) => entry.path),
        everyElement(isNot(contains('run'))));
  });

  test('an empty marker left by a crash is still a claim', () async {
    final fence = McpToolCallFence(Directory('${root.path}/claims'));
    expect(await fence.claim('run/step'), isTrue);
    final marker = fence.directory.listSync().single as File;
    await marker.writeAsBytes([]);
    expect(await McpToolCallFence(fence.directory).claim('run/step'), isFalse);
  });

  test('storage errors and invalid keys fail closed', () async {
    final occupied = File('${root.path}/file')..writeAsStringSync('x');
    final fence = McpToolCallFence(Directory(occupied.path));
    await expectLater(
        fence.claim('run/step'), throwsA(isA<FileSystemException>()));
    await expectLater(fence.claim(''), throwsFormatException);
  });

  group('durability', () {
    test('claim syncs the marker, then its directory, before returning true',
        () async {
      final calls = <String>[];
      final fence = McpToolCallFence(
        Directory('${root.path}/claims'),
        sync: (path, {required directory}) async =>
            calls.add('${directory ? 'dir' : 'file'}:${path.split('/').last}'),
      );
      expect(await fence.claim('run/step'), isTrue);
      expect(calls.length, 3);
      expect(calls[0], startsWith('file:'));
      expect(
          calls.sublist(1), ['dir:claims', 'dir:${root.path.split('/').last}']);
      // A repeat claim never needs to sync: nothing new was recorded.
      calls.clear();
      expect(await fence.claim('run/step'), isFalse);
      expect(calls, isEmpty);
    });

    test('a failed sync throws but the marker still blocks any later claim',
        () async {
      final dir = Directory('${root.path}/claims');
      final failing = McpToolCallFence(dir,
          sync: (path, {required directory}) async =>
              throw const FileSystemException('disk error'));
      await expectLater(
          failing.claim('run/step'), throwsA(isA<FileSystemException>()));
      expect(await McpToolCallFence(dir).claim('run/step'), isFalse);
    });

    test('the real sync works on files and directories and fails closed',
        () async {
      if (Platform.isWindows) {
        expect(durableDirectorySyncSupported, isFalse);
        return;
      }
      expect(durableDirectorySyncSupported, isTrue);
      final file = File('${root.path}/f')..writeAsStringSync('x');
      await syncPathDurably(file.path, directory: false);
      await syncPathDurably(root.path, directory: true);
      await expectLater(
          syncPathDurably('${root.path}/missing', directory: true),
          throwsA(isA<FileSystemException>()));
      // End to end through the default implementation, non-ASCII path included.
      final fence = McpToolCallFence(Directory('${root.path}/claims-é'));
      expect(await fence.claim('run/step'), isTrue);
    });
  });

  group('outcome journal', () {
    late McpToolCallFence fence;
    setUp(() => fence = McpToolCallFence(Directory('${root.path}/claims'),
        sync: (path, {required directory}) async {}));

    test('keeps the first outcome only', () async {
      expect(await fence.claim('k'), isTrue);
      expect(await fence.wasClaimed('k'), isTrue);
      expect(await fence.recordedOutcome('k'), isNull);
      expect(
          await fence.recordOutcome('k',
              state: 'completed', code: 'completed', result: {'a': 1}),
          isTrue);
      expect(
          await fence.recordOutcome('k', state: 'unknown', code: 'x'), isFalse);
      final recorded = (await fence.recordedOutcome('k'))!;
      expect(recorded['state'], 'completed');
      expect(recorded['result'], {'a': 1});
    });

    test('an unclaimed key is not claimed and has no outcome', () async {
      expect(await fence.wasClaimed('never'), isFalse);
      expect(await fence.recordedOutcome('never'), isNull);
    });

    test('a corrupt or unknown-state record reads as no outcome', () async {
      expect(await fence.claim('k'), isTrue);
      await fence.recordOutcome('k', state: 'completed', code: 'completed');
      final file = fence.directory
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.outcome.json'));
      file.writeAsStringSync('{"state":"completed"');
      expect(await fence.recordedOutcome('k'), isNull);
      file.writeAsStringSync('{"state":"great","code":"x"}');
      expect(await fence.recordedOutcome('k'), isNull);
      // A claimed key stays claimed whatever the journal says.
      expect(await fence.claim('k'), isFalse);
    });
  });
}
