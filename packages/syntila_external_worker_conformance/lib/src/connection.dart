import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart';

/// A raw, line-oriented channel to one running plugin process. The suite is
/// written against this so the same cases run in author tooling (a direct
/// process) and inside the Engine's plugin host.
abstract class ExternalWorkerConnection {
  /// Writes one line (a trailing newline is added).
  Future<void> send(String line);

  /// The next stdout line, or null on timeout. Throws [ExternalWorkerExited] once the
  /// process closed stdout and every buffered line was consumed.
  Future<String?> readLine(Duration timeout);

  /// Closes the plugin's stdin (end of input).
  Future<void> closeInput();

  /// Exit status, or null if it did not exit within [timeout].
  Future<int?> waitForExit(Duration timeout);

  /// Force-terminates the process tree.
  Future<void> kill();
}

class ExternalWorkerExited implements Exception {
  const ExternalWorkerExited();
}

/// Starts a fresh plugin process for each case.
abstract class ConformanceLauncher {
  Future<ExternalWorkerConnection> launch();
}

/// Splits stdout bytes into lines with a hard per-frame bound and an
/// awaitable queue. Shared by connection implementations.
class LineQueue {
  final Queue<String> _lines = Queue<String>();
  final BytesBuilder _partial = BytesBuilder(copy: false);
  Completer<void>? _waiter;
  bool _closed = false;

  /// True if a line exceeded the frame limit.
  bool oversize = false;

  void add(List<int> chunk) {
    for (var i = 0; i < chunk.length; i++) {
      final byte = chunk[i];
      if (byte == 0x0A) {
        _lines.add(utf8.decode(_partial.takeBytes(), allowMalformed: true));
        _wake();
      } else if (_partial.length < ExternalWorkerLimits.maxFrameBytes + 1) {
        _partial.addByte(byte);
      } else {
        oversize = true;
      }
    }
  }

  void close() {
    _closed = true;
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<String?> next(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_lines.isNotEmpty) return _lines.removeFirst();
      if (_closed) throw const ExternalWorkerExited();
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      final waiter = _waiter ??= Completer<void>();
      try {
        await waiter.future.timeout(remaining);
      } on TimeoutException {
        return null;
      }
    }
  }
}
