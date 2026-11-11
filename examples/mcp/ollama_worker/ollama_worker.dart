// Ollama MCP Worker (reference): a Syntila MCP Worker (MCP_WORKER_PROFILE_V1.md)
// that runs assignments on a local Ollama daemon through its HTTP API.
//
// Only dart: libraries are used, so `dart compile exe ollama_worker.dart` makes
// a single self-contained binary to package as a Syntila plugin
// (manifest `kind: "mcp"`, see README.md).
//
// Tools: syntila.execute (streams /api/chat, reports progress, honours
// cancellation and the deadline), syntila.probe (readiness) and syntila.models
// (installed models). Conversation continuity is `history_replay`: Syntila
// replays the history inside the prompt, so no session is kept here.
//
// Configuration: OLLAMA_BASE_URL (default http://127.0.0.1:11434). Only loopback
// addresses are accepted so a prompt can never leave the machine by accident.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const maxOutputBytes = 700 * 1024;
final _contextError = RegExp(
  r'context (?:window|length|size).*(?:exceed|too (?:long|large)|limit)|'
  r'(?:exceed|too (?:long|large)).*context (?:window|length|size)',
);
final _modelId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

void send(Map<String, Object?> message) => stdout.writeln(jsonEncode(message));

/// A tool failure with a Syntila issue code (plugin protocol error codes).
class Issue implements Exception {
  Issue(this.code, this.message);
  final String code;
  final String message;
}

class Config {
  Config(this.base);

  final Uri base;

  static Config fromEnvironment() {
    final raw =
        Platform.environment['OLLAMA_BASE_URL'] ?? 'http://127.0.0.1:11434';
    final uri = Uri.tryParse(raw);
    const loopback = {'127.0.0.1', 'localhost', '::1', '[::1]'};
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        !loopback.contains(uri.host)) {
      throw Issue(
        'not_ready',
        'OLLAMA_BASE_URL must be an http(s) loopback address.',
      );
    }
    return Config(uri);
  }
}

/// Thin Ollama client. [abort] force-closes the connection to cancel.
class Ollama {
  Ollama(this.config);

  final Config config;
  final _clients = <HttpClient>{};

  void abort() {
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  Future<Map<String, Object?>> getJson(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    _clients.add(client);
    try {
      final request = await client.getUrl(config.base.resolve(path));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await utf8.decodeStream(response);
      if (response.statusCode != 200)
        throw _fromBody(response.statusCode, body);
      return jsonDecode(body) as Map<String, Object?>;
    } on SocketException {
      throw Issue('not_ready', 'Ollama is not reachable.');
    } on TimeoutException {
      throw Issue('timeout', 'Ollama did not answer in time.');
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<Map<String, String>> models() async {
    final tags = await getJson('/api/tags');
    final result = <String, String>{};
    for (final m in (tags['models'] as List? ?? const [])) {
      final native = (m as Map)['name'];
      if (native is! String || !_modelId.hasMatch(native)) continue;
      // Cloud entries and Syntila session snapshots are not local base models.
      if (native.endsWith(':cloud') || native.startsWith('syntila-session-')) {
        continue;
      }
      result[native] = native;
      if (result.length >= 128) break;
    }
    return result;
  }

  /// Streams /api/chat, calling [onChunk] with each text delta.
  Future<String> chat(
    String model,
    String prompt, {
    required void Function(String delta) onChunk,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    _clients.add(client);
    try {
      final request = await client.postUrl(config.base.resolve('/api/chat'));
      request.headers.contentType = ContentType.json;
      final body = utf8.encode(
        jsonEncode({
          'model': model,
          'stream': true,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        }),
      );
      // An explicit length keeps the request simple for any server in front.
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw _fromBody(response.statusCode, await utf8.decodeStream(response));
      }
      final text = StringBuffer();
      var outputBytes = 0;
      var completed = false;
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final chunk = jsonDecode(line) as Map<String, Object?>;
        if (chunk['error'] is String) throw _fromBody(200, line);
        final delta = (chunk['message'] as Map?)?['content'];
        if (delta is String && delta.isNotEmpty) {
          text.write(delta);
          outputBytes += utf8.encode(delta).length;
          if (outputBytes > maxOutputBytes) {
            throw Issue('output_too_large', 'The model output is too large.');
          }
          onChunk(delta);
        }
        if (chunk['done'] == true) {
          completed = true;
          break;
        }
      }
      if (!completed) {
        throw Issue(
          'not_ready',
          'Ollama ended the response before completion.',
        );
      }
      return text.toString().trim();
    } on SocketException {
      throw Issue('not_ready', 'Ollama is not reachable.');
    } on HttpException {
      // Force-closed by abort(); the caller decides if that was a cancel.
      throw Issue('cancelled', 'The request was aborted.');
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Issue _fromBody(int status, String body) {
    var detail = body;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is String) {
        detail = decoded['error'] as String;
      }
    } on FormatException {
      // Not JSON; use the raw text.
    }
    final lower = detail.toLowerCase();
    if (_contextError.hasMatch(lower)) {
      return Issue(
        'context_limit_exceeded',
        'The conversation exceeds the model context window.',
      );
    }
    if (status == 404 || lower.contains('not found')) {
      return Issue('model_unavailable', 'The selected model is not installed.');
    }
    return Issue('not_ready', 'Ollama could not run the request.');
  }
}

class InFlight {
  InFlight(this.ollama);
  final Ollama ollama;
  var cancelled = false;
}

Map<String, Object?> toolDefinition(String name, String description) => {
  'name': name,
  'description': description,
  'inputSchema': {'type': 'object'},
};

Map<String, Object?> okResult(
  Map<String, Object?> structured, [
  String? text,
]) => {
  'content': [
    if (text != null) {'type': 'text', 'text': text},
  ],
  'structuredContent': structured,
};

Map<String, Object?> errorResult(Issue issue) => {
  'isError': true,
  'content': <Object?>[],
  'structuredContent': {
    'issue': {'code': issue.code, 'message': issue.message},
  },
};

Future<Map<String, Object?>> probe(Config config, String mode) async {
  final ollama = Ollama(config);
  try {
    final version = await ollama.getJson('/api/version');
    final checks = <Map<String, Object?>>[
      {
        'code': 'ollama_reachable',
        'ok': true,
        'message': 'Ollama ${version['version']} is reachable.',
      },
    ];
    var state = 'ready';
    String? issue;
    if (mode == 'live') {
      final models = await ollama.models();
      final hasModels = models.isNotEmpty;
      checks.add({
        'code': 'models_installed',
        'ok': hasModels,
        'message': hasModels
            ? '${models.length} model(s) installed.'
            : 'No local model is installed.',
      });
      if (!hasModels) {
        state = 'setup_required';
        issue = 'ollama_model_missing';
      }
    }
    return {
      'state': state,
      if (issue != null) 'issueCode': issue,
      'checks': checks,
      'capabilities': {
        'progress': true,
        'modelDiscovery': true,
        'continuity': {'strategy': 'history_replay'},
      },
    };
  } on Issue catch (error) {
    return {
      'state': 'unavailable',
      'issueCode': 'ollama_unavailable',
      'checks': [
        {'code': 'ollama_reachable', 'ok': false, 'message': error.message},
      ],
      'capabilities': {
        'progress': true,
        'modelDiscovery': true,
        'continuity': {'strategy': 'history_replay'},
      },
    };
  }
}

Future<Map<String, Object?>> execute(
  Config config,
  Map<String, Object?> args,
  InFlight call,
  void Function(num progress, String message) progress,
) async {
  final prompt = args['prompt'];
  if (prompt is! String || prompt.isEmpty) {
    throw Issue('invalid_request', 'The prompt is empty.');
  }
  final ollama = call.ollama;
  Timer? deadlineTimer;
  var timedOut = false;
  final deadline = DateTime.tryParse('${args['deadline']}');
  if (deadline != null) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw Issue('timeout', 'The deadline had already passed.');
    }
    deadlineTimer = Timer(remaining, () {
      timedOut = true;
      ollama.abort();
    });
  }

  try {
    final installed = await ollama.models();
    final requested = args['model'];
    final String native;
    if (requested is String && requested.isNotEmpty) {
      final found = installed[requested];
      if (found == null) {
        throw Issue(
          'model_unavailable',
          'The selected model is no longer installed.',
        );
      }
      native = found;
    } else if (installed.length == 1) {
      native = installed.values.single;
    } else {
      throw Issue('model_unavailable', 'Select an installed Ollama model.');
    }

    var chars = 0;
    var chunks = 0;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    final text = await ollama.chat(
      native,
      prompt,
      onChunk: (delta) {
        chars += delta.length;
        chunks++;
        final now = DateTime.now();
        if (now.difference(lastProgress) >= const Duration(milliseconds: 400)) {
          lastProgress = now;
          progress(chunks, 'Generating ($chars characters)');
        }
      },
    );
    return okResult({'text': text}, text);
  } catch (_) {
    if (call.cancelled)
      throw Issue('cancelled', 'The assignment was cancelled.');
    if (timedOut) throw Issue('timeout', 'Ollama timed out.');
    rethrow;
  } finally {
    deadlineTimer?.cancel();
  }
}

Future<void> main() async {
  final inFlight = <Object, InFlight>{};
  Config? config;
  Issue? configError;
  try {
    config = Config.fromEnvironment();
  } on Issue catch (error) {
    configError = error;
  }

  Future<void> handleCall(Object id, Map<String, Object?> params) async {
    final name = params['name'];
    final args = (params['arguments'] as Map?)?.cast<String, Object?>() ?? {};
    final meta = (params['_meta'] as Map?)?.cast<String, Object?>();
    final token = meta?['progressToken'];
    final call = InFlight(Ollama(config ?? Config(Uri.parse('http://x'))));
    inFlight[id] = call;
    void report(num progress, String message) {
      if (token == null) return;
      send({
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': {
          'progressToken': token,
          'progress': progress,
          'message': message,
        },
      });
    }

    Map<String, Object?> result;
    try {
      if (configError != null) throw configError;
      result = switch (name) {
        'syntila.probe' => okResult(await probe(config!, '${args['mode']}')),
        'syntila.models' => okResult({
          'models': [
            for (final id in (await Ollama(config!).models()).keys)
              {'id': id, 'name': id},
          ],
        }),
        'syntila.execute' => await execute(config!, args, call, report),
        _ => throw Issue('invalid_request', 'Unknown tool.'),
      };
    } on Issue catch (error) {
      result = errorResult(error);
    } catch (_) {
      result = errorResult(
        Issue('internal', 'The Worker failed unexpectedly.'),
      );
    } finally {
      inFlight.remove(id);
    }
    // Always answer, even after a cancel: the host ignores a late answer, and
    // a request that is never answered would only be killed after the grace.
    send({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final m = jsonDecode(line) as Map<String, Object?>;
    final id = m['id'];
    final params = (m['params'] as Map?)?.cast<String, Object?>() ?? {};
    switch (m['method']) {
      case 'initialize':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': params['protocolVersion'],
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'ollama-worker', 'version': '1.0.0'},
            '_meta': {'syntila.worker': '1'},
          },
        });
      case 'ping':
        send({'jsonrpc': '2.0', 'id': id, 'result': {}});
      case 'tools/list':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': [
              toolDefinition(
                'syntila.execute',
                'Run an assignment on a local Ollama model.',
              ),
              toolDefinition(
                'syntila.probe',
                'Check that Ollama is reachable and has a model.',
              ),
              toolDefinition(
                'syntila.models',
                'List the installed Ollama models.',
              ),
            ],
          },
        });
      case 'notifications/cancelled':
        final target = inFlight[params['requestId']];
        if (target != null) {
          target.cancelled = true;
          target.ollama.abort();
        }
      case 'tools/call':
        // Not awaited: the loop must keep reading so a cancel can arrive.
        unawaited(handleCall(id!, params));
      default:
        if (id != null) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'Method not found'},
          });
        }
    }
  }
  for (final call in inFlight.values) {
    call.ollama.abort();
  }
}
