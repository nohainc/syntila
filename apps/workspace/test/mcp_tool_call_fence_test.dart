import 'dart:io';

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
}
