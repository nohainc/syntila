import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Flushes a file or directory to stable storage through the operating system.
///
/// `File.flush` and `writeAsString(flush: true)` sync file data but say nothing
/// about the directory entry that names a newly created file, so a power loss
/// can lose a marker whose contents were synced. POSIX therefore also needs an
/// `fsync` on the containing directory. On macOS a plain `fsync` does not force
/// the drive cache, so `F_FULLFSYNC` is requested first. Windows has no
/// equivalent for directories through Dart; NTFS journals the metadata and the
/// file itself is flushed by `flush: true`, which is the strongest guarantee
/// available there and is reported by [durableDirectorySyncSupported].
///
/// Throws [FileSystemException] when the sync fails: callers that depend on
/// durability must treat that as an unknown outcome and never proceed.
typedef DurablePathSync = Future<void> Function(
  String path, {
  required bool directory,
});

bool get durableDirectorySyncSupported => !Platform.isWindows;

Future<void> syncPathDurably(String path, {required bool directory}) async {
  if (Platform.isWindows) return;
  _posixSync(path);
}

typedef _OpenC = Int32 Function(Pointer<Uint8>, Int32);
typedef _Open = int Function(Pointer<Uint8>, int);
typedef _FsyncC = Int32 Function(Int32);
typedef _Fsync = int Function(int);
typedef _FcntlC = Int32 Function(Int32, Int32);
typedef _Fcntl = int Function(int, int);
typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _Malloc = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _Free = void Function(Pointer<Uint8>);

void _posixSync(String path) {
  final lib = DynamicLibrary.process();
  final open = lib.lookupFunction<_OpenC, _Open>('open');
  final fsync = lib.lookupFunction<_FsyncC, _Fsync>('fsync');
  final close = lib.lookupFunction<_FsyncC, _Fsync>('close');
  final malloc = lib.lookupFunction<_MallocC, _Malloc>('malloc');
  final free = lib.lookupFunction<_FreeC, _Free>('free');
  final bytes = utf8.encode(path);
  final buffer = malloc(bytes.length + 1);
  try {
    final view = buffer.asTypedList(bytes.length + 1);
    view.setAll(0, bytes);
    view[bytes.length] = 0;
    // O_RDONLY is 0 on every supported POSIX system.
    final fd = open(buffer, 0);
    if (fd < 0) {
      throw FileSystemException('Could not open for sync', path);
    }
    try {
      var ok = false;
      if (Platform.isMacOS) {
        final fcntl = lib.lookupFunction<_FcntlC, _Fcntl>('fcntl');
        const fFullFsync = 51; // <sys/fcntl.h>
        ok = fcntl(fd, fFullFsync) == 0;
      }
      if (!ok && fsync(fd) != 0) {
        throw FileSystemException('fsync failed', path);
      }
    } finally {
      close(fd);
    }
  } finally {
    free(buffer);
  }
}
