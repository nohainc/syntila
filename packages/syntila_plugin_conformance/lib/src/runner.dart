import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

import 'connection.dart';
import 'report.dart';

class ConformanceFailure implements Exception {
  const ConformanceFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Runs the protocol conformance cases (`suiteVersion 1.1.0`) against a
/// plugin. Each case starts a fresh process via the [launcher].
///
/// This checks observable protocol behavior only. It cannot tell whether a
/// plugin is safe, truthful about its declared access, or malicious.
class ConformanceRunner {
  ConformanceRunner({
    required this.launcher,
    required this.expectedPluginId,
    required this.expectedVersion,
    this.declaresResume = false,
    this.declaredCapabilities,
    this.caseTimeout = const Duration(seconds: 90),
    this.terminalTimeout = const Duration(seconds: 60),
  });

  final ConformanceLauncher launcher;
  final String expectedPluginId;
  final String expectedVersion;
  final bool declaresResume;

  /// Capability keys the manifest declared; null skips the subset check.
  final Map<String, Object?>? declaredCapabilities;
  final Duration caseTimeout;

  /// How long an execute may take to produce its terminal frame.
  final Duration terminalTimeout;

  late final Directory _work = Directory.systemTemp.createTempSync(
    'plugin-conformance-work',
  );
  late final Directory _data = Directory.systemTemp.createTempSync(
    'plugin-conformance-data',
  );

  late final Map<String, Future<void> Function(_Wire)> _cases = {
    'handshake.identity': _handshakeIdentity,
    'handshake.version_negotiation': _versionNegotiation,
    'handshake.unsupported_protocol': _unsupportedProtocol,
    'probe.passive': _probePassive,
    if (declaredCapabilities?['modelDiscovery'] == true)
      'models.list': _listModels,
    'execute.single_terminal_frame': _singleTerminal,
    'execute.id_correlation': _idCorrelation,
    'execute.progress_ordering': _progressOrdering,
    'execute.large_prompt': _largePrompt,
    'frame.unknown_type_tolerated': _unknownType,
    'frame.unknown_field_tolerated': _unknownField,
    'frame.malformed_input_survives': _malformedInput,
    'frame.crlf_tolerated': _crlf,
    'heartbeat.pong': _pong,
    'cancel.within_grace': _cancelWithinGrace,
    'cancel.idempotent': _cancelIdempotent,
    'cancel.after_terminal_ignored': _cancelAfterTerminal,
    'shutdown.within_grace': _shutdown,
    'stdin.eof_exits': _stdinEof,
    'manifest.capabilities_subset': _capabilitiesSubset,
    'resume.roundtrip': _resumeRoundtrip,
    'resume.unknown_key_session_not_found': _resumeUnknownKey,
  };

  List<String> get caseIds => List.unmodifiable(_cases.keys);

  Future<ConformanceReport> run({
    void Function(ConformanceCase result)? onCase,
  }) async {
    final results = <ConformanceCase>[];
    try {
      for (final entry in _cases.entries) {
        final result = await _runCase(entry.key, entry.value);
        results.add(result);
        onCase?.call(result);
      }
    } finally {
      for (final dir in [_work, _data]) {
        try {
          dir.deleteSync(recursive: true);
        } on Object {
          // Temporary files only.
        }
      }
    }
    return ConformanceReport(
      protocol: PluginProtocolLimits.protocolVersion,
      cases: results,
    );
  }

  Future<ConformanceCase> _runCase(
    String id,
    Future<void> Function(_Wire) body,
  ) async {
    final timer = Stopwatch()..start();
    PluginConnection? connection;
    try {
      if (id.startsWith('resume.') && !declaresResume) {
        return ConformanceCase(
          id: id,
          status: ConformanceStatus.skipped,
          milliseconds: 0,
          detail: 'The plugin does not declare session resume.',
        );
      }
      if (id == 'manifest.capabilities_subset' &&
          declaredCapabilities == null) {
        return ConformanceCase(
          id: id,
          status: ConformanceStatus.skipped,
          milliseconds: 0,
          detail: 'No manifest capabilities were supplied.',
        );
      }
      connection = await launcher.launch();
      await body(_Wire(connection, this)).timeout(caseTimeout);
      return ConformanceCase(
        id: id,
        status: ConformanceStatus.passed,
        milliseconds: timer.elapsedMilliseconds,
      );
    } on ConformanceFailure catch (failure) {
      return ConformanceCase(
        id: id,
        status: ConformanceStatus.failed,
        milliseconds: timer.elapsedMilliseconds,
        detail: failure.message,
      );
    } on TimeoutException {
      return ConformanceCase(
        id: id,
        status: ConformanceStatus.failed,
        milliseconds: timer.elapsedMilliseconds,
        detail: 'The case did not finish within $caseTimeout.',
      );
    } on PluginExited {
      return ConformanceCase(
        id: id,
        status: ConformanceStatus.failed,
        milliseconds: timer.elapsedMilliseconds,
        detail: 'The plugin exited unexpectedly.',
      );
    } on Object catch (error) {
      return ConformanceCase(
        id: id,
        status: ConformanceStatus.failed,
        milliseconds: timer.elapsedMilliseconds,
        detail: 'The plugin could not be exercised: ${error.runtimeType}',
      );
    } finally {
      await connection?.kill();
    }
  }

  // ---- handshake -----------------------------------------------------------

  Future<void> _handshakeIdentity(_Wire w) async {
    final result = await w.handshake();
    final plugin = Map<String, Object?>.from(result.json['plugin'] as Map);
    if (plugin['id'] != expectedPluginId ||
        plugin['version'] != expectedVersion) {
      throw ConformanceFailure(
        'hello.result identifies ${plugin['id']}@${plugin['version']}, '
        'expected $expectedPluginId@$expectedVersion.',
      );
    }
  }

  Future<void> _versionNegotiation(_Wire w) async {
    final result = await w.handshake(supported: const ['1.0', '1.99', '9.9']);
    final chosen = result.json['protocol'];
    if (chosen is! String ||
        !const ['1.0', '1.99', '9.9'].contains(chosen) ||
        !chosen.startsWith('1.')) {
      throw ConformanceFailure('Selected protocol "$chosen" is not offered.');
    }
  }

  Future<void> _unsupportedProtocol(_Wire w) async {
    await w.sendRaw(
      jsonEncode({
        'type': 'hello',
        'id': 'h1',
        'protocol': {
          'supported': ['2.0'],
          'preferred': '2.0',
        },
        'host': {'name': 'conformance', 'version': '1.0.0'},
        'dataDir': _data.path,
      }),
    );
    try {
      final frame = await w.read(PluginProtocolLimits.handshakeTimeout);
      if (frame.type == 'error' &&
          frame.json['code'] == 'unsupported_protocol') {
        return;
      }
      throw ConformanceFailure(
        'Expected an unsupported_protocol error, got ${frame.type}.',
      );
    } on PluginExited {
      return; // Exiting is the other permitted response.
    }
  }

  // ---- readiness -----------------------------------------------------------

  Future<void> _probePassive(_Wire w) async {
    await w.handshake();
    await w.sendFrame(PluginFrame.probe(id: 'p1', mode: 'passive'));
    final result = await w.readUntilType(
      'probe.result',
      PluginProtocolLimits.maxProbeTimeoutMs == 0
          ? const Duration(seconds: 30)
          : const Duration(
              milliseconds: PluginProtocolLimits.maxProbeTimeoutMs),
    );
    if (result.id != 'p1') {
      throw ConformanceFailure('probe.result id ${result.id} is not p1.');
    }
  }

  // ---- execute -------------------------------------------------------------

  Future<List<PluginFrame>> _execute(
    _Wire w, {
    String prompt = 'conformance check',
    Map<String, Object?>? session,
    bool read = true,
  }) async {
    await w.sendFrame(
      PluginFrame.execute(
        id: 'e1',
        deadlineMs: 60000,
        prompt: prompt,
        workingDirectory: _work.path,
        access: 'read_write',
        sessionKey: session?['key'] as String?,
        sessionMode: (session?['mode'] as String?) ?? 'new',
      ),
    );
    if (!read) return const [];
    return w.readUntilTerminal(terminalTimeout);
  }

  Future<void> _singleTerminal(_Wire w) async {
    await w.handshake();
    await _execute(w);
    await w.expectNoMore(
      (f) => f.isTerminal && f.id == 'e1',
      'a second terminal frame for one execute',
    );
  }

  Future<void> _idCorrelation(_Wire w) async {
    await w.handshake();
    final frames = await _execute(w);
    for (final frame in frames) {
      if (frame.id != 'e1') {
        throw ConformanceFailure(
          '${frame.type} frame carries id ${frame.id}, expected e1.',
        );
      }
    }
  }

  Future<void> _progressOrdering(_Wire w) async {
    await w.handshake();
    await _execute(w);
    await w.expectNoMore(
      (f) => f.type == 'progress' || f.type == 'activity',
      'progress or activity after the terminal frame',
    );
  }

  Future<void> _largePrompt(_Wire w) async {
    await w.handshake();
    final prompt = 'a' * (PluginProtocolLimits.maxPromptBytes - 4096);
    final frames = await _execute(w, prompt: prompt);
    if (frames.isEmpty || !frames.last.isTerminal) {
      throw const ConformanceFailure('No terminal frame for a large prompt.');
    }
  }

  // ---- framing -------------------------------------------------------------

  Future<void> _unknownType(_Wire w) async {
    await w.handshake();
    await w.sendRaw(jsonEncode({'type': 'future.thing', 'id': 'x1'}));
    await w.sendFrame(PluginFrame.probe(id: 'p1', mode: 'passive'));
    await w.readUntilType('probe.result', const Duration(seconds: 30));
  }

  Future<void> _unknownField(_Wire w) async {
    await w.handshake(extraField: true);
  }

  Future<void> _malformedInput(_Wire w) async {
    await w.handshake();
    await w.sendRaw('this is not json');
    await w.sendFrame(PluginFrame.probe(id: 'p1', mode: 'passive'));
    await w.readUntilType('probe.result', const Duration(seconds: 30));
  }

  Future<void> _crlf(_Wire w) async {
    await w.handshake();
    await w.sendRaw(
      '${PluginFrame.probe(id: 'p1', mode: 'passive').encode()}\r',
    );
    await w.readUntilType('probe.result', const Duration(seconds: 30));
  }

  // ---- liveness and control --------------------------------------------------

  Future<void> _pong(_Wire w) async {
    await w.handshake();
    await w.sendFrame(PluginFrame.ping('n-1'));
    final frame = await w.readUntilType('pong', const Duration(seconds: 5));
    if (frame.json['nonce'] != 'n-1') {
      throw const ConformanceFailure('pong does not echo the ping nonce.');
    }
  }

  Future<void> _cancelWithinGrace(_Wire w) async {
    await w.handshake();
    await _execute(w, read: false);
    await w.sendFrame(PluginFrame.cancel(id: 'e1'));
    final frames = await w.readUntilTerminal(
      PluginProtocolLimits.cancelGrace + const Duration(seconds: 1),
    );
    final last = frames.last;
    if (last.type == 'error' &&
        last.json['code'] != 'cancelled' &&
        last.json['code'] != 'timeout') {
      throw ConformanceFailure(
        'Cancel ended with error ${last.json['code']}, expected cancelled.',
      );
    }
  }

  Future<void> _cancelIdempotent(_Wire w) async {
    await w.handshake();
    await _execute(w, read: false);
    await w.sendFrame(PluginFrame.cancel(id: 'e1'));
    await w.sendFrame(PluginFrame.cancel(id: 'e1'));
    await w.readUntilTerminal(
      PluginProtocolLimits.cancelGrace + const Duration(seconds: 1),
    );
    await w.expectNoMore(
      (f) => f.isTerminal && f.id == 'e1',
      'a second terminal frame after a repeated cancel',
    );
  }

  Future<void> _cancelAfterTerminal(_Wire w) async {
    await w.handshake();
    await _execute(w);
    await w.sendFrame(PluginFrame.cancel(id: 'e1'));
    await w.expectNoMore(
      (f) => f.isTerminal && f.id == 'e1',
      'a terminal frame after cancelling a finished execute',
    );
    await w.sendFrame(PluginFrame.probe(id: 'p1', mode: 'passive'));
    await w.readUntilType('probe.result', const Duration(seconds: 30));
  }

  Future<void> _shutdown(_Wire w) async {
    await w.handshake();
    await w.sendFrame(PluginFrame.shutdown());
    final code = await w.connection.waitForExit(
      PluginProtocolLimits.shutdownGrace + const Duration(milliseconds: 500),
    );
    if (code == null) {
      throw const ConformanceFailure('The plugin did not exit after shutdown.');
    }
    if (code != 0) {
      throw ConformanceFailure('The plugin exited with status $code.');
    }
  }

  Future<void> _stdinEof(_Wire w) async {
    await w.handshake();
    await w.connection.closeInput();
    final code = await w.connection.waitForExit(
      PluginProtocolLimits.shutdownGrace + const Duration(milliseconds: 500),
    );
    if (code == null) {
      throw const ConformanceFailure('The plugin ignored end of input.');
    }
  }

  // ---- manifest --------------------------------------------------------------

  Future<void> _listModels(_Wire w) async {
    final hello = await w.handshake(supported: const ['1.1', '1.0']);
    if (hello.json['protocol'] != '1.1')
      throw ConformanceFailure('Discovery requires protocol 1.1');
    await w.sendFrame(PluginFrame.listModels(id: 'models-1'));
    final result = await w.read(const Duration(seconds: 10));
    if (result.type != 'models.list.result' || result.id != 'models-1') {
      throw ConformanceFailure('Expected a correlated models.list.result');
    }
  }

  Future<void> _capabilitiesSubset(_Wire w) async {
    final result = await w.handshake();
    final announced = Map<String, Object?>.from(
      result.json['capabilities'] as Map,
    );
    for (final entry in announced.entries) {
      final enabled =
          entry.value == true || entry.value is String || entry.value is Map;
      if (enabled && entry.key != 'models' && entry.key != 'cancel') {
        if (!declaredCapabilities!.containsKey(entry.key) ||
            _canonical(declaredCapabilities![entry.key]) !=
                _canonical(entry.value)) {
          throw ConformanceFailure(
            'hello.result announces "${entry.key}", which the manifest does not declare.',
          );
        }
      }
    }
  }

  // ---- resume ----------------------------------------------------------------

  static final _sessionKey =
      'conformance-session-${DateTime.now().microsecondsSinceEpoch}';

  Future<void> _resumeRoundtrip(_Wire w) async {
    await w.handshake();
    final created = await _execute(
      w,
      session: {'key': _sessionKey, 'mode': 'new'},
    );
    _expectSession(created.last, 'created');
    // A new process proves the state outlives the process.
    final second = _Wire(await launcher.launch(), this);
    try {
      await second.handshake();
      final resumed = await _execute(
        second,
        session: {'key': _sessionKey, 'mode': 'resume'},
      );
      _expectSession(resumed.last, 'resumed');
    } finally {
      await second.connection.kill();
    }
  }

  Future<void> _resumeUnknownKey(_Wire w) async {
    await w.handshake();
    final frames = await _execute(
      w,
      session: {
        'key': 'conformance-unknown-${DateTime.now().microsecondsSinceEpoch}',
        'mode': 'resume',
      },
    );
    final last = frames.last;
    if (last.type != 'error' || last.json['code'] != 'session_not_found') {
      throw const ConformanceFailure(
        'Resuming an unknown session must fail with session_not_found.',
      );
    }
  }

  void _expectSession(PluginFrame terminal, String state) {
    if (terminal.type != 'result') {
      throw ConformanceFailure(
        'Expected a result, got ${terminal.type} (${terminal.json['code']}).',
      );
    }
    final session = terminal.json['session'];
    if (session is! Map || session['state'] != state) {
      throw ConformanceFailure('Expected session state "$state".');
    }
  }
}

/// Frame-level helper over one connection.
class _Wire {
  _Wire(this.connection, this.runner);

  final PluginConnection connection;
  final ConformanceRunner runner;

  Future<void> sendFrame(PluginFrame frame) => connection.send(frame.encode());
  Future<void> sendRaw(String line) => connection.send(line);

  /// Reads and validates the next frame. Anything on stdout that is not a
  /// protocol frame is a failure (stdout purity).
  Future<PluginFrame> read(Duration timeout) async {
    final line = await connection.readLine(timeout);
    if (line == null) {
      throw ConformanceFailure(
          'No frame arrived within ${timeout.inSeconds}s.');
    }
    final text = line.length > 80 ? '${line.substring(0, 80)}...' : line;
    try {
      return decodePluginFrame(line, PluginDirection.pluginToHost);
    } on PluginFrameException catch (error) {
      throw ConformanceFailure(
        'Non-protocol output on stdout ("$text"): ${error.message}',
      );
    }
  }

  Future<PluginFrame> handshake({
    List<String> supported = const ['1.0'],
    bool extraField = false,
  }) async {
    await sendRaw(
      jsonEncode({
        'type': 'hello',
        'id': 'h1',
        'protocol': {'supported': supported, 'preferred': supported.first},
        'host': {'name': 'conformance', 'version': '1.0.0'},
        'dataDir': runner._data.path,
        'limits': {
          'maxFrameBytes': PluginProtocolLimits.maxFrameBytes,
          'maxPromptBytes': PluginProtocolLimits.maxPromptBytes,
          'maxOutputBytes': PluginProtocolLimits.maxOutputBytes,
        },
        if (extraField) 'future': {'ignored': true},
      }),
    );
    final frame = await read(PluginProtocolLimits.handshakeTimeout);
    if (frame.type != 'hello.result' || frame.id != 'h1') {
      throw ConformanceFailure(
        'Expected hello.result, got ${frame.type} (${frame.json['code']}).',
      );
    }
    return frame;
  }

  /// Reads until a frame of [type] arrives, ignoring benign interleaved
  /// frames (progress, activity, errors about unsupported frames, pings).
  Future<PluginFrame> readUntilType(String type, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw ConformanceFailure(
            'No $type frame within ${timeout.inSeconds}s.');
      }
      final frame = await read(remaining);
      if (frame.type == type) return frame;
      if (frame.type == 'ping') {
        await sendFrame(PluginFrame.pong(frame.json['nonce'] as String));
      }
    }
  }

  /// Frames up to and including the terminal result or error for `e1`.
  Future<List<PluginFrame>> readUntilTerminal(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    final frames = <PluginFrame>[];
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw ConformanceFailure(
          'No terminal frame within ${timeout.inSeconds}s.',
        );
      }
      final frame = await read(remaining);
      if (frame.type == 'ping') {
        await sendFrame(PluginFrame.pong(frame.json['nonce'] as String));
        continue;
      }
      frames.add(frame);
      if (frame.isTerminal) return frames;
    }
  }

  /// Fails if a frame matching [bad] arrives during a short quiet period.
  Future<void> expectNoMore(
    bool Function(PluginFrame frame) bad,
    String what,
  ) async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 400));
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      final String? line;
      try {
        line = await connection.readLine(remaining);
      } on PluginExited {
        return;
      }
      if (line == null) return;
      final PluginFrame frame;
      try {
        frame = decodePluginFrame(line, PluginDirection.pluginToHost);
      } on PluginFrameException {
        throw const ConformanceFailure('Non-protocol output on stdout.');
      }
      if (bad(frame)) throw ConformanceFailure('The plugin sent $what.');
    }
  }
}

String _canonical(Object? value) {
  if (value is Map)
    return jsonEncode({
      for (final key in value.keys.cast<String>().toList()..sort())
        key: jsonDecode(_canonical(value[key]))
    });
  if (value is List)
    return jsonEncode(value.map((v) => jsonDecode(_canonical(v))).toList());
  return jsonEncode(value);
}
