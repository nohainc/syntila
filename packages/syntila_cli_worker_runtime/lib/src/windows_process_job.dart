import 'dart:ffi';
import 'dart:io';

int? _lifetimeJob;

/// Called only by standalone service/Engine entry points before any children.
/// The retained, non-inheritable handle closes on process exit and Windows kills
/// every descendant in this job, including descendants whose parent exited.
void initializeWindowsProcessJob({
  int? maxMemoryBytes,
  int? maxProcesses,
  int? cpuSeconds,
}) {
  if (!Platform.isWindows || _lifetimeJob != null) return;
  if (sizeOf<IntPtr>() != 8) throw UnsupportedError('Windows x64 is required');
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
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final close = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final name = 'Local\\SyntilaProcess-$pid';
  final text = allocate(heap, 8, (name.length + 1) * 2).cast<Uint16>();
  final limits = allocate(heap, 8, 144).cast<Uint8>();
  if (text == nullptr || limits == nullptr)
    throw StateError('Windows job allocation failed');
  text.asTypedList(name.length).setAll(0, name.codeUnits);
  int handle = 0;
  try {
    final create = kernel
        .lookupFunction<
          IntPtr Function(Pointer<Void>, Pointer<Uint16>),
          int Function(Pointer<Void>, Pointer<Uint16>)
        >('CreateJobObjectW');
    handle = create(nullptr, text);
    if (handle == 0 || error() == 183)
      throw StateError('Could not create exclusive Windows process job');
    (limits + 16).cast<Uint32>().value =
        0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if (maxMemoryBytes != null) {
      (limits + 16).cast<Uint32>().value |= 0x200;
      (limits + 120).cast<Uint64>().value = maxMemoryBytes;
    }
    if (maxProcesses != null) {
      (limits + 16).cast<Uint32>().value |= 0x8;
      (limits + 40).cast<Uint32>().value = maxProcesses;
    }
    if (cpuSeconds != null) {
      (limits + 16).cast<Uint32>().value |= 0x4;
      (limits + 8).cast<Int64>().value = cpuSeconds * 10000000;
    }
    final configure = kernel
        .lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)
        >('SetInformationJobObject');
    final assign = kernel
        .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
          'AssignProcessToJobObject',
        );
    final current = kernel.lookupFunction<IntPtr Function(), int Function()>(
      'GetCurrentProcess',
    )();
    if (configure(handle, 9, limits.cast(), 144) == 0 ||
        assign(handle, current) == 0) {
      throw StateError(
        'Could not protect Windows process descendants (${error()})',
      );
    }
    _lifetimeJob = handle;
    handle = 0;
  } finally {
    if (handle != 0) close(handle);
    free(heap, 0, text.cast());
    free(heap, 0, limits.cast());
  }
}

bool terminateWindowsProcessJob(int processId) {
  if (!Platform.isWindows) return false;
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
  final text = 'Local\\SyntilaProcess-$processId';
  final name = allocate(heap, 8, (text.length + 1) * 2).cast<Uint16>();
  if (name == nullptr) throw StateError('Windows job allocation failed');
  name.asTypedList(text.length).setAll(0, text.codeUnits);
  final open = kernel
      .lookupFunction<
        IntPtr Function(Uint32, Int32, Pointer<Uint16>),
        int Function(int, int, Pointer<Uint16>)
      >('OpenJobObjectW');
  final handle = open(8, 0, name);
  free(heap, 0, name.cast());
  if (handle == 0) return false;
  try {
    return kernel.lookupFunction<
          Int32 Function(IntPtr, Uint32),
          int Function(int, int)
        >('TerminateJobObject')(handle, 1) !=
        0;
  } finally {
    kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'CloseHandle',
    )(handle);
  }
}
