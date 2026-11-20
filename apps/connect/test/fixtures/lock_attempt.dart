import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';

/// Exit 0 when another process owns the lock (the expected outcome).
Future<void> main(List<String> args) async {
  try {
    final lock = await AgentLock.acquire(File(args.single));
    await lock.release();
    exitCode = 1;
  } on AgentLockedException {
    exitCode = 0;
  }
}
