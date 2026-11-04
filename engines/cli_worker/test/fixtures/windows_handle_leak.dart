// Windows CI fixture: creates executive handles until the job monitor stops it.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

Future<void> main() async {
  if (!Platform.isWindows) exit(77);
  final create = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Uint16>),
        int Function(Pointer<Void>, int, int, Pointer<Uint16>)
      >('CreateEventW');
  for (var i = 0; i < 5000; i++) {
    if (create(nullptr, 0, 0, nullptr) == 0) exit(71);
  }
  stdout.writeln('handles-created');
  await Future<void>.delayed(const Duration(seconds: 30));
}
