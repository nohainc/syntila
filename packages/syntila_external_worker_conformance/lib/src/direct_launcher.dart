import 'dart:async';
import 'dart:io';

import 'connection.dart';

/// Author tooling only: starts the plugin directly with `Process.start`. It is
/// not the `syntila` CLI, applies none of the Engine's limits or isolation and
/// can register nothing. Production runs go Service → Engine → plugin.
class DirectProcessLauncher implements ConformanceLauncher {
  DirectProcessLauncher({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;

  @override
  Future<ExternalWorkerConnection> launch() async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    return DirectProcessConnection(process);
  }
}

class DirectProcessConnection implements ExternalWorkerConnection {
  DirectProcessConnection(this._process) {
    _subscription = _process.stdout.listen(
      _queue.add,
      onDone: _queue.close,
      onError: (_) => _queue.close(),
    );
    _process.stderr.drain<void>().catchError((_) {});
    unawaited(_process.stdin.done.catchError((_) {}));
  }

  final Process _process;
  final LineQueue _queue = LineQueue();
  late final StreamSubscription<List<int>> _subscription;

  @override
  Future<void> send(String line) async {
    try {
      _process.stdin.writeln(line);
      await _process.stdin.flush();
    } on Object {
      // A closed pipe is observed through the exit.
    }
  }

  @override
  Future<String?> readLine(Duration timeout) => _queue.next(timeout);

  @override
  Future<void> closeInput() async {
    try {
      await _process.stdin.close();
    } on Object {
      // Already closed.
    }
  }

  @override
  Future<int?> waitForExit(Duration timeout) async {
    try {
      return await _process.exitCode.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<void> kill() async {
    _process.kill(ProcessSignal.sigkill);
    await _subscription.cancel();
  }
}
