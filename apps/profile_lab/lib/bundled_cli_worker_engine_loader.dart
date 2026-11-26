import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Loads and materializes the app-bundled generic CLI Worker Engine binary.
///
/// Profile Lab bundles the exact same generic CLI Worker Engine binary used by
/// Connect so that Profile testing is identical to production Connect execution
/// without requiring Syntila Connect to be installed.
Future<File?> loadBundledCliWorkerEngine({
  required Directory enginesDirectory,
  AssetBundle? bundle,
}) async {
  const assetName = 'assets/engines/syntila-agent';
  final assets = bundle ?? rootBundle;
  List<int>? bytes;

  // 1. Try loading from Flutter AssetBundle
  try {
    final data = await assets.load(assetName);
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    // 2. Fallback to direct relative filesystem file (useful in tests or local runs)
    final localFallback = File('assets/engines/syntila-agent');
    if (await localFallback.exists()) {
      bytes = await localFallback.readAsBytes();
    }
  }

  if (bytes == null || bytes.isEmpty || bytes.length > 128 * 1024 * 1024) {
    return null;
  }

  try {
    final digest = sha256.convert(bytes).toString();
    final versionDirectory = Directory(
      '${enginesDirectory.path}/cli_worker/$cliWorkerEngineVersion-$digest',
    );
    if (!await versionDirectory.exists()) {
      await versionDirectory.create(recursive: true);
    }

    final executable = File('${versionDirectory.path}/syntila-agent');
    var cacheMatches = false;
    if (await executable.exists()) {
      final existingDigest = await sha256.bind(executable.openRead()).first;
      cacheMatches = existingDigest.toString() == digest;
    }

    if (!cacheMatches) {
      await executable.writeAsBytes(bytes, flush: true);
    }

    // Enforce execute permissions on macOS POSIX
    if (Platform.isMacOS || Platform.isLinux) {
      final chmod = await Process.run('chmod', ['700', executable.path]);
      if (chmod.exitCode != 0) return null;
    }

    return executable;
  } catch (_) {
    return null;
  }
}
