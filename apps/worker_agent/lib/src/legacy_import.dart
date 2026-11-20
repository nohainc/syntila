import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'folders.dart';
import 'work_root.dart';

/// What [importLegacyWorkspace] did, in words that carry no secrets.
class LegacyImportReport {
  final List<String> imported = [];
  final List<String> skipped = [];
  String? workRoot;
  final List<String> notCopied = const [
    'credentials and keys: this Agent creates its own key pair when it pairs',
    'Profiles: the Agent downloads and verifies them itself',
    'native Engine sessions: they belong to the old Workspace service account',
    'folder ids: the Agent derives new opaque ids from the folder paths',
  ];
}

/// Brings the local choices of a legacy Workspace over to this Agent.
///
/// The old data directory is only read, never changed, so it still works until
/// the rollback window closes. Everything is imported with the least access:
/// folders are granted read-only (use [write] to keep write access) and nothing
/// that proves identity is copied. The Worker's server-side identity is kept by
/// pairing: the owner creates the pairing code from the existing Worker, and
/// the backend maps that Worker's id to this Agent.
Future<LegacyImportReport> importLegacyWorkspace({
  required Directory legacyData,
  required AllowedFolders folders,
  required WorkRoot workRoot,
  bool write = false,
  bool dryRun = false,
}) async {
  final report = LegacyImportReport();
  if (!await legacyData.exists()) {
    throw FormatException('${legacyData.path} does not exist');
  }

  final lifecycle = File(p.join(legacyData.path, 'workspace-lifecycle.json'));
  final registry = File(p.join(legacyData.path, 'allowed-folders.json'));

  final legacyRoot = await _workRootPath(lifecycle);
  if (legacyRoot != null && await Directory(legacyRoot).exists()) {
    if (await workRoot.root() == null) {
      if (!dryRun) await workRoot.setRoot(legacyRoot);
      report.workRoot = legacyRoot;
      if (!dryRun) {
        for (final id in await workRoot.adoptMarkedSpaces()) {
          report.imported.add('Space $id: existing folder under the Work Root');
        }
      }
    } else {
      report.skipped.add('Work Root: this Agent already has one');
    }
  } else if (legacyRoot != null) {
    report.skipped.add('Work Root: $legacyRoot no longer exists');
  }

  for (final path in await _folderPaths(registry)) {
    try {
      if (!dryRun) await folders.add(path, write: write);
      report.imported.add(path);
    } on FolderRejectedException catch (error) {
      report.skipped.add('$path: ${error.reason}');
    }
  }
  return report;
}

Future<String?> _workRootPath(File file) async {
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map && decoded['workRootPath'] is String) {
      return decoded['workRootPath'] as String;
    }
  } on FormatException {
    // An unreadable file imports nothing; the report says nothing was found.
  }
  return null;
}

Future<List<String>> _folderPaths(File file) async {
  if (!await file.exists()) return [];
  try {
    final decoded = jsonDecode(await file.readAsString());
    final entries = decoded is Map ? decoded['folders'] : null;
    if (entries is! List) return [];
    return [
      for (final entry in entries)
        if (entry is Map && entry['path'] is String) entry['path'] as String,
    ];
  } on FormatException {
    return [];
  }
}
