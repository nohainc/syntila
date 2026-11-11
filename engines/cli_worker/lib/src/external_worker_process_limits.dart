import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';

import 'external_worker_windows_handles.dart';

/// Private child mode. Limits are applied before executing untrusted code.
Future<void> runLimitedExternalWorkerChild(List<String> args) async {
  if (args.length < 7 ||
      args[0] != '--plugin-child' ||
      args[1] != '--cpu-seconds' ||
      args[3] != '--open-files' ||
      args[5] != '--') {
    throw const FormatException('invalid plugin child arguments');
  }
  final cpu = int.tryParse(args[2]);
  final files = int.tryParse(args[4]);
  if (cpu == null ||
      cpu < 1 ||
      cpu > 3600 ||
      files == null ||
      files < 32 ||
      files > 256) {
    throw const FormatException('invalid plugin limits');
  }
  final target = args.sublist(6);
  if (!File(target.first).isAbsolute ||
      target.any((s) => s.contains('\u0000'))) {
    throw const FormatException('plugin executable must be absolute');
  }
  if (Platform.isWindows) {
    initializeWindowsProcessJob(
      maxMemoryBytes: 1024 * 1024 * 1024,
      maxProcesses: 66,
      cpuSeconds: cpu,
    );
    final child = await Process.start(
      target.first,
      target.sublist(1),
      mode: ProcessStartMode.inheritStdio,
      runInShell: false,
    );
    final handles = ExternalWorkerHandleMonitor(
      readCount: () => readWindowsExternalWorkerJobHandles(pid),
      onViolation: (reason) {
        stderr.writeln(reason);
        // Exiting closes the retained job handle and kills every job member.
        exit(70);
      },
    )..start();
    try {
      exitCode = await child.exitCode;
    } finally {
      handles.stop();
    }
    return;
  }
  if (!Platform.isMacOS && !Platform.isLinux) {
    throw UnsupportedError('plugin resource limits unavailable');
  }
  final native = _Posix();
  native.limit(0, cpu); // RLIMIT_CPU on Darwin and Linux
  native.limit(Platform.isMacOS ? 8 : 7, files); // RLIMIT_NOFILE
  native.limit(4, 0); // RLIMIT_CORE: no dumps of credentials
  native.exec(target);
}

class _Posix {
  final DynamicLibrary _lib = DynamicLibrary.process();
  late final _calloc = _lib
      .lookupFunction<
        Pointer<Void> Function(IntPtr, IntPtr),
        Pointer<Void> Function(int, int)
      >('calloc');
  late final _free = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  late final _get = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint64>),
        int Function(int, Pointer<Uint64>)
      >('getrlimit');
  late final _set = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint64>),
        int Function(int, Pointer<Uint64>)
      >('setrlimit');

  void limit(int resource, int value) {
    final limits = _calloc(2, 8).cast<Uint64>();
    if (limits == nullptr) throw StateError('limit allocation failed');
    try {
      if (_get(resource, limits) != 0) throw StateError('getrlimit failed');
      final hard = limits[1];
      // Linux RLIM_INFINITY is UINT64_MAX, represented as -1 by Dart's
      // 64-bit integer FFI read. Do not mistake that sentinel for a lower cap.
      limits[0] = hard < 0 || hard > value ? value : hard;
      limits[1] = limits[0];
      if (_set(resource, limits) != 0) throw StateError('setrlimit failed');
    } finally {
      _free(limits.cast());
    }
  }

  Never exec(List<String> args) {
    final allocated = <Pointer<Void>>[];
    final argv = _calloc(
      args.length + 1,
      sizeOf<IntPtr>(),
    ).cast<Pointer<Uint8>>();
    if (argv == nullptr) throw StateError('argv allocation failed');
    allocated.add(argv.cast());
    try {
      for (var i = 0; i < args.length; i++) {
        final bytes = utf8.encode(args[i]);
        final text = _calloc(bytes.length + 1, 1).cast<Uint8>();
        if (text == nullptr) throw StateError('argument allocation failed');
        allocated.add(text.cast());
        text.asTypedList(bytes.length).setAll(0, bytes);
        argv[i] = text;
      }
      _lib.lookupFunction<
        Int32 Function(Pointer<Uint8>, Pointer<Pointer<Uint8>>),
        int Function(Pointer<Uint8>, Pointer<Pointer<Uint8>>)
      >('execv')(argv[0], argv);
      throw StateError('plugin exec failed');
    } finally {
      for (final pointer in allocated.reversed) {
        _free(pointer);
      }
    }
  }
}

/// Used only by plugin-mode Engines; official Profiles keep their process path.
class LimitedExternalWorkerSupervisor implements PlatformProcessSupervisor {
  LimitedExternalWorkerSupervisor({String? engine, this.prefix = const []})
    : engine = engine ?? Platform.resolvedExecutable;
  final String engine;
  final List<String> prefix;
  final _base = const StandardProcessSupervisor();

  @override
  Future<Process> startIsolatedProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) => _base.startIsolatedProcess(
    engine,
    [
      ...prefix,
      '--plugin-child',
      '--cpu-seconds',
      '3600',
      '--open-files',
      '256',
      '--',
      executable,
      ...arguments,
    ],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );

  @override
  Future<void> terminateProcessTree(Process process, {required bool force}) =>
      _base.terminateProcessTree(process, force: force);
}
