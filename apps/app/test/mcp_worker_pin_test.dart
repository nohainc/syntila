import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/mcp_worker_pin.dart';

void main() {
  final digest = 'a' * 64;

  test('reads the pin and the versions the Agent reports', () {
    final state = McpWorkerPinState.fromJson({
      'pin': {'version': '1.4.2', 'manifestDigest': digest},
      'available': [
        {'id': 'acme-tool', 'version': '1.4.2', 'manifestDigest': digest},
        {'id': 'acme-tool', 'version': '1.5.0', 'manifestDigest': 'b' * 64},
      ],
    });
    expect(state.pin?.version, '1.4.2');
    expect(state.available.map((v) => v.version), ['1.4.2', '1.5.0']);
    expect(state.available.first.id, 'acme-tool');
  });

  test('drops malformed entries instead of failing', () {
    final state = McpWorkerPinState.fromJson({
      'pin': {'version': '1', 'manifestDigest': 'not-a-digest'},
      'available': [
        'x',
        {'version': '', 'manifestDigest': digest},
        {'version': '1.0.0', 'manifestDigest': 'ZZ'},
        {'version': '1.0.0', 'manifestDigest': digest},
      ],
    });
    expect(state.pin, isNull);
    expect(state.available, hasLength(1));
    expect(McpWorkerPinState.fromJson(null).available, isEmpty);
  });

  test('versions compare by id, version and digest', () {
    McpWorkerVersion v(String d) =>
        McpWorkerVersion(id: 'a', version: '1.0.0', manifestDigest: d);
    expect(v(digest), v(digest));
    expect(v(digest), isNot(v('c' * 64)));
  });
}
