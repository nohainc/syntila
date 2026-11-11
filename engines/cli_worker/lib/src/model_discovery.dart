import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

/// Discovery parses bounded CLI metadata, never executes a model request.
List<DiscoveredModel> parseDiscoveredModels(String output, String idPrefix) {
  if (utf8.encode(output).length > 64 * 1024)
    throw const FormatException('Model catalog exceeds limit');
  final models = <String, DiscoveredModel>{};
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isEmpty) continue;
    final fields = line.split('\t');
    if (fields.length < 2 || fields.length > 4)
      throw const FormatException('Expected model ID and label');
    final id = fields[0].trim();
    if (idPrefix.isNotEmpty && !id.startsWith(idPrefix)) continue;
    final efforts =
        fields.length < 3 || fields[2].trim().isEmpty || fields[2].trim() == '-'
        ? const <String>[]
        : fields[2]
              .split(',')
              .map((effort) => effort.trim())
              .where((effort) => effort.isNotEmpty)
              .toList(growable: false);
    final defaultEffort =
        fields.length < 4 || fields[3].trim().isEmpty || fields[3].trim() == '-'
        ? null
        : fields[3].trim();
    final model = DiscoveredModel(
      id: id,
      name: fields[1].trim(),
      supportedReasoningEfforts: efforts,
      defaultReasoningEffort: defaultEffort,
    );
    if (models.containsKey(id))
      throw const FormatException('Duplicate model ID');
    models[id] = model;
    if (models.length > 128)
      throw const FormatException('Model catalog exceeds limit');
  }
  return models.values.toList();
}

/// Reads the `[possible values: a, b, c]` list a clap-based CLI prints when a
/// value-taking flag is given without a value (for example `copilot --model`).
/// Efforts come from the Profile: a [catalog] entry for a known model, else
/// [defaultEfforts]. IDs in [excludeIds] are never offered.
List<DiscoveredModel> parseClapPossibleValues(
  String output,
  String idPrefix, {
  List<Map<String, Object?>> catalog = const [],
  List<String> defaultEfforts = const [],
  Set<String> excludeIds = const {},
}) {
  if (utf8.encode(output).length > 64 * 1024)
    throw const FormatException('Model catalog exceeds limit');
  final match = RegExp(r'\[possible values:\s*([^\]]*)\]').firstMatch(output);
  if (match == null) throw const FormatException('No possible values listed');
  final known = {for (final entry in catalog) entry['id'] as String: entry};
  final models = <String, DiscoveredModel>{};
  for (final raw in match.group(1)!.split(',')) {
    final id = raw.trim();
    if (id.isEmpty || excludeIds.contains(id)) continue;
    if (idPrefix.isNotEmpty && !id.startsWith(idPrefix)) continue;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$').hasMatch(id))
      throw const FormatException('Invalid model ID');
    if (models.containsKey(id))
      throw const FormatException('Duplicate model ID');
    final entry = known[id];
    final efforts = entry != null && entry['supportedReasoningEfforts'] is List
        ? (entry['supportedReasoningEfforts'] as List).cast<String>()
        : defaultEfforts;
    models[id] = DiscoveredModel(
      id: id,
      name: entry?['name'] as String? ?? readableModelName(id),
      supportedReasoningEfforts: efforts,
      defaultReasoningEffort: entry?['defaultReasoningEffort'] as String?,
    );
    if (models.length > 128)
      throw const FormatException('Model catalog exceeds limit');
  }
  if (models.isEmpty) throw const FormatException('No models listed');
  return models.values.toList();
}

/// Reads a human model list printed one model per indented line, optionally
/// bulleted with `*` or `-` and followed by a parenthesized note, for example
/// `grok models`:
///
/// ```text
/// Available models:
///   * grok-4.7 (default)
///   grok-4.6
/// ```
///
/// Unindented lines (headings, sign-in notes) are ignored. Efforts come from
/// the Profile exactly as for [parseClapPossibleValues].
List<DiscoveredModel> parseIndentedModelList(
  String output,
  String idPrefix, {
  List<Map<String, Object?>> catalog = const [],
  List<String> defaultEfforts = const [],
  Set<String> excludeIds = const {},
}) {
  if (utf8.encode(output).length > 64 * 1024)
    throw const FormatException('Model catalog exceeds limit');
  final known = {for (final entry in catalog) entry['id'] as String: entry};
  final models = <String, DiscoveredModel>{};
  final line = RegExp(
    r'^[ \t]+(?:[*-][ \t]+)?(\S+)(?:[ \t]+\([^)]*\))?[ \t]*$',
  );
  for (final raw in const LineSplitter().convert(output)) {
    final match = line.firstMatch(raw);
    if (match == null) continue;
    final id = match.group(1)!;
    if (excludeIds.contains(id)) continue;
    if (idPrefix.isNotEmpty && !id.startsWith(idPrefix)) continue;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$').hasMatch(id))
      throw const FormatException('Invalid model ID');
    if (models.containsKey(id))
      throw const FormatException('Duplicate model ID');
    final entry = known[id];
    final efforts = entry != null && entry['supportedReasoningEfforts'] is List
        ? (entry['supportedReasoningEfforts'] as List).cast<String>()
        : defaultEfforts;
    models[id] = DiscoveredModel(
      id: id,
      name: entry?['name'] as String? ?? readableModelName(id),
      supportedReasoningEfforts: efforts,
      defaultReasoningEffort: entry?['defaultReasoningEffort'] as String?,
    );
    if (models.length > 128)
      throw const FormatException('Model catalog exceeds limit');
  }
  if (models.isEmpty) throw const FormatException('No models listed');
  return models.values.toList();
}

/// Turns a CLI model ID into a display name: `claude-sonnet-5.5` becomes
/// `Claude Sonnet 5.5` and `gpt-5.3-codex` becomes `GPT-5.3 Codex`.
String readableModelName(String id) {
  const acronyms = {'gpt': 'GPT', 'mai': 'MAI'};
  final parts = <String>[];
  for (final token in id.split('-').where((t) => t.isNotEmpty)) {
    final lower = token.toLowerCase();
    if (parts.isNotEmpty &&
        parts.last == 'GPT' &&
        RegExp(r'^\d').hasMatch(token)) {
      parts[parts.length - 1] = 'GPT-$token';
    } else if (acronyms.containsKey(lower)) {
      parts.add(acronyms[lower]!);
    } else {
      parts.add('${token[0].toUpperCase()}${token.substring(1)}');
    }
  }
  return parts.join(' ');
}

/// Queries the Codex app-server model catalog over its newline-delimited
/// JSON-RPC transport. The app-server is intentionally used only for
/// discovery here; execution remains owned by the generic CLI engine.
Future<List<DiscoveredModel>> discoverCodexAppServerModels({
  required String executable,
  required List<String> arguments,
  required Map<String, String> environment,
  required String workingDirectory,
  required String idPrefix,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final process = await startCliProcess(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
    runInShell: false,
  );
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  const cleanup = WorkerProcessCleanup();
  // Keep stderr drained so a noisy app-server cannot block its stdout.
  final stderrDrain = process.stderr.drain<void>();
  final deadline = DateTime.now().add(timeout);
  try {
    await _sendAppServerRequest(process.stdin, {
      'id': 1,
      'method': 'initialize',
      'params': {
        'clientInfo': {'name': 'syntila-cli-worker-engine', 'version': '1.2.0'},
        'capabilities': null,
      },
    });
    await _readAppServerResponse(lines, 1, deadline);
    final models = <DiscoveredModel>[];
    final seen = <String>{};
    String? cursor;
    for (var page = 0; page < 8; page++) {
      final requestId = page + 2;
      await _sendAppServerRequest(process.stdin, {
        'id': requestId,
        'method': 'model/list',
        'params': {'cursor': cursor, 'includeHidden': false, 'limit': 128},
      });
      final response = await _readAppServerResponse(lines, requestId, deadline);
      for (final model in parseCodexAppServerModels(response, idPrefix)) {
        if (!seen.add(model.id)) {
          throw const FormatException('Duplicate model ID');
        }
        models.add(model);
      }
      if (models.length > 128) {
        throw const FormatException('Model catalog exceeds limit');
      }
      final next = response['nextCursor'];
      if (next == null) return models;
      if (next is! String || next.isEmpty) {
        throw const FormatException('Codex app-server pagination is invalid');
      }
      cursor = next;
    }
    throw const FormatException('Codex app-server pagination exceeds limit');
  } finally {
    await lines.cancel();
    await cleanup.terminate(process, grace: const Duration(milliseconds: 500));
    await stderrDrain.catchError((_) {});
  }
}

/// Calls one parameterless JSON-RPC [method] on a stdio app-server (for
/// example Codex `account/rateLimits/read`) and returns the raw result. The
/// result is never interpreted: providers calculate usage differently.
///
/// [framing] `newline` is the Codex app-server transport (newline JSON with
/// an `initialize` handshake). `content_length` is LSP-style
/// `Content-Length` framing with no handshake (for example
/// `copilot --headless --stdio`). `acp` is the Agent Client Protocol: the same
/// newline JSON, an `initialize` with `protocolVersion: 1`, and an empty
/// params object on the call (for example `grok agent stdio`).
Future<Map<String, Object?>> readAppServerResult({
  required String executable,
  required List<String> arguments,
  required Map<String, String> environment,
  required String workingDirectory,
  required String method,
  String framing = 'newline',
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (framing == 'content_length') {
    return _readContentLengthRpcResult(
      executable: executable,
      arguments: arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      method: method,
      timeout: timeout,
    );
  }
  final process = await startCliProcess(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
    runInShell: false,
  );
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  const cleanup = WorkerProcessCleanup();
  final stderrDrain = process.stderr.drain<void>();
  final deadline = DateTime.now().add(timeout);
  try {
    final acp = framing == 'acp';
    await _sendAppServerRequest(process.stdin, {
      if (acp) 'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': acp
          ? {'protocolVersion': 1, 'clientCapabilities': <String, Object?>{}}
          : {
              'clientInfo': {
                'name': 'syntila-cli-worker-engine',
                'version': '1.2.0',
              },
              'capabilities': null,
            },
    });
    await _readAppServerResponse(lines, 1, deadline);
    await _sendAppServerRequest(process.stdin, {
      if (acp) 'jsonrpc': '2.0',
      'id': 2,
      'method': method,
      if (acp) 'params': <String, Object?>{},
    });
    return await _readAppServerResponse(lines, 2, deadline);
  } finally {
    await lines.cancel();
    await cleanup.terminate(process, grace: const Duration(milliseconds: 500));
    await stderrDrain.catchError((_) {});
  }
}

Future<Map<String, Object?>> _readContentLengthRpcResult({
  required String executable,
  required List<String> arguments,
  required Map<String, String> environment,
  required String workingDirectory,
  required String method,
  required Duration timeout,
}) async {
  final client = await ContentLengthRpcClient.start(
    executable: executable,
    arguments: arguments,
    environment: environment,
    workingDirectory: workingDirectory,
    timeout: timeout,
  );
  try {
    final result = await client.call(method);
    if (result is! Map) {
      throw const FormatException('JSON-RPC result is invalid');
    }
    return Map<String, Object?>.from(result);
  } finally {
    await client.close();
  }
}

/// A stdio JSON-RPC server using LSP-style `Content-Length` framing and no
/// handshake (for example `copilot --headless --stdio`). One deadline bounds
/// every call; each frame is capped at 64 KiB.
class ContentLengthRpcClient {
  ContentLengthRpcClient._(this._process, this._deadline)
    : _chunks = StreamIterator(_process.stdout),
      _stderrDrain = _process.stderr.drain<void>();

  static Future<ContentLengthRpcClient> start({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required String workingDirectory,
    required Duration timeout,
  }) async {
    final process = await startCliProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    return ContentLengthRpcClient._(process, DateTime.now().add(timeout));
  }

  static const _maxMessageBytes = 64 * 1024;
  final Process _process;
  final DateTime _deadline;
  final StreamIterator<List<int>> _chunks;
  final Future<void> _stderrDrain;
  var _pending = <int>[];
  var _nextId = 1;

  Future<void> _fill() async {
    final remaining = _deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('JSON-RPC request timed out');
    }
    if (!await _chunks.moveNext().timeout(remaining)) {
      throw const FormatException('JSON-RPC server closed before responding');
    }
    _pending = [..._pending, ..._chunks.current];
    if (_pending.length > _maxMessageBytes + 1024) {
      throw const FormatException('JSON-RPC response exceeds limit');
    }
  }

  /// Calls [method] and returns its raw `result`; a JSON-RPC error becomes a
  /// [FormatException] carrying the provider's message.
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final id = _nextId++;
    final body = utf8.encode(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    _process.stdin.add(utf8.encode('Content-Length: ${body.length}\r\n\r\n'));
    _process.stdin.add(body);
    await _process.stdin.flush();
    while (true) {
      var headerEnd = -1;
      while (headerEnd < 0) {
        for (var i = 0; i + 3 < _pending.length; i++) {
          if (_pending[i] == 13 &&
              _pending[i + 1] == 10 &&
              _pending[i + 2] == 13 &&
              _pending[i + 3] == 10) {
            headerEnd = i;
            break;
          }
        }
        if (headerEnd < 0) await _fill();
      }
      final header = ascii.decode(_pending.sublist(0, headerEnd));
      final match = RegExp(
        r'^content-length:\s*(\d+)\s*$',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(header);
      final length = match == null ? null : int.tryParse(match.group(1)!);
      if (length == null || length > _maxMessageBytes) {
        throw const FormatException('JSON-RPC frame header is invalid');
      }
      final start = headerEnd + 4;
      while (_pending.length < start + length) {
        await _fill();
      }
      final message = _pending.sublist(start, start + length);
      _pending = _pending.sublist(start + length);
      final decoded = jsonDecode(utf8.decode(message));
      if (decoded is! Map || decoded['id'] != id) continue;
      final error = decoded['error'];
      if (error != null) {
        final text = error is Map && error['message'] is String
            ? error['message'] as String
            : '$error';
        throw FormatException('JSON-RPC request failed: $text');
      }
      return decoded['result'];
    }
  }

  Future<void> close() async {
    await _chunks.cancel();
    await const WorkerProcessCleanup().terminate(
      _process,
      grace: const Duration(milliseconds: 500),
    );
    await _stderrDrain.catchError((_) {});
  }
}

/// Thrown when the provider reports that no account is signed in.
class ProviderNotAuthenticatedException implements Exception {
  const ProviderNotAuthenticatedException(this.message);
  final String message;
}

/// Lists the models the signed-in GitHub Copilot account may select, through
/// the CLI's own SDK server (`auth.getStatus`, then `models.list`). Unlike the
/// CLI's `--model` value list this is account-aware: plans that only allow
/// automatic selection return no models. Auto is not listed: running Copilot
/// without `--model` already selects a model automatically, which is what the
/// client's own provider-default ("Auto") choice does.
Future<List<DiscoveredModel>> discoverCopilotSdkModels({
  required String executable,
  required List<String> arguments,
  required Map<String, String> environment,
  required String workingDirectory,
  required String idPrefix,
  Set<String> excludeIds = const {},
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = await ContentLengthRpcClient.start(
    executable: executable,
    arguments: arguments,
    environment: environment,
    workingDirectory: workingDirectory,
    timeout: timeout,
  );
  try {
    final status = await client.call('auth.getStatus');
    if (status is! Map || status['isAuthenticated'] != true) {
      final message = status is Map && status['statusMessage'] is String
          ? status['statusMessage'] as String
          : null;
      throw ProviderNotAuthenticatedException(
        'GitHub Copilot is not signed in${message == null ? '' : ' ($message)'}. '
        'Run `copilot login`, or sign in with `gh auth login`, then refresh.',
      );
    }
    return parseCopilotSdkModels(
      await client.call('models.list'),
      idPrefix,
      excludeIds: excludeIds,
    );
  } finally {
    await client.close();
  }
}

/// Maps a Copilot SDK `models.list` result. Models whose policy is
/// `disabled` are not selectable and are skipped.
List<DiscoveredModel> parseCopilotSdkModels(
  Object? response,
  String idPrefix, {
  Set<String> excludeIds = const {},
}) {
  final list = response is Map ? response['models'] : null;
  if (list is! List) {
    throw const FormatException('Copilot model list is invalid');
  }
  final models = <DiscoveredModel>[];
  final ids = <String>{};
  for (final raw in list) {
    if (raw is! Map) throw const FormatException('Copilot model is invalid');
    final id = raw['id'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,159}$').hasMatch(id)) {
      throw const FormatException('Copilot model ID is invalid');
    }
    if (excludeIds.contains(id)) continue;
    if (idPrefix.isNotEmpty && !id.startsWith(idPrefix)) continue;
    final policy = raw['policy'];
    if (policy is Map && policy['state'] == 'disabled') continue;
    if (!ids.add(id)) continue;
    final efforts = <String>[];
    final rawEfforts = raw['supportedReasoningEfforts'];
    if (rawEfforts is List) {
      for (final effort in rawEfforts) {
        if (effort is! String ||
            !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(effort)) {
          throw const FormatException('Copilot reasoning effort is invalid');
        }
        if (!efforts.contains(effort)) efforts.add(effort);
      }
    }
    final defaultEffort = raw['defaultReasoningEffort'];
    final name = raw['name'];
    models.add(
      DiscoveredModel(
        id: id,
        name: name is String && name.trim().isNotEmpty
            ? name.trim()
            : readableModelName(id),
        supportedReasoningEfforts: efforts,
        defaultReasoningEffort:
            defaultEffort is String && efforts.contains(defaultEffort)
            ? defaultEffort
            : null,
      ),
    );
    if (models.length > 128) {
      throw const FormatException('Model catalog exceeds limit');
    }
  }
  return models;
}

/// Lists the models the signed-in Claude account may use through the
/// Anthropic Models API (`GET /v1/models`). The Claude CLI has no list command.
/// The credential is the Claude Code sign-in (macOS keychain or
/// `~/.claude/.credentials.json`) or `ANTHROPIC_API_KEY`; it is only sent to
/// `api.anthropic.com` and never logged or stored. The full model ID is the
/// execution value, so a selection stays pinned to that model.
Future<List<DiscoveredModel>> discoverClaudeApiModels({
  required String idPrefix,
  Set<String> excludeIds = const {},
  Duration timeout = const Duration(seconds: 10),
  Map<String, String>? environment,
  Future<Map<String, String>?> Function()? credentialReader,
  HttpClient Function()? clientFactory,
}) async {
  final headers = await (credentialReader ?? readClaudeApiCredential)(
    environment ?? Platform.environment,
  );
  if (headers == null) {
    throw ProviderNotAuthenticatedException(
      'Claude is not signed in. Run `claude` and sign in, then refresh.',
    );
  }
  final client = (clientFactory ?? HttpClient.new)()
    ..connectionTimeout = timeout;
  try {
    final request = await client
        .getUrl(Uri.https('api.anthropic.com', '/v1/models', {'limit': '100'}))
        .timeout(timeout);
    request.headers.set('anthropic-version', '2023-06-01');
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    if (response.statusCode == 401 || response.statusCode == 403) {
      await response.drain<void>();
      throw ProviderNotAuthenticatedException(
        'Claude sign-in was rejected. Run `claude` and sign in again, then refresh.',
      );
    }
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != 200 || body.length > 1024 * 1024) {
      throw const FormatException('Claude model list failed');
    }
    return parseClaudeApiModels(
      jsonDecode(body),
      idPrefix,
      excludeIds: excludeIds,
    );
  } finally {
    client.close(force: true);
  }
}

/// Headers that authenticate a Models API call, or null when not signed in.
Future<Map<String, String>?> readClaudeApiCredential(
  Map<String, String> environment,
) async {
  final key = environment['ANTHROPIC_API_KEY'];
  if (key != null && key.isNotEmpty) return {'x-api-key': key};
  String? raw;
  if (Platform.isMacOS) {
    final result = await Process.run('security', [
      'find-generic-password',
      '-s',
      'Claude Code-credentials',
      '-w',
    ]);
    if (result.exitCode == 0) raw = '${result.stdout}'.trim();
  }
  if (raw == null || raw.isEmpty) {
    final home = environment['HOME'] ?? environment['USERPROFILE'];
    if (home != null) {
      final file = File('$home/.claude/.credentials.json');
      if (await file.exists()) raw = await file.readAsString();
    }
  }
  if (raw == null || raw.isEmpty) return null;
  try {
    final oauth = (jsonDecode(raw) as Map)['claudeAiOauth'];
    final token = oauth is Map ? oauth['accessToken'] : null;
    if (token is! String || token.isEmpty) return null;
    return {
      'authorization': 'Bearer $token',
      'anthropic-beta': 'oauth-2025-04-20',
    };
  } on Object {
    return null;
  }
}

/// Maps a Models API response. `id` is the execution value and `display_name`
/// the shown name. Efforts come from `capabilities.effort`; retired models
/// are not selectable.
List<DiscoveredModel> parseClaudeApiModels(
  Object? response,
  String idPrefix, {
  Set<String> excludeIds = const {},
}) {
  final list = response is Map ? response['data'] : null;
  if (list is! List)
    throw const FormatException('Claude model list is invalid');
  const order = ['low', 'medium', 'high', 'xhigh', 'max'];
  final models = <DiscoveredModel>[];
  final ids = <String>{};
  for (final raw in list) {
    if (raw is! Map) throw const FormatException('Claude model is invalid');
    final id = raw['id'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(id)) {
      throw const FormatException('Claude model ID is invalid');
    }
    if (excludeIds.contains(id)) continue;
    if (idPrefix.isNotEmpty && !id.startsWith(idPrefix)) continue;
    if (raw['lifecycle'] == 'retired') continue;
    if (!ids.add(id)) continue;
    final capability = raw['capabilities'];
    final effort = capability is Map ? capability['effort'] : null;
    final efforts = [
      if (effort is Map && effort['supported'] == true)
        for (final level in order)
          if (effort[level] is Map && effort[level]['supported'] == true) level,
    ];
    final name = raw['display_name'];
    models.add(
      DiscoveredModel(
        id: id,
        name: name is String && name.trim().isNotEmpty
            ? name.trim()
            : readableModelName(id),
        supportedReasoningEfforts: efforts,
      ),
    );
    if (models.length > 128) {
      throw const FormatException('Model catalog exceeds limit');
    }
  }
  return models;
}

Future<void> _sendAppServerRequest(IOSink sink, Map<String, Object?> request) {
  sink.writeln(jsonEncode(request));
  return sink.flush();
}

Future<Map<String, Object?>> _readAppServerResponse(
  StreamIterator<String> lines,
  int requestId,
  DateTime deadline,
) async {
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Codex app-server discovery timed out');
    }
    if (!await lines.moveNext().timeout(remaining)) {
      throw const FormatException('Codex app-server closed before responding');
    }
    final line = lines.current;
    if (utf8.encode(line).length > 64 * 1024) {
      throw const FormatException('Codex app-server response exceeds limit');
    }
    // Servers may log plain text on stdout; only JSON-RPC objects count.
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final value = Map<String, Object?>.from(decoded);
    if (value['id'] != requestId) continue;
    if (value['error'] != null) {
      throw FormatException(
        'Codex app-server request failed: ${value['error']}',
      );
    }
    final result = value['result'];
    if (result is! Map) {
      throw const FormatException('Codex app-server result is invalid');
    }
    return Map<String, Object?>.from(result);
  }
}

List<DiscoveredModel> parseCodexAppServerModels(
  Map<String, Object?> response,
  String idPrefix,
) {
  final data = response['data'];
  if (data is! List) {
    throw const FormatException('Codex app-server model list is invalid');
  }
  final models = <DiscoveredModel>[];
  final ids = <String>{};
  for (final raw in data) {
    if (raw is! Map) {
      throw const FormatException('Codex app-server model entry is invalid');
    }
    final value = Map<String, Object?>.from(raw);
    if (value['hidden'] == true) continue;
    final id = (value['id'] ?? value['model']);
    if (id is! String || id.isEmpty) {
      throw const FormatException('Codex app-server model ID is invalid');
    }
    if (idPrefix.isNotEmpty && !id.startsWith(idPrefix)) continue;
    if (!ids.add(id)) {
      throw const FormatException('Duplicate model ID');
    }
    final name =
        value['displayName'] is String &&
            (value['displayName'] as String).isNotEmpty
        ? value['displayName'] as String
        : id;
    final efforts = <String>[];
    final rawEfforts = value['supportedReasoningEfforts'];
    if (rawEfforts is List) {
      for (final rawEffort in rawEfforts) {
        if (rawEffort is! Map || rawEffort['reasoningEffort'] is! String) {
          throw const FormatException(
            'Codex app-server reasoning effort is invalid',
          );
        }
        final effort = rawEffort['reasoningEffort'] as String;
        if (efforts.contains(effort))
          throw const FormatException('Duplicate reasoning effort');
        efforts.add(effort);
      }
    } else if (rawEfforts != null) {
      throw const FormatException(
        'Codex app-server reasoning efforts are invalid',
      );
    }
    final defaultEffort = value['defaultReasoningEffort'];
    if (defaultEffort != null &&
        (defaultEffort is! String || !efforts.contains(defaultEffort))) {
      throw const FormatException(
        'Codex app-server default reasoning effort is invalid',
      );
    }
    models.add(
      DiscoveredModel(
        id: id,
        nativeId: value['model'] == null
            ? id
            : value['model'] is String
            ? value['model'] as String
            : throw const FormatException('Codex native model ID is invalid'),
        name: name,
        supportedReasoningEfforts: efforts,
        defaultReasoningEffort: defaultEffort as String?,
      ),
    );
    if (models.length > 128) {
      throw const FormatException('Model catalog exceeds limit');
    }
  }
  return models;
}

class ModelDiscoveryCache {
  ModelDiscoveryCache(String statePath)
    : file = File('$statePath/model-catalog.json');
  final File file;
  Future<DiscoveredModelCatalog?> load(String digest, String version) async {
    try {
      if (await file.length() > 128 * 1024) return null;
      final catalog = DiscoveredModelCatalog.fromJson(
        Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map),
      );
      return catalog.profileDigest == digest &&
              catalog.providerToolVersion == version
          ? catalog
          : null;
    } on Object {
      return null;
    }
  }

  /// The cached catalog for this Profile regardless of the CLI version it was
  /// discovered with. Used by execution, which does not run the CLI just to
  /// re-check its version: Workspace readiness owns that check.
  Future<DiscoveredModelCatalog?> loadForProfile(String digest) async {
    try {
      if (await file.length() > 128 * 1024) return null;
      final catalog = DiscoveredModelCatalog.fromJson(
        Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map),
      );
      return catalog.profileDigest == digest ? catalog : null;
    } on Object {
      return null;
    }
  }

  Future<void> save(DiscoveredModelCatalog catalog) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(jsonEncode(catalog.toJson()), flush: true);
    await temp.rename(file.path);
  }
}

/// Intersects signed exact mappings with the current native catalog.
List<DiscoveredModel> normalizeCombinedModels(
  List<DiscoveredModel> models,
  Object? mapping,
  String version, {
  Object? effortVariants,
}) {
  final families = parseModelSelectionMapping(mapping);
  if (families.isEmpty) {
    return effortVariants is Map
        ? deriveEffortVariantModels(models, effortVariants)
        : models;
  }
  final native = {for (final model in models) model.nativeId: model};
  if (native.length != models.length)
    throw const FormatException('Duplicate native model ID');
  final consumed = <String>{};
  final result = <DiscoveredModel>[];
  for (final family in families) {
    final variants = family.variants
        .where((v) => v.supports(version) && native.containsKey(v.nativeId))
        .toList();
    if (variants.isEmpty) continue;
    consumed.addAll(variants.map((v) => v.nativeId));
    final efforts = variants.map((v) => v.effort).toList();
    result.add(
      DiscoveredModel(
        id: family.id,
        name: family.name,
        selectionMode: 'combined',
        supportedReasoningEfforts: efforts,
        defaultReasoningEffort: efforts.contains(family.defaultEffort)
            ? family.defaultEffort
            : null,
      ),
    );
  }
  result.addAll(
    models
        .where((m) => !consumed.contains(m.nativeId))
        .map(
          (m) => DiscoveredModel(
            id: m.id,
            name: m.name,
            nativeId: m.nativeId,
            status: m.status,
            selectionMode: 'combined',
          ),
        ),
  );
  if (result.map((m) => m.id).toSet().length != result.length)
    throw const FormatException('Logical model ID collision');
  return result;
}

const _effortRank = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

/// Reads the efforts a CLI lists when it rejects an invalid effort for one
/// model, for example Grok Build's `unknown effort level 'x'; use one of:
/// xhigh, high, medium, low`. Returns them lowest first; an empty list when
/// the CLI named no efforts (the model is not offered an effort choice).
List<String> parseUseOneOfEfforts(String output) {
  if (utf8.encode(output).length > 64 * 1024) return const [];
  final match = RegExp(
    r'use one of:\s*([A-Za-z0-9._:-]+(?:\s*,\s*[A-Za-z0-9._:-]+)*)',
  ).firstMatch(output);
  if (match == null) return const [];
  final efforts = <String>[];
  for (final raw in match.group(1)!.split(',')) {
    final effort = raw.trim().toLowerCase();
    if (!_effortValue.hasMatch(effort) || efforts.contains(effort)) continue;
    efforts.add(effort);
    if (efforts.length == 16) break;
  }
  int rank(String effort) {
    final index = _effortRank.indexOf(effort);
    return index < 0 ? _effortRank.length : index;
  }

  return efforts..sort((a, b) => rank(a).compareTo(rank(b)));
}

final _labelEffort = RegExp(r'^(.+?)\s*\(([^()]+)\)$');
final _effortValue = RegExp(r'^[a-z0-9][a-z0-9._:-]{0,63}$');

/// Groups native models into one logical model per family using only what the
/// CLI printed: the label ends with the effort in parentheses (`Name (High)`)
/// and the native ID is `<family><separator><effort>`. No model or effort is
/// declared in the Profile; a line that does not follow this stays a plain
/// model with no effort choice.
List<DiscoveredModel> deriveEffortVariantModels(
  List<DiscoveredModel> models,
  Map<Object?, Object?> rule,
) {
  final separator = rule['separator'] as String;
  final names = <String, String>{};
  final efforts = <String, List<String>>{};
  final order = <String>[];
  final plain = <DiscoveredModel>[];
  for (final model in models) {
    final label = _labelEffort.firstMatch(model.name);
    final effort = label?.group(2)?.trim().toLowerCase();
    if (label == null ||
        effort == null ||
        !_effortValue.hasMatch(effort) ||
        !model.nativeId.endsWith('$separator$effort') ||
        model.nativeId.length == '$separator$effort'.length) {
      plain.add(model);
      continue;
    }
    final suffix = '$separator$effort';
    final family = model.nativeId.substring(
      0,
      model.nativeId.length - suffix.length,
    );
    if (!efforts.containsKey(family)) {
      order.add(family);
      efforts[family] = [];
      names[family] = label.group(1)!.trim();
    }
    if (efforts[family]!.contains(effort)) {
      throw const FormatException('Duplicate model effort');
    }
    efforts[family]!.add(effort);
  }
  int rank(String effort) {
    final index = _effortRank.indexOf(effort);
    return index < 0 ? _effortRank.length : index;
  }

  final result = <DiscoveredModel>[
    for (final family in order)
      DiscoveredModel(
        id: family,
        name: names[family]!,
        selectionMode: 'combined',
        supportedReasoningEfforts: [...efforts[family]!]
          ..sort((a, b) => rank(a).compareTo(rank(b))),
      ),
    for (final model in plain)
      DiscoveredModel(
        id: model.id,
        name: model.name,
        nativeId: model.nativeId,
        status: model.status,
        selectionMode: 'combined',
      ),
  ];
  if (result.map((m) => m.id).toSet().length != result.length) {
    throw const FormatException('Logical model ID collision');
  }
  return result;
}

/// Resolves only an advertised pair; missing defaults never choose a variant.
String resolveNativeSelection(
  DiscoveredModel model,
  String? effort,
  Object? mapping,
  String version, {
  Object? effortVariants,
}) {
  final family = parseModelSelectionMapping(
    mapping,
  ).where((m) => m.id == model.id).firstOrNull;
  if (family == null &&
      effortVariants is Map &&
      model.selectionMode == 'combined' &&
      model.supportedReasoningEfforts.isNotEmpty) {
    final selected = effort ?? model.defaultReasoningEffort;
    if (selected == null ||
        !model.supportedReasoningEfforts.contains(selected)) {
      throw const FormatException('Explicit supported effort required');
    }
    return '${model.id}${effortVariants['separator']}$selected';
  }
  if (family == null) return model.nativeId;
  final selected = effort ?? model.defaultReasoningEffort;
  if (selected == null || !model.supportedReasoningEfforts.contains(selected))
    throw const FormatException('Explicit supported effort required');
  final matches = family.variants
      .where((v) => v.supports(version) && v.effort == selected)
      .toList();
  if (matches.length != 1)
    throw const FormatException('Ambiguous native model selection');
  return matches.single.nativeId;
}
