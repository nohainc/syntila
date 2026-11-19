import 'dart:io';

/// Thrown when another process (or another Agent in this process) already owns
/// the data directory.
class AgentLockedException implements Exception {
  AgentLockedException(this.path);
  final String path;

  @override
  String toString() => 'another Worker Agent already owns $path';
}

/// Exclusive ownership of one Worker data directory. It stops two processes
/// on one host from sharing a credential and journal before the server's
/// session fencing is even reached.
///
/// POSIX byte-range locks are per process, so a registry of held paths covers
/// a second owner inside this process; the file lock covers other processes.
class AgentLock {
  AgentLock._(this.file, this._handle);

  final File file;
  final RandomAccessFile _handle;
  static final Set<String> _heldHere = {};
  bool _released = false;

  static Future<AgentLock> acquire(File file) async {
    await file.parent.create(recursive: true);
    final key = file.absolute.path;
    if (!_heldHere.add(key)) throw AgentLockedException(key);
    RandomAccessFile? handle;
    try {
      handle = await file.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      await handle.truncate(0);
      await handle.writeString('$pid\n');
      await handle.flush();
      return AgentLock._(file, handle);
    } on FileSystemException {
      _heldHere.remove(key);
      await handle?.close();
      throw AgentLockedException(key);
    } on Object {
      _heldHere.remove(key);
      await handle?.close();
      rethrow;
    }
  }

  /// Whether some owner holds the lock right now. Used by `status`.
  static Future<bool> isHeld(File file) async {
    try {
      final lock = await acquire(file);
      await lock.release();
      return false;
    } on AgentLockedException {
      return true;
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    _heldHere.remove(file.absolute.path);
    try {
      await _handle.unlock();
    } on Object {
      // Closing the handle drops the lock anyway.
    }
    await _handle.close();
  }
}
