import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';
import 'package:test/test.dart';

/// Drives [runMcpWorker] in-process with controllable stdin/stdout.
class Harness {
  Harness(PluginWorker worker) {
    final out = StreamController<List<int>>();
    out.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) => received.add(jsonDecode(line) as Map<String, Object?>),
        );
    _outSink = IOSink(out);
    _logSink = IOSink(_log);
    done = runMcpWorker(
      worker,
      input: _in.stream,
      output: _outSink,
      log: _logSink,
    );
    logLines = _log.stream.transform(utf8.decoder).toList();
  }

  final _in = StreamController<List<int>>();
  final _log = StreamController<List<int>>();
  final received = <Map<String, Object?>>[];
  late final IOSink _outSink;
  late final IOSink _logSink;
  late final Future<void> done;
  late final Future<List<String>> logLines;
  var _next = 1;

  int send(String method, [Map<String, Object?>? params]) {
    final id = _next++;
    _in.add(
      utf8.encode(
        '${jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'method': method,
              if (params != null) 'params': params
            })}\n',
      ),
    );
    return id;
  }

  void notify(String method, Map<String, Object?> params) => _in.add(
        utf8.encode(
          '${jsonEncode({
                'jsonrpc': '2.0',
                'method': method,
                'params': params
              })}\n',
        ),
      );

  void raw(String line) => _in.add(utf8.encode('$line\n'));

  int call(String tool, Map<String, Object?> arguments, {Object? token}) =>
      send('tools/call', {
        'name': tool,
        'arguments': arguments,
        if (token != null) '_meta': {'progressToken': token},
      });

  Future<void> settle([int ms = 150]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Map<String, Object?> response(int id) =>
      received.singleWhere((m) => m['id'] == id);

  Map<String, Object?> structured(int id) =>
      ((response(id)['result'] as Map)['structuredContent'] as Map)
          .cast<String, Object?>();

  Map<String, Object?> issue(int id) =>
      (structured(id)['issue'] as Map).cast<String, Object?>();

  List<Map<String, Object?>> progress() =>
      received.where((m) => m['method'] == 'notifications/progress').toList();

  Future<void> close() async {
    await _in.close();
    await done;
    await _outSink.close();
    await _logSink.close();
  }
}

class TestWorker extends PluginWorker {
  TestWorker(
      {this.onExecute, this.models, this.readiness, this.discovery = false});

  final Future<WorkResult> Function(WorkRequest, WorkContext)? onExecute;
  final List<PluginModel>? models;
  final Future<PluginReadiness> Function(bool live)? readiness;
  final bool discovery;
  WorkRequest? lastRequest;

  @override
  String get id => 'sdk-test';
  @override
  String get version => '1.2.3';
  @override
  String get name => 'SDK Test';
  @override
  Map<String, Object?> get capabilities => {
        'progress': true,
        if (discovery) 'modelDiscovery': true,
      };

  @override
  Future<PluginReadiness> probe({required bool live}) =>
      readiness?.call(live) ?? Future.value(const PluginReadiness.ready());

  @override
  Future<List<PluginModel>> discoverModels() async => models ?? const [];

  @override
  Future<WorkResult> execute(WorkRequest request, WorkContext context) {
    lastRequest = request;
    return onExecute?.call(request, context) ??
        Future.value(WorkResult('echo: ${request.prompt}'));
  }
}

Map<String, Object?> args(
  String prompt, {
  String access = 'work',
  Object? session,
  String? model,
  Object? deadline,
}) =>
    {
      'protocol': 'syntila.worker/1',
      'prompt': prompt,
      'access': access,
      if (session != null) 'session': session,
      if (model != null) 'model': model,
      'deadline': deadline ??
          DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 5))
              .toIso8601String(),
    };

void main() {
  late Harness h;
  tearDown(() async => h.close());

  test('initialize advertises the Worker profile and negotiates the version',
      () async {
    h = Harness(TestWorker());
    final a = h.send('initialize', {'protocolVersion': '2025-03-26'});
    final b = h.send('initialize', {'protocolVersion': '1999-01-01'});
    await h.settle();
    final first = h.response(a)['result'] as Map;
    expect(first['protocolVersion'], '2025-03-26');
    expect((first['_meta'] as Map)['syntila.worker'], '1');
    expect((first['serverInfo'] as Map)['name'], 'SDK Test');
    expect((first['serverInfo'] as Map)['version'], '1.2.3');
    // An unknown client version gets the newest one this SDK supports.
    expect((h.response(b)['result'] as Map)['protocolVersion'], isNotNull);
    expect((h.response(b)['result'] as Map)['protocolVersion'],
        isNot('1999-01-01'));
  });

  test('tools/list offers models only for Workers that discover them',
      () async {
    h = Harness(TestWorker());
    final plain = h.send('tools/list');
    await h.settle();
    List<Object?> names(int id) => [
          for (final t in (h.response(id)['result'] as Map)['tools'] as List)
            (t as Map)['name'],
        ];
    expect(names(plain), ['syntila.execute', 'syntila.probe']);
    await h.close();
    h = Harness(TestWorker(discovery: true));
    final withModels = h.send('tools/list');
    await h.settle();
    expect(names(withModels), [
      'syntila.execute',
      'syntila.probe',
      'syntila.models',
    ]);
  });

  test('tool definitions are stable across calls (consent pins depend on it)',
      () async {
    h = Harness(TestWorker());
    final a = h.send('tools/list');
    final b = h.send('tools/list');
    await h.settle();
    expect(
      jsonEncode(h.response(a)['result']),
      jsonEncode(h.response(b)['result']),
    );
  });

  test('execute maps access, model, session and deadline onto the request',
      () async {
    final worker = TestWorker(
      onExecute: (r, c) async => WorkResult('ok',
          artifacts: const ['out/a.md'], sessionState: 'resumed'),
    );
    h = Harness(worker);
    final id = h.call(
      'syntila.execute',
      args(
        'hello',
        access: 'restricted',
        model: 'm:8b',
        session: {'key': 's-1', 'mode': 'resume'},
      ),
    );
    await h.settle();
    final r = worker.lastRequest!;
    expect(r.prompt, 'hello');
    expect(r.readOnly, isTrue);
    expect(r.model, 'm:8b');
    expect(r.sessionKey, 's-1');
    expect(r.resumeSession, isTrue);
    expect(r.rebuildSession, isFalse);
    expect(r.deadline, greaterThan(const Duration(minutes: 4)));
    expect(h.structured(id), {
      'text': 'ok',
      'artifacts': ['out/a.md'],
      'session': {'state': 'resumed'},
    });
    final content = (h.response(id)['result'] as Map)['content'] as List;
    expect((content.single as Map)['text'], 'ok');
  });

  test('rebuild mode and read-write access are passed through', () async {
    final worker = TestWorker();
    h = Harness(worker);
    h.call(
      'syntila.execute',
      args('x', session: {'key': 's', 'mode': 'rebuild'}),
    );
    await h.settle();
    expect(worker.lastRequest!.readOnly, isFalse);
    expect(worker.lastRequest!.rebuildSession, isTrue);
  });

  test('progress needs a token and strictly increases', () async {
    final worker = TestWorker(
      onExecute: (r, c) async {
        c.progress('first', percent: 20);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        c.progress('second', percent: 20); // not higher: must still advance
        await Future<void>.delayed(const Duration(milliseconds: 80));
        c.progress('third');
        return const WorkResult('done');
      },
    );
    h = Harness(worker);
    h.call('syntila.execute', args('a'), token: 'tok-1');
    await h.settle(400);
    final events = h.progress();
    expect(events.map((e) => (e['params'] as Map)['message']), [
      'first',
      'second',
      'third',
    ]);
    final values = [
      for (final e in events) (e['params'] as Map)['progress'] as num
    ];
    for (var i = 1; i < values.length; i++) {
      expect(values[i], greaterThan(values[i - 1]));
    }
    expect((events.first['params'] as Map)['total'], 100);
    expect((events.first['params'] as Map)['progressToken'], 'tok-1');
    await h.close();
    h = Harness(worker);
    h.call('syntila.execute', args('a')); // no token
    await h.settle(400);
    expect(h.progress(), isEmpty);
  });

  test('a cancel completes context.cancelled and the answer is cancelled',
      () async {
    final started = Completer<void>();
    final worker = TestWorker(
      onExecute: (r, c) async {
        started.complete();
        await c.cancelled;
        return const WorkResult('partial');
      },
    );
    h = Harness(worker);
    final id = h.call('syntila.execute', args('long'));
    await started.future;
    h.notify('notifications/cancelled', {'requestId': id});
    await h.settle();
    expect(h.issue(id)['code'], 'cancelled');
    expect(h.received.where((m) => m['id'] == id), hasLength(1));
  });

  test('a cancel for another request is ignored', () async {
    final release = Completer<void>();
    final worker = TestWorker(
      onExecute: (r, c) async {
        await release.future;
        return WorkResult(c.isCancelled ? 'cancelled' : 'fine');
      },
    );
    h = Harness(worker);
    final id = h.call('syntila.execute', args('x'));
    await h.settle();
    h.notify('notifications/cancelled', {'requestId': 999});
    release.complete();
    await h.settle();
    expect(h.structured(id)['text'], 'fine');
  });

  test('failures keep their code; unexpected errors never leak internals',
      () async {
    h = Harness(
      TestWorker(
        onExecute: (r, c) async {
          if (r.prompt == 'limit') {
            throw const PluginFailure('rate_limited', 'slow down',
                retryable: true);
          }
          throw StateError('secret path /Users/me/.ssh');
        },
      ),
    );
    final a = h.call('syntila.execute', args('limit'));
    final b = h.call('syntila.execute', args('boom'));
    await h.settle();
    expect((h.response(a)['result'] as Map)['isError'], isTrue);
    expect(h.issue(a), {
      'code': 'rate_limited',
      'message': 'slow down',
      'retryable': true,
    });
    expect(h.issue(b)['code'], 'internal');
    expect(jsonEncode(h.response(b)), isNot(contains('.ssh')));
    expect(
        (await (() async {
          await h.close();
          return h.logLines;
        })())
            .join(),
        contains('StateError'));
    h = Harness(TestWorker());
  });

  test('only one execute at a time', () async {
    final release = Completer<void>();
    h = Harness(TestWorker(onExecute: (r, c) async {
      await release.future;
      return const WorkResult('first');
    }));
    final a = h.call('syntila.execute', args('one'));
    await h.settle();
    final b = h.call('syntila.execute', args('two'));
    await h.settle();
    expect(h.issue(b), {
      'code': 'invalid_request',
      'message': 'One request at a time',
      'retryable': true,
    });
    release.complete();
    await h.settle();
    expect(h.structured(a)['text'], 'first');
  });

  test('bad input and oversize output are reported, not thrown', () async {
    h = Harness(
      TestWorker(
        onExecute: (r, c) async => WorkResult('x' * (800 * 1024)),
      ),
    );
    final empty = h.call('syntila.execute', {'prompt': ''});
    final past = h.call(
      'syntila.execute',
      args('x',
          deadline: DateTime.now()
              .toUtc()
              .subtract(const Duration(seconds: 5))
              .toIso8601String()),
    );
    final big = h.call('syntila.execute', args('big'));
    final unknown = h.call('syntila.nope', {});
    await h.settle(300);
    expect(h.issue(empty)['code'], 'invalid_request');
    expect(h.issue(past)['code'], 'timeout');
    expect(h.issue(big)['code'], 'output_too_large');
    expect(h.issue(unknown)['code'], 'invalid_request');
  });

  test('probe reports state, default check messages and capabilities',
      () async {
    final modes = <bool>[];
    h = Harness(
      TestWorker(
        readiness: (live) async {
          modes.add(live);
          return const PluginReadiness.setupRequired(
            'model_missing',
            checks: [
              PluginCheck('daemon', ok: true),
              PluginCheck('model', ok: false, message: 'No model installed'),
            ],
          );
        },
      ),
    );
    final id = h.call('syntila.probe', {'mode': 'live'});
    await h.settle();
    expect(modes, [true]);
    final s = h.structured(id);
    expect(s['state'], 'setup_required');
    expect(s['issueCode'], 'model_missing');
    expect(s['checks'], [
      {'code': 'daemon', 'ok': true, 'message': 'passed'},
      {'code': 'model', 'ok': false, 'message': 'No model installed'},
    ]);
    expect((s['capabilities'] as Map)['progress'], true);
  });

  test('a throwing probe is unavailable, not a crash', () async {
    h = Harness(TestWorker(readiness: (live) async => throw StateError('x')));
    final id = h.call('syntila.probe', {'mode': 'passive'});
    await h.settle();
    expect(h.structured(id)['state'], 'unavailable');
    expect(h.structured(id)['issueCode'], 'probe_failed');
  });

  test('models are listed and validated', () async {
    h = Harness(
      TestWorker(
        discovery: true,
        models: const [PluginModel(id: 'm:8b', name: 'Model')],
      ),
    );
    final ok = h.call('syntila.models', {});
    await h.settle();
    expect(h.structured(ok)['models'], [
      {'id': 'm:8b', 'name': 'Model', 'status': 'listed'},
    ]);
    await h.close();
    h = Harness(
      TestWorker(
        discovery: true,
        models: const [PluginModel(id: 'bad id!', name: 'x')],
      ),
    );
    final bad = h.call('syntila.models', {});
    await h.settle();
    expect(h.issue(bad)['code'], 'internal');
  });

  test('models is unknown for a Worker without discovery', () async {
    h = Harness(TestWorker());
    final id = h.call('syntila.models', {});
    await h.settle();
    expect(h.issue(id)['code'], 'invalid_request');
  });

  test('protocol errors: unknown method and malformed JSON', () async {
    h = Harness(TestWorker());
    final id = h.send('resources/list');
    h.raw('not json');
    await h.settle();
    expect((h.response(id)['error'] as Map)['code'], -32601);
    final parse =
        h.received.firstWhere((m) => m['error'] != null && m['id'] == null);
    expect((parse['error'] as Map)['code'], -32700);
  });

  test('print goes to the log and stdout carries only protocol', () async {
    h = Harness(
      TestWorker(
        onExecute: (r, c) async {
          // ignore: avoid_print
          print('debug line');
          return const WorkResult('ok');
        },
      ),
    );
    h.call('syntila.execute', args('x'));
    await h.settle();
    final logged = await (() async {
      await h.close();
      return h.logLines;
    })();
    expect(logged.join(), contains('debug line'));
    expect(h.received.every((m) => m['jsonrpc'] == '2.0'), isTrue);
    h = Harness(TestWorker());
  });

  test('in-flight work finishes after stdin closes, with one answer', () async {
    final worker = TestWorker(onExecute: (r, c) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return const WorkResult('late');
    });
    h = Harness(worker);
    final id = h.call('syntila.execute', args('x'));
    await h.settle(20);
    await h.close();
    expect(h.structured(id)['text'], 'late');
  });
}
