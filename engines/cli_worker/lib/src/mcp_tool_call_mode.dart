import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'mcp_host.dart';
import 'mcp_tool_call_runner.dart';
import 'external_worker_process_host.dart';
import 'external_worker_process_limits.dart';

const mcpToolCallFlag = '--mcp-tool-call';

/// Internal, one-assignment Engine mode. The caller must independently admit
/// the Workspace, operation, consent and pins; this is not a management API.
Future<Map<String, Object?>> runMcpToolCall(
  Map<String, Object?> request, {
  ExternalWorkerProcessHost? pluginHost,
  Future<void>? cancel,
}) async {
  final host = McpHost(
    pluginHost:
        pluginHost ??
        ExternalWorkerProcessHost(
          supervisor: LimitedExternalWorkerSupervisor(),
        ),
  );
  Directory? data;
  var invocationStarted = false;
  try {
    final rawPins = request['toolPins'];
    final tool = request['tool'];
    final arguments = request['arguments'];
    final timeoutMs = request['timeoutMs'];
    if (rawPins is! Map ||
        rawPins.isEmpty ||
        rawPins.length > 128 ||
        tool is! String ||
        tool.isEmpty ||
        tool.length > 128 ||
        arguments is! Map ||
        timeoutMs is! int ||
        timeoutMs < 1 ||
        timeoutMs > 1800000) {
      throw const FormatException('Invalid call request');
    }
    final pins = <String, String>{};
    for (final entry in rawPins.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value as String)) {
        throw const FormatException('Invalid tool pins');
      }
      pins[entry.key as String] = entry.value as String;
    }
    if (!pins.containsKey(tool))
      throw const FormatException('Tool is not pinned');
    final remote = request['remote'];
    final local = request['server'];
    if ((remote is Map) == (local is Map)) {
      throw const FormatException('Exactly one target is required');
    }
    final McpServerSpec spec;
    if (remote is Map) {
      final endpoint = Uri.tryParse('${remote['endpoint']}');
      if (endpoint == null || !endpoint.hasAuthority) {
        throw const FormatException('Invalid endpoint');
      }
      final token = remote['bearerToken'];
      if (token != null && token is! String)
        throw const FormatException('Invalid token');
      spec = McpServerSpec(
        serverId: 'tool-call',
        workspaceId: 'engine',
        pins: ToolPins(pins),
        remote: McpRemote(
          endpoint: endpoint,
          bearerToken: token as String?,
          allowInsecureLoopback: remote['allowInsecureLoopback'] == true,
        ),
      );
    } else {
      final server = McpServerLaunch.fromJson(
        Map<String, Object?>.from(local as Map),
      );
      final sha = request['commandSha256'];
      final cwd = request['workingDirectory'];
      if (sha is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
          cwd is! String ||
          !Directory(cwd).isAbsolute) {
        throw const FormatException('Invalid local target');
      }
      data = await Directory.systemTemp.createTemp('syntila-mcp-call-');
      spec = McpServerSpec(
        serverId: server.name,
        workspaceId: 'engine',
        pins: ToolPins(pins),
        launch: ExternalWorkerLaunch(
          executable: server.command!,
          arguments: server.arguments,
          artifactSha256: sha,
          pluginId: server.name,
          version: '0',
          dataDirectory: data.path,
          workingDirectory: cwd,
          environment: {
            ...ExternalWorkerProcessHost.buildEnvironment(),
            ...server.environment,
          },
          hostVersion: '0',
        ),
      );
    }
    invocationStarted = true;
    final outcome = await McpToolCallRunner(host).call(
      spec,
      tool,
      Map<String, Object?>.from(arguments),
      timeout: Duration(milliseconds: timeoutMs),
      cancel: cancel,
    );
    return {
      'state': outcome.state.name,
      'code': outcome.code,
      if (outcome.result != null) 'result': outcome.result,
    };
  } on Object {
    return invocationStarted
        ? {'state': 'unknown', 'code': 'outcome_unknown'}
        : {'state': 'rejected', 'code': 'invalid_request'};
  } finally {
    await host.closeAll();
    try {
      await data?.delete(recursive: true);
    } on FileSystemException {
      // Best effort for the Engine-owned temporary directory.
    }
  }
}

Future<void> runMcpToolCallMode() async {
  final input = _ToolCallInput();
  Map<String, Object?>? request;
  Map<String, Object?> result;
  try {
    final line = await input.request.timeout(const Duration(seconds: 10));
    request = Map<String, Object?>.from(jsonDecode(line) as Map);
  } on Object {
    request = null;
  }
  if (request == null) {
    result = {'state': 'rejected', 'code': 'invalid_request'};
  } else {
    try {
      result = await runMcpToolCall(request, cancel: input.cancelled);
    } on Object {
      // Cleanup can fail after dispatch, so never claim a safe rejection.
      result = {'state': 'unknown', 'code': 'outcome_unknown'};
    }
  }
  await input.close();
  stdout.writeln(jsonEncode(result));
  await stdout.flush();
}

/// One request followed optionally by a cancellation frame. Closing stdin is
/// not cancellation: callers may close it immediately after the request.
class _ToolCallInput {
  _ToolCallInput() {
    _subscription = stdin.listen(
      _accept,
      onError: (Object error) {
        if (!_request.isCompleted) _request.completeError(error);
      },
      onDone: () {
        if (!_request.isCompleted) {
          _request.completeError(const FormatException('Missing request'));
        }
      },
    );
  }

  final _request = Completer<String>();
  final _cancelled = Completer<void>();
  final _bytes = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> _subscription;
  bool _finished = false;

  Future<String> get request => _request.future;
  Future<void> get cancelled => _cancelled.future;

  void _accept(List<int> chunk) {
    for (final byte in chunk) {
      if (_finished) return;
      if (byte == 10) {
        try {
          final line = utf8.decode(_bytes.takeBytes());
          if (!_request.isCompleted) {
            _request.complete(line);
          } else {
            final frame = jsonDecode(line);
            if (frame is Map && frame['cancel'] == true) {
              _cancelled.complete();
            }
            _finished = true;
          }
        } on Object catch (error, stack) {
          if (!_request.isCompleted) _request.completeError(error, stack);
          _finished = true;
        }
      } else {
        _bytes.addByte(byte);
        if (_bytes.length > McpLimits.maxFrameBytes) {
          if (!_request.isCompleted) {
            _request.completeError(const FormatException('Request too large'));
          }
          _finished = true;
        }
      }
    }
  }

  Future<void> close() => _subscription.cancel();
}
