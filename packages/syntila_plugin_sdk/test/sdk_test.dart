@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_plugin_conformance/syntila_plugin_conformance.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';
import 'package:test/test.dart';

/// Produced by the TypeScript `pluginManifestDigest`; Cloud, the Workspace and
/// this SDK must all compute the same pin.
const _vectorDigest =
    "1bb61d4147ad05e39110b86209fdb9f54dce582f6ffb0d92bbc913a928d49a8d";
final _vectorManifest = jsonDecode(
        r'''{"schemaVersion": 1, "pluginId": "acme-reviewer", "version": "1.4.2", "displayName": "Acme Reviewer \u2014 \u00fcn\u00efcode \u2713", "description": "Reviews \"code\".\nSecond line with a tab\t.", "author": {"name": "Acme", "contact": "plugins@acme.example"}, "protocol": {"min": "1.0", "max": "1.0"}, "artifacts": {"linux-x64": {"command": "bin/reviewer", "args": ["--syntila", "--flag=a/b"], "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 1024}}, "capabilities": {"progress": true, "readOnly": "never"}, "access": {"workRoot": "write", "network": {"mode": "declared", "hosts": ["api.acme.example"]}, "subprocess": false, "env": ["ACME_ENDPOINT"]}}''')
    as Map<String, Object?>;

/// Drives [runPlugin] in-process with controllable stdin/stdout.
class Harness {
  Harness(PluginWorker plugin) {
    final out = StreamController<List<int>>();
    out.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) => received.add(jsonDecode(line) as Map<String, Object?>));
    _outSink = IOSink(out);
    _logSink = IOSink(_log);
    done = runPlugin(
      plugin,
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

  void send(Map<String, Object?> frame) =>
      _in.add(utf8.encode('${jsonEncode(frame)}\n'));

  void hello() => send({
        'type': 'hello',
        'id': 'h1',
        'protocol': {
          'supported': ['1.0'],
          'preferred': '1.0'
        },
        'host': {'name': 'test', 'version': '1.0.0'},
        'dataDir': Directory.systemTemp.path,
      });

  void execute(String id,
          {String prompt = 'hi', String access = 'read_write'}) =>
      send({
        'type': 'execute',
        'id': id,
        'deadlineMs': 10000,
        'prompt': prompt,
        'workingDirectory': Directory.systemTemp.path,
        'access': access,
        'attachments': <Object?>[],
      });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 120));

  Future<void> close() async {
    await _in.close();
    await done;
    await _outSink.close();
    await _logSink.close();
  }

  List<Map<String, Object?>> ofType(String type) =>
      received.where((f) => f['type'] == type).toList();
}

class Probe extends PluginWorker {
  Probe(this.body);
  final Future<WorkResult> Function(WorkRequest, WorkContext) body;
  @override
  String get id => 'probe-plugin';
  @override
  String get version => '1.0.0';
  @override
  Future<WorkResult> execute(WorkRequest r, WorkContext c) => body(r, c);
}

void main() {
  group('runPlugin', () {
    test('answers the handshake with the plugin identity', () async {
      final h = Harness(Probe((_, __) async => const WorkResult('x')))..hello();
      await h.settle();
      final result = h.ofType('hello.result').single;
      expect(result['protocol'], '1.0');
      expect((result['plugin'] as Map)['id'], 'probe-plugin');
      await h.close();
    });

    test('refuses a host that offers no common protocol', () async {
      final h = Harness(Probe((_, __) async => const WorkResult('x')));
      h.send({
        'type': 'hello',
        'id': 'h1',
        'protocol': {
          'supported': ['2.0'],
          'preferred': '2.0'
        },
        'host': {'name': 't', 'version': '1'},
        'dataDir': Directory.systemTemp.path,
      });
      await h.settle();
      expect(h.ofType('error').single['code'], 'unsupported_protocol');
      await h.done;
    });

    test('sends exactly one terminal frame with progress before it', () async {
      final h = Harness(
        Probe((r, c) async {
          c.progress('step one', percent: 10);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return WorkResult('done: ${r.prompt}');
        }),
      )..hello();
      h.execute('e1', prompt: 'work');
      await h.settle();
      final types = h.received.map((f) => f['type']).toList();
      expect(types.where((t) => t == 'result'), hasLength(1));
      expect(types.indexOf('progress'), lessThan(types.indexOf('result')));
      expect(h.ofType('result').single['output'], 'done: work');
      await h.close();
    });

    test('oversize output returns a terminal error', () async {
      final h = Harness(Probe((_, __) async =>
          WorkResult('x' * (PluginProtocolLimits.maxOutputBytes + 1))))
        ..hello();
      h.execute('large');
      await h.settle();
      expect(h.ofType('error').single['code'], 'output_too_large');
      expect(h.ofType('result'), isEmpty);
      await h.close();
    });

    test('invalid artifacts still produce one terminal error', () async {
      final h = Harness(Probe(
          (_, __) async => const WorkResult('x', artifacts: ['../escape'])))
        ..hello();
      h.execute('invalid');
      await h.settle();
      expect(h.ofType('error').single['code'], 'internal');
      expect(h.ofType('result'), isEmpty);
      await h.close();
    });

    test('maps PluginFailure to its code and hides other errors', () async {
      var n = 0;
      final h = Harness(
        Probe((_, __) async {
          n += 1;
          if (n == 1) {
            throw const PluginFailure('sign_in_required', 'Sign in first');
          }
          throw StateError('secret internal detail /Users/me/token');
        }),
      )..hello();
      h.execute('e1');
      await h.settle();
      h.execute('e2');
      await h.settle();
      final errors = h.ofType('error');
      expect(errors[0]['code'], 'sign_in_required');
      expect(errors[1]['code'], 'internal');
      expect(jsonEncode(errors[1]), isNot(contains('secret')));
      expect(jsonEncode(errors[1]), isNot(contains('/Users')));
      await h.close();
    });

    test('cancel stops cooperative work with a cancelled error', () async {
      final started = Completer<void>();
      final h = Harness(
        Probe((_, c) async {
          started.complete();
          await c.cancelled;
          return const WorkResult('partial');
        }),
      )..hello();
      h.execute('e1');
      await started.future;
      h.send({'type': 'cancel', 'id': 'e1', 'reason': 'user'});
      await h.settle();
      expect(h.ofType('error').single['code'], 'cancelled');
      expect(h.ofType('result'), isEmpty);
      await h.close();
    });

    test('answers pings while work is running', () async {
      final release = Completer<void>();
      final h = Harness(
        Probe((_, __) async {
          await release.future;
          return const WorkResult('x');
        }),
      )..hello();
      h.execute('e1');
      h.send({'type': 'ping', 'nonce': 'n-1'});
      await h.settle();
      expect(h.ofType('pong').single['nonce'], 'n-1');
      release.complete();
      await h.close();
    });

    test('accepts one request at a time', () async {
      final release = Completer<void>();
      final h = Harness(
        Probe((_, __) async {
          await release.future;
          return const WorkResult('x');
        }),
      )..hello();
      h.execute('e1');
      h.execute('e2');
      await h.settle();
      expect(h.ofType('error').single['id'], 'e2');
      release.complete();
      await h.close();
    });

    test('survives garbage input and keeps stdout to protocol frames',
        () async {
      final h = Harness(Probe((_, __) async => const WorkResult('x')))..hello();
      h._in.add(utf8.encode('not json\n'));
      h.send({'type': 'future.thing', 'id': 'z'});
      await h.settle();
      expect(h.ofType('error').map((f) => f['code']),
          everyElement('unsupported_frame'));
      await h.close();
    });

    test('print is redirected to the log, never to stdout', () async {
      final h = Harness(
        Probe((_, __) async {
          // ignore: avoid_print
          print('debug line');
          return const WorkResult('x');
        }),
      )..hello();
      h.execute('e1');
      await h.settle();
      expect(h.received.every((f) => f['type'] != 'debug line'), isTrue);
      await h.close();
      expect(await h.logLines, contains(contains('debug line')));
    });
  });

  group('packaging', () {
    test('the manifest digest equals the TypeScript digest', () {
      expect(pluginManifestDigest(_vectorManifest), _vectorDigest);
    });

    test('pack fills hashes from the files and validates', () {
      final dir = Directory.systemTemp.createTempSync('pack-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/bin/run')
        ..createSync(recursive: true)
        ..writeAsStringSync('binary');
      File('${dir.path}/plugin.json').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'pluginId': 'packed',
          'version': '1.0.0',
          'displayName': 'Packed',
          'description': '',
          'author': {'name': 'Me'},
          'protocol': {'min': '1.0', 'max': '1.0'},
          'artifacts': {
            'any': {'command': 'bin/run'},
          },
          'capabilities': <String, Object?>{},
          'access': {
            'workRoot': 'none',
            'network': {'mode': 'none'},
            'subprocess': false,
            'env': <String>[],
          },
        }),
      );
      final result = packPluginDirectory(dir.path);
      final artifact = result.manifest.artifacts['any']!;
      expect(artifact.size, 6);
      expect(artifact.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(result.digest, matches(RegExp(r'^[0-9a-f]{64}$')));
      // Packing again changes nothing.
      expect(packPluginDirectory(dir.path).digest, result.digest);
      File('${dir.path}/bin/run').writeAsStringSync('changed');
      expect(packPluginDirectory(dir.path).digest, isNot(result.digest));
    });

    test('pack rejects an unsafe artifact path and an invalid manifest', () {
      final dir = Directory.systemTemp.createTempSync('pack-bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/plugin.json').writeAsStringSync(
        jsonEncode({
          'artifacts': {
            'any': {'command': '../evil'},
          },
        }),
      );
      expect(() => packPluginDirectory(dir.path), throwsFormatException);
      File('${dir.path}/plugin.json').writeAsStringSync('{"artifacts":{}}');
      expect(() => packPluginDirectory(dir.path), throwsFormatException);
    });
  });

  test('init generates a buildable plugin and refuses overwrite', () async {
    final root = Directory.systemTemp.createTempSync('plugin-init');
    addTearDown(() => root.deleteSync(recursive: true));
    initializePluginDirectory(root.path, 'new-plugin',
        sdkPath: Directory.current.path);
    expect(
        () => initializePluginDirectory(root.path, 'new-plugin',
            sdkPath: Directory.current.path),
        throwsFormatException);
    for (final args in [
      ['pub', 'get'],
      ['analyze'],
      [
        'compile',
        'exe',
        'bin/main.dart',
        '-o',
        Platform.isWindows ? 'bin/plugin.exe' : 'bin/plugin'
      ],
    ]) {
      final run = await Process.run(Platform.resolvedExecutable, args,
          workingDirectory: root.path);
      expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    }
    expect(packPluginDirectory(root.path).manifest.pluginId, 'new-plugin');
  });

  test('Python echo passes standalone conformance', () async {
    final script = File('../../examples/plugins/echo_python/echo.py').absolute;
    final report = await ConformanceRunner(
      launcher: DirectProcessLauncher(
          executable: 'python3', arguments: [script.path]),
      expectedPluginId: 'echo-python',
      expectedVersion: '1.0.0',
      declaresResume: true,
      declaredCapabilities: const {'progress': true, 'sessionResume': true},
    ).run();
    expect(
        report.cases
            .where((c) => c.status == ConformanceStatus.failed)
            .map((c) => '${c.id}: ${c.detail}'),
        isEmpty);
    expect(report.cases.where((c) => c.status == ConformanceStatus.skipped),
        isEmpty);
    expect(report.cases, hasLength(21));
    expect(report.passed, isTrue);
  });

  test('the echo example, packed, passes every conformance case', () async {
    final root = Directory.systemTemp.createTempSync('echo-example');
    addTearDown(() => root.deleteSync(recursive: true));
    final binary = '${root.path}/echo';
    final compiled = await Process.run(
        Platform.resolvedExecutable,
        [
          'compile',
          'exe',
          'bin/echo_dart.dart',
          '-o',
          binary,
        ],
        workingDirectory: '../../examples/plugins/echo_dart');
    expect(compiled.exitCode, 0,
        reason: '${compiled.stdout}${compiled.stderr}');
    final package = Directory('${root.path}/package/bin')
      ..createSync(recursive: true);
    File(binary).copySync('${package.path}/echo');
    File('${root.path}/package/plugin.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'pluginId': 'echo-dart',
        'version': '1.0.0',
        'displayName': 'Echo (Dart)',
        'description': 'Reference plugin.',
        'author': {'name': 'Syntila'},
        'protocol': {'min': '1.0', 'max': '1.0'},
        'artifacts': {
          currentPluginPlatform(): {'command': 'bin/echo'},
        },
        'capabilities': {'progress': true, 'sessionResume': true},
        'access': {
          'workRoot': 'write',
          'network': {'mode': 'none'},
          'subprocess': false,
          'env': <String>[],
        },
      }),
    );
    final packed = packPluginDirectory('${root.path}/package');
    final work = Directory('${root.path}/cwd')..createSync();
    final report = await ConformanceRunner(
      launcher: DirectProcessLauncher(
        executable: '${root.path}/package/bin/echo',
        workingDirectory: work.path,
      ),
      expectedPluginId: packed.manifest.pluginId,
      expectedVersion: packed.manifest.version,
      declaresResume: true,
      declaredCapabilities: const {'progress': true, 'sessionResume': true},
    ).run();
    final failed = report.cases
        .where((c) => c.status == ConformanceStatus.failed)
        .map((c) => '${c.id}: ${c.detail}');
    expect(failed, isEmpty);
    expect(report.cases.where((c) => c.status == ConformanceStatus.skipped),
        isEmpty);
    expect(report.passed, isTrue);
  });
}
