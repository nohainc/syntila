import 'dart:async';
import 'dart:ffi';
import 'dart:io';

/// Observed aggregate executive-handle cap for the private Windows plugin job.
/// This includes the launcher; it is not a hard file-descriptor quota.
class ExternalWorkerHandleMonitor {
  ExternalWorkerHandleMonitor({
    required this.readCount,
    required this.onViolation,
    this.maxHandles = 4096,
    this.interval = const Duration(seconds: 1),
  });
  final int Function() readCount;
  final void Function(String) onViolation;
  final int maxHandles;
  final Duration interval;
  Timer? _timer;
  bool _stopped = false;

  void start() {
    _timer = Timer.periodic(interval, (_) {
      if (_stopped) return;
      try {
        if (readCount() <= maxHandles) return;
        stop();
        onViolation('plugin handle count limit exceeded');
      } on Object {
        stop();
        onViolation('plugin handle usage could not be inspected');
      }
    });
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }
}

/// Enumerates the named private job (not every process owned by the user), then
/// queries each member with PROCESS_QUERY_LIMITED_INFORMATION. A process that
/// exited during the snapshot is skipped; other inspection failures fail closed.
int readWindowsExternalWorkerJobHandles(int launcherPid) {
  if (!Platform.isWindows || sizeOf<IntPtr>() != 8) {
    throw UnsupportedError('Windows x64 job inspection required');
  }
  final kernel = DynamicLibrary.open('kernel32.dll');
  final heap = kernel.lookupFunction<IntPtr Function(), int Function()>(
    'GetProcessHeap',
  )();
  final allocate = kernel
      .lookupFunction<
        Pointer<Void> Function(IntPtr, Uint32, IntPtr),
        Pointer<Void> Function(int, int, int)
      >('HeapAlloc');
  final free = kernel
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>),
        int Function(int, int, Pointer<Void>)
      >('HeapFree');
  final close = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final openProcess = kernel
      .lookupFunction<
        IntPtr Function(Uint32, Int32, Uint32),
        int Function(int, int, int)
      >('OpenProcess');
  final handles = kernel
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetProcessHandleCount');
  final allocated = <Pointer<Void>>[];
  int job = 0;
  Pointer<Void> buffer(int size) {
    final result = allocate(heap, 8, size);
    if (result == nullptr) throw StateError('job inspection allocation failed');
    allocated.add(result);
    return result;
  }

  try {
    final name = 'Local\\SyntilaProcess-$launcherPid';
    final text = buffer((name.length + 1) * 2).cast<Uint16>();
    text.asTypedList(name.length).setAll(0, name.codeUnits);
    job = kernel
        .lookupFunction<
          IntPtr Function(Uint32, Int32, Pointer<Uint16>),
          int Function(int, int, Pointer<Uint16>)
        >('OpenJobObjectW')(4, 0, text);
    if (job == 0) throw StateError('private plugin job unavailable');
    // The job's hard process count is 66, including launcher and plugin.
    const capacity = 66;
    const bytes = 8 + capacity * 8;
    final list = buffer(bytes).cast<Uint8>();
    final query = kernel
        .lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
        >('QueryInformationJobObject');
    if (query(job, 3, list.cast(), bytes, nullptr) == 0) {
      throw StateError('private plugin job could not be inspected');
    }
    final assigned = list.cast<Uint32>()[0];
    final count = list.cast<Uint32>()[1];
    if (count > capacity || assigned > capacity || assigned != count) {
      throw StateError('private plugin job list exceeds bound');
    }
    final value = buffer(4).cast<Uint32>();
    var total = 0;
    for (var i = 0; i < count; i++) {
      final id = (list + 8).cast<Uint64>()[i];
      final process = openProcess(0x1000, 0, id);
      if (process == 0) {
        if (error() == 87) continue; // ERROR_INVALID_PARAMETER: no longer live
        throw StateError('plugin process could not be inspected');
      }
      try {
        if (handles(process, value) == 0) {
          throw StateError('plugin handle count unavailable');
        }
        total += value.value;
      } finally {
        close(process);
      }
    }
    return total;
  } finally {
    if (job != 0) close(job);
    for (final allocation in allocated.reversed) {
      free(heap, 0, allocation);
    }
  }
}
