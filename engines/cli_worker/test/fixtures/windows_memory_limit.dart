import 'dart:ffi';
import 'dart:io';

// A committed-memory request must fail before the private job exceeds 1 GiB.
void main() {
  if (!Platform.isWindows) exit(77);
  final allocate = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, IntPtr, Uint32, Uint32),
        Pointer<Void> Function(Pointer<Void>, int, int, int)
      >('VirtualAlloc');
  const chunk = 64 * 1024 * 1024;
  var committed = 0;
  for (var i = 0; i < 32; i++) {
    if (allocate(nullptr, chunk, 0x3000, 0x4) == nullptr) {
      stdout.writeln(committed);
      return;
    }
    committed += chunk;
  }
  exit(71); // No limit refusal within 2 GiB: do not count as a pass.
}
