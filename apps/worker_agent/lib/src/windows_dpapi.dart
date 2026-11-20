import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

/// Windows current-user DPAPI. DLLs are loaded lazily and never on other OSes.
abstract final class WindowsDpapi {
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _crypt = DynamicLibrary.open('crypt32.dll');
  static final _heap = _kernel
      .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap')();
  static final _alloc = _kernel
      .lookupFunction<
        Pointer<Void> Function(IntPtr, Uint32, IntPtr),
        Pointer<Void> Function(int, int, int)
      >('HeapAlloc');
  static final _free = _kernel
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>),
        int Function(int, int, Pointer<Void>)
      >('HeapFree');
  static final _localFree = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');

  static Pointer<Uint8> _allocate(int size) {
    if (sizeOf<IntPtr>() != 8) {
      throw UnsupportedError('Windows x64 is required');
    }
    final memory = _alloc(_heap, 8, size).cast<Uint8>();
    if (memory == nullptr) throw StateError('Windows allocation failed');
    return memory;
  }

  static Uint8List transform(
    List<int> input,
    String context, {
    required bool decrypt,
  }) {
    final entropyBytes = utf8.encode(context);
    final data = _allocate(input.length);
    final entropy = _allocate(entropyBytes.length);
    final blob = _allocate(16);
    final entropyBlob = _allocate(16);
    final output = _allocate(16);
    data.asTypedList(input.length).setAll(0, input);
    entropy.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
    blob.cast<Uint32>().value = input.length;
    (blob + 8).cast<Pointer<Uint8>>().value = data;
    entropyBlob.cast<Uint32>().value = entropyBytes.length;
    (entropyBlob + 8).cast<Pointer<Uint8>>().value = entropy;
    try {
      final crypt = _crypt
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
              Uint32,
              Pointer<Void>,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
              int,
              Pointer<Void>,
            )
          >(decrypt ? 'CryptUnprotectData' : 'CryptProtectData');
      if (crypt(
            blob.cast(),
            nullptr,
            entropyBlob.cast(),
            nullptr,
            nullptr,
            1,
            output.cast(),
          ) ==
          0) {
        throw StateError('Windows DPAPI failed');
      }
      final length = output.cast<Uint32>().value;
      if (length > 1024 * 1024) throw StateError('Credential exceeds limit');
      return Uint8List.fromList(
        (output + 8).cast<Pointer<Uint8>>().value.asTypedList(length),
      );
    } finally {
      final result = (output + 8).cast<Pointer<Void>>().value;
      if (result != nullptr) _localFree(result);
      data.asTypedList(input.length).fillRange(0, input.length, 0);
      for (final ptr in [data, entropy, blob, entropyBlob, output]) {
        _free(_heap, 0, ptr.cast());
      }
    }
  }
}
