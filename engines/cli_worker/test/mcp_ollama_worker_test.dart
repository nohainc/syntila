@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:syntila_cli_worker_engine/src/mcp_host.dart';
import 'package:syntila_cli_worker_engine/src/mcp_worker_runner.dart';
import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:test/test.dart';

const workerPath = '../../examples/mcp/ollama_worker/ollama_worker.dart';

/// A scriptable stand-in for the Ollama HTTP API on a raw socket, because
/// dart:io's HttpServer does not reliably report a client that disconnects
/// mid-stream while a socket's `onDone` does.
class FakeOllama {
  late ServerSocket server;
  List<String> models = ['llama3.1:8b', 'tiny:latest'];
  int chatStatus = 200;
  String? chatError;
  List<String> chunks = ['Hel', 'lo ', 'world'];
  Duration chunkDelay = Duration.zero;
  bool hang = false;
  String? lastModel;
  String? lastPrompt;
  var aborted = Completer<void>();

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_connection);
  }

  void _connection(Socket socket) {
    final buffer = BytesBuilder();
    var handled = false;
    var closed = false;
    socket.listen(
      (data) {
        buffer.add(data);
        if (handled) return;
        final bytes = buffer.toBytes();
        final text = latin1.decode(bytes);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        final head = text.substring(0, end).split('\r\n');
        final length =
            int.tryParse(
              head
                      .map((h) => h.toLowerCase())
                      .where((h) => h.startsWith('content-length:'))
                      .map((h) => h.split(':')[1].trim())
                      .firstOrNull ??
                  '0',
            ) ??
            0;
        if (bytes.length < end + 4 + length) return;
        handled = true;
        final parts = head.first.split(' ');
        final body = utf8.decode(bytes.sublist(end + 4, end + 4 + length));
        unawaited(_respond(socket, parts[0], parts[1], body, () => closed));
      },
      onDone: () {
        closed = true;
        if (handled && !aborted.isCompleted) aborted.complete();
      },
      onError: (Object _) {
        closed = true;
        if (!aborted.isCompleted) aborted.complete();
      },
      cancelOnError: true,
    );
  }

  void _json(Socket socket, int status, Object body) {
    final payload = utf8.encode(jsonEncode(body));
    socket.add(
      latin1.encode(
        'HTTP/1.1 $status X\r\nContent-Type: application/json\r\n'
        'Content-Length: ${payload.length}\r\nConnection: close\r\n\r\n',
      ),
    );
    socket.add(payload);
  }

  void _chunk(Socket socket, Object line) {
    final data = utf8.encode('${jsonEncode(line)}\n');
    socket.add(latin1.encode('${data.length.toRadixString(16)}\r\n'));
    socket.add(data);
    socket.add(latin1.encode('\r\n'));
  }

  Future<void> _respond(
    Socket socket,
    String method,
    String path,
    String body,
    bool Function() closed,
  ) async {
    try {
      if (method == 'GET' && path == '/api/version') {
        _json(socket, 200, {'version': '0.0.0-fake'});
      } else if (method == 'GET' && path == '/api/tags') {
        _json(socket, 200, {
          'models': [
            for (final m in models) {'name': m},
          ],
        });
      } else if (method == 'POST' && path == '/api/chat') {
        final decoded = jsonDecode(body) as Map<String, Object?>;
        lastModel = decoded['model'] as String?;
        lastPrompt =
            ((decoded['messages'] as List).first as Map)['content'] as String?;
        if (chatStatus != 200) {
          _json(socket, chatStatus, {'error': chatError ?? 'failure'});
        } else {
          socket.add(
            latin1.encode(
              'HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n'
              'Transfer-Encoding: chunked\r\n\r\n',
            ),
          );
          for (final text in chunks) {
            _chunk(socket, {
              'message': {'role': 'assistant', 'content': text},
              'done': false,
            });
            await socket.flush();
            if (chunkDelay > Duration.zero)
              await Future<void>.delayed(chunkDelay);
          }
          if (hang) {
            final until = DateTime.now().add(const Duration(seconds: 25));
            while (!closed() && DateTime.now().isBefore(until)) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            return;
          }
          _chunk(socket, {'done': true});
          socket.add(latin1.encode('0\r\n\r\n'));
        }
      } else {
        _json(socket, 404, {'error': 'not found'});
      }
      await socket.flush();
    } on Object {
      // The client went away.
    } finally {
      if (!hang || chatStatus != 200 || path != '/api/chat') {
        await socket.close().catchError((Object _) {});
      }
    }
  }

  Future<void> stop() => server.close();
}

late String dartDigest;
late Directory root;
final plugins = PluginHost();

McpServerSpec spec(String baseUrl, {ToolPins? pins}) => McpServerSpec(
  serverId: 'ollama-worker',
  workspaceId: 'ws1',
  requireWorkerProfile: true,
  pins: pins,
  launch: PluginLaunch(
    executable: Platform.resolvedExecutable,
    arguments: [File(workerPath).absolute.path],
    artifactSha256: dartDigest,
    pluginId: 'ollama-worker',
    version: '1.0.0',
    dataDirectory: root.path,
    workingDirectory: root.path,
    environment: {...PluginHost.buildEnvironment(), 'OLLAMA_BASE_URL': baseUrl},
    hostVersion: '1.4.0',
  ),
);

PluginRunRequest request(
  String prompt, {
  String? model,
  Duration deadline = const Duration(seconds: 30),
}) => PluginRunRequest(
  executeId: 'e1',
  prompt: prompt,
  access: 'read_write',
  deadline: deadline,
  model: model,
);

void main() {
  late FakeOllama ollama;
  late McpHost host;
  late McpWorkerRunner runner;

  Future<McpServerSpec> consented([String? baseUrl]) async {
    final url = baseUrl ?? ollama.base;
    final lease = await host.acquire(spec(url));
    final pins = ToolPins.fromTools(lease.tools);
    lease.release();
    return spec(url, pins: pins);
  }

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('mcp-ollama');
    dartDigest = await plugins.sha256OfFile(Platform.resolvedExecutable);
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() async {
    ollama = FakeOllama();
    await ollama.start();
    host = McpHost(pluginHost: plugins);
    runner = McpWorkerRunner(host);
  });
  tearDown(() async {
    await host.closeAll();
    await ollama.stop();
  });

  test(
    'passive probe reaches Ollama; live also requires an installed model',
    () async {
      final s = await consented();
      final passive = await runner.probe(s, 'passive') as PluginProbeSuccess;
      expect(passive.state, 'ready');
      expect(passive.checks.single['message'], contains('0.0.0-fake'));
      expect(
        (passive.capabilities['continuity'] as Map)['strategy'],
        'history_replay',
      );
      ollama.models = [];
      final live = await runner.probe(s, 'live') as PluginProbeSuccess;
      expect(live.state, 'setup_required');
      expect(live.issueCode, 'ollama_model_missing');
      ollama.models = ['tiny:latest'];
      expect(
        (await runner.probe(s, 'live') as PluginProbeSuccess).state,
        'ready',
      );
    },
  );

  test('an unreachable Ollama is unavailable, not a crash', () async {
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://127.0.0.1:${dead.port}';
    await dead.close(force: true);
    final s = await consented(url);
    final probe = await runner.probe(s, 'passive') as PluginProbeSuccess;
    expect(probe.state, 'unavailable');
    expect(probe.issueCode, 'ollama_unavailable');
    final run = await runner.run(s, request('hi')) as PluginRunFailure;
    expect(run.code, 'not_ready');
    expect(run.fromPlugin, isTrue);
  });

  test('a non-loopback OLLAMA_BASE_URL is refused', () async {
    final s = await consented('http://example.com:11434');
    final run = await runner.run(s, request('hi')) as PluginRunFailure;
    expect(run.code, 'not_ready');
    expect(run.message, contains('loopback'));
  });

  test('lists installed models and skips cloud and session entries', () async {
    ollama.models = [
      'llama3.1:8b',
      'big:cloud',
      'syntila-session-abc',
      'bad name',
    ];
    final outcome = await runner.run(
      await consented(),
      PluginRunRequest.models(
        executeId: 'm',
        deadline: const Duration(seconds: 10),
      ),
    );
    // The routing host handles `models`; the runner exposes it directly.
    expect(outcome, isA<PluginRunFailure>());
    final models =
        await runner.models(await consented()) as PluginModelsSuccess;
    expect([for (final m in models.models) m['id']], ['llama3.1:8b']);
  });

  test(
    'streams a response, reports progress and sends the chosen model',
    () async {
      ollama.chunkDelay = const Duration(milliseconds: 500);
      final progress = <String>[];
      final outcome =
          await runner.run(
                await consented(),
                request('say hello', model: 'tiny:latest'),
                onProgress: (_, m) => progress.add(m),
              )
              as PluginRunSuccess;
      expect(outcome.output, 'Hello world');
      expect(ollama.lastModel, 'tiny:latest');
      expect(ollama.lastPrompt, 'say hello');
      expect(progress, isNotEmpty);
      expect(progress.first, startsWith('Generating ('));
    },
  );

  test(
    'model selection: single installed model is automatic, else explicit',
    () async {
      final s = await consented();
      final ambiguous = await runner.run(s, request('hi')) as PluginRunFailure;
      expect(ambiguous.code, 'model_unavailable');
      final missing =
          await runner.run(s, request('hi', model: 'nope:1b'))
              as PluginRunFailure;
      expect(missing.code, 'model_unavailable');
      ollama.models = ['only:latest'];
      expect(
        (await runner.run(s, request('hi')) as PluginRunSuccess).output,
        'Hello world',
      );
      expect(ollama.lastModel, 'only:latest');
    },
  );

  test('Ollama errors map to stable codes', () async {
    ollama.models = ['m:1'];
    final s = await consented();
    ollama.chatStatus = 400;
    ollama.chatError = 'the input length exceeds the context window';
    expect(
      ((await runner.run(s, request('hi'))) as PluginRunFailure).code,
      'context_limit_exceeded',
    );
    ollama.chatStatus = 404;
    ollama.chatError = 'model "m:1" not found';
    expect(
      ((await runner.run(s, request('hi'))) as PluginRunFailure).code,
      'model_unavailable',
    );
    ollama.chatStatus = 500;
    ollama.chatError = 'boom';
    expect(
      ((await runner.run(s, request('hi'))) as PluginRunFailure).code,
      'not_ready',
    );
  });

  test('cancel aborts the HTTP request to Ollama promptly', () async {
    ollama.models = ['m:1'];
    ollama.hang = true;
    final s = await consented();
    final cancel = Completer<void>();
    final clock = Stopwatch()..start();
    final running = runner.run(s, request('long'), cancel: cancel.future);
    await Future<void>.delayed(const Duration(seconds: 2));
    cancel.complete();
    final outcome = await running as PluginRunFailure;
    expect(outcome.code, 'cancelled');
    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 4) + McpLimits.cancelGrace),
    );
    await ollama.aborted.future.timeout(const Duration(seconds: 5));
  });

  test('the deadline stops generation with a timeout', () async {
    ollama.models = ['m:1'];
    ollama.hang = true;
    final outcome =
        await runner.run(
              await consented(),
              request('long', deadline: const Duration(seconds: 3)),
            )
            as PluginRunFailure;
    expect(outcome.code, 'timeout');
    expect(
      ollama.lastPrompt,
      'long',
      reason: 'chat request never reached Ollama',
    );
    await ollama.aborted.future.timeout(const Duration(seconds: 5));
  });

  test('the packaging template is a valid MCP Worker manifest', () {
    final template = File(
      '../../examples/mcp/ollama_worker/plugin.json.template',
    ).readAsStringSync();
    final manifest = jsonDecode(
      template
          .replaceAll('__PLATFORM__', 'darwin-arm64')
          .replaceAll('__SHA256__', 'a' * 64)
          .replaceAll('__SIZE__', '1234'),
    );
    final validation = validatePluginManifest(manifest);
    expect(validation.issues, isEmpty);
    expect(validation.manifest!.isMcp, isTrue);
  });
}
