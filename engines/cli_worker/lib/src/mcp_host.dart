import 'dart:async';
import 'dart:collection';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_plugin_conformance/syntila_plugin_conformance.dart'
    show PluginConnection, PluginExited;

import 'plugin_host.dart';

/// Adapts a supervised [PluginConnection] (digest-checked, limited, process
/// tree cleanup) to the MCP client's line transport. Frames are capped at the
/// connection's 1 MiB line limit, which is above the 1 MiB result limit.
class PluginConnectionTransport implements McpTransport {
  PluginConnectionTransport(this._connection) {
    unawaited(_pump());
  }

  final PluginConnection _connection;
  final _controller = StreamController<String>();
  var _closed = false;

  @override
  Stream<String> get lines => _controller.stream;

  // The connection flushes stdin per send and swallows errors, so overlapping
  // sends can be silently dropped. Serialise them.
  Future<void> _sendChain = Future<void>.value();

  @override
  void send(String line) {
    _sendChain = _sendChain.then((_) => _connection.send(line));
  }

  Future<void> _pump() async {
    try {
      while (!_closed) {
        final line = await _connection.readLine(const Duration(seconds: 1));
        if (line != null && !_controller.isClosed) _controller.add(line);
      }
    } on PluginExited {
      // Stream end is observed by the client as a crash.
    } finally {
      if (!_controller.isClosed) await _controller.close();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _connection.kill();
  }
}

/// Everything the Service resolved about one MCP server.
class McpServerSpec {
  McpServerSpec({
    required this.serverId,
    required this.workspaceId,
    required this.launch,
    this.requireWorkerProfile = false,
    this.pins,
    this.maxConcurrent = 1,
  });

  final String serverId;
  final String workspaceId;
  final PluginLaunch launch;

  /// Worker-class servers must advertise `_meta["syntila.worker"]`.
  final bool requireWorkerProfile;

  /// Tool hashes recorded at consent. Null means "not yet consented": no call
  /// is allowed (listing is).
  final ToolPins? pins;
  final int maxConcurrent;

  String get key =>
      '$workspaceId|$serverId|${launch.pluginId}@${launch.version}|${launch.artifactSha256}';
}

class _Entry {
  _Entry(this.spec);

  /// Latest spec for this key: consent (pins) may change while the warm
  /// process stays the same.
  McpServerSpec spec;
  McpClient? client;
  PluginConnection? connection;
  List<Map<String, Object?>> tools = const [];
  var busy = 0;
  var failures = 0;
  DateTime? lastFailure;
  Timer? idle;
  final waiters = Queue<Completer<void>>();
}

/// Warm pool of MCP client sessions (`MCP_HOST_V1.md`). One session per
/// `(workspace, server, digest)`; servers are reused until idle for
/// [idleTtl], restarted with backoff when they crash.
class McpHost {
  McpHost({
    PluginHost? pluginHost,
    this.idleTtl = McpLimits.idleServerTtl,
    this.maxRestartDelay = const Duration(seconds: 5),
  }) : _plugins = pluginHost ?? PluginHost();

  final PluginHost _plugins;
  final Duration idleTtl;
  final Duration maxRestartDelay;
  final _entries = <String, _Entry>{};

  /// Number of live warm sessions (for tests and diagnostics).
  int get warmSessions => _entries.values
      .where((e) => e.client != null && !e.client!.isClosed)
      .length;

  Future<McpLease> acquire(McpServerSpec spec) async {
    final entry = _entries.putIfAbsent(spec.key, () => _Entry(spec));
    entry.spec = spec;
    entry.idle?.cancel();
    while (entry.busy >= spec.maxConcurrent) {
      final w = Completer<void>();
      entry.waiters.add(w);
      await w.future;
    }
    entry.busy++;
    try {
      await _ensureConnected(entry);
    } on Object {
      _release(entry);
      rethrow;
    }
    return McpLease._(this, entry);
  }

  Future<void> closeAll() async {
    for (final e in _entries.values) {
      e.idle?.cancel();
      await _disconnect(e);
    }
    _entries.clear();
  }

  Future<void> _ensureConnected(_Entry e) async {
    final existing = e.client;
    if (existing != null && !existing.isClosed) return;
    // Restart backoff after consecutive failures: 200ms * 2^n, capped.
    if (e.failures > 0 && e.lastFailure != null) {
      final delay = Duration(
        milliseconds: (200 * (1 << (e.failures - 1).clamp(0, 10))).clamp(
          0,
          maxRestartDelay.inMilliseconds,
        ),
      );
      final wait = delay - DateTime.now().difference(e.lastFailure!);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    try {
      final connection = await _plugins.connect(e.spec.launch);
      final client = McpClient(PluginConnectionTransport(connection));
      e.connection = connection;
      e.client = client;
      await client.initialize();
      if (e.spec.requireWorkerProfile &&
          client.initializeMeta['syntila.worker'] != '1') {
        throw McpException(
          McpFailure.protocolViolation,
          'server does not advertise the Syntila Worker profile',
        );
      }
      e.tools = await client.listTools();
      e.failures = 0;
    } on Object {
      e.failures++;
      e.lastFailure = DateTime.now();
      await _disconnect(e);
      rethrow;
    }
  }

  Future<void> _disconnect(_Entry e) async {
    final client = e.client;
    e.client = null;
    e.connection = null;
    try {
      await client?.close();
    } on Object {
      // Already gone.
    }
  }

  void _release(_Entry e) {
    e.busy--;
    if (e.waiters.isNotEmpty) {
      e.waiters.removeFirst().complete();
      return;
    }
    if (e.busy == 0) {
      e.idle?.cancel();
      e.idle = Timer(idleTtl, () => unawaited(_disconnect(e)));
    }
  }
}

/// Exclusive use of one warm session. Always [release] it.
class McpLease {
  McpLease._(this._host, this._entry);

  final McpHost _host;
  final _Entry _entry;
  var _released = false;

  McpClient get client => _entry.client!;
  List<Map<String, Object?>> get tools => _entry.tools;

  /// Pin diff against the server's current definitions (re-lists when the
  /// server signalled `list_changed`).
  Future<ToolPinDiff?> pinDiff() async {
    final pins = _entry.spec.pins;
    if (pins == null) return null;
    if (client.toolsListChanged) _entry.tools = await client.listTools();
    return pins.diff(_entry.tools);
  }

  /// Calls a tool only if it was consented and is unchanged.
  Future<McpCall> callTool(
    String name,
    Map<String, Object?> arguments, {
    McpProgressCallback? onProgress,
    Duration? timeout,
  }) async {
    final pins = _entry.spec.pins;
    if (client.toolsListChanged) _entry.tools = await client.listTools();
    if (pins == null || !pins.allows(name, _entry.tools)) {
      throw McpException(
        McpFailure.definitionChanged,
        'tool "$name" is not consented or its definition changed',
      );
    }
    return client.callTool(
      name,
      arguments,
      onProgress: onProgress,
      timeout: timeout,
    );
  }

  void release() {
    if (_released) return;
    _released = true;
    _host._release(_entry);
  }

  /// Kills the server process (cancelled, timed-out or misbehaving run) and
  /// releases the lease. The next acquire starts a fresh process.
  Future<void> discard() async {
    if (_released) return;
    await _host._disconnect(_entry);
    release();
  }
}
