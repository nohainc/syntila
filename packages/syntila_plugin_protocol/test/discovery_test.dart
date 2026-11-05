import 'dart:convert';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('discovery accepts empty catalogs and rejects duplicate or invalid IDs',
      () {
    PluginFrame parse(List<Object?> models) => decodePluginFrame(
        jsonEncode({
          'type': 'models.list.result',
          'id': 'd1',
          'models': models,
        }),
        PluginDirection.pluginToHost);
    expect(parse([]).type, 'models.list.result');
    final model = {'id': 'm:8b', 'name': 'Model', 'status': 'listed'};
    expect(() => parse([model, model]), throwsA(isA<PluginFrameException>()));
    expect(
        () => parse([
              {'id': '../bad', 'name': 'Bad'}
            ]),
        throwsA(isA<PluginFrameException>()));
  });
  test('checkpoint declarations require a format identity', () {
    expect(() => validatePluginContinuity({'strategy': 'checkpoint'}),
        throwsA(isA<PluginFrameException>()));
    validatePluginContinuity({'strategy': 'checkpoint', 'formatId': 'kv-v1'});
    validatePluginContinuity({'strategy': 'history_replay'});
  });
  test('discovery responses must match an outstanding request', () {
    final session =
        PluginHostSession(expectedPluginId: 'test', expectedVersion: '1.0.0');
    session.startHandshake(id: 'h1', hostVersion: '1.0.0', dataDir: '/tmp');
    final hello = decodePluginFrame(
        jsonEncode({
          'type': 'hello.result',
          'id': 'h1',
          'protocol': '1.1',
          'plugin': {'id': 'test', 'version': '1.0.0', 'name': 'Test'},
          'capabilities': {'modelDiscovery': true}
        }),
        PluginDirection.pluginToHost);
    expect(session.onPluginFrame(hello).isViolation, false);
    session.beginListModels(id: 'd1');
    final wrong = PluginFrame('models.list.result',
        {'type': 'models.list.result', 'id': 'd2', 'models': []});
    expect(session.onPluginFrame(wrong).isViolation, true);
    final correct = PluginFrame('models.list.result',
        {'type': 'models.list.result', 'id': 'd1', 'models': []});
    expect(session.onPluginFrame(correct).isViolation, false);
    expect(session.onPluginFrame(correct).isViolation, true);
  });
}
