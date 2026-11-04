// Windows CI probe: query the job inherited by the plugin process.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

void main() {
  if (!Platform.isWindows) exit(77);
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
  final buffer = allocate(heap, 8, 144).cast<Uint8>();
  if (buffer == nullptr) exit(70);
  try {
    final query = kernel
        .lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
        >('QueryInformationJobObject');
    if (query(0, 9, buffer.cast(), 144, nullptr) == 0) exit(70);
    stdout.writeln(
      jsonEncode({
        'flags': (buffer + 16).cast<Uint32>().value,
        'processes': (buffer + 40).cast<Uint32>().value,
        'memory': (buffer + 120).cast<Uint64>().value,
        'cpu': (buffer + 8).cast<Int64>().value,
      }),
    );
  } finally {
    free(heap, 0, buffer.cast());
  }
}
