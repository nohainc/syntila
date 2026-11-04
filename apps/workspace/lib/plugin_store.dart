import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

import 'worker_trust_policy.dart' show canonicalJson;

/// A failure with a stable management-IPC error code (see
/// `WORKER_PLUGIN_MANAGEMENT_IPC_V1.md`). Messages are safe to show and never
/// contain absolute paths, plugin output or secrets.
class PluginServiceException implements Exception {
  const PluginServiceException(this.code, this.message, {this.details});

  final String code;
  final String message;

  /// Structured, safe detail such as manifest issues.
  final Object? details;

  @override
  String toString() => '$code: $message';
}

const maxPluginManifestBytes = 256 * 1024;
const maxPluginPackageBytes = 512 * 1024 * 1024;
const maxPluginPackageFiles = 2000;

class PluginOrigin {
  const PluginOrigin({
    required this.kind,
    required this.locator,
    required this.importedAt,
  });

  /// `local_path` or `export_bundle`.
  final String kind;

  /// A display name (the basename), never an absolute path.
  final String locator;
  final DateTime importedAt;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'locator': locator,
        'importedAt': importedAt.toUtc().toIso8601String(),
      };

  factory PluginOrigin.fromJson(Map<String, Object?> json) => PluginOrigin(
        kind: json['kind'] as String,
        locator: json['locator'] as String,
        importedAt: DateTime.parse(json['importedAt'] as String),
      );
}

class PluginSigner {
  const PluginSigner({
    required this.fingerprint,
    required this.keyId,
    required this.verified,
  });

  /// SHA-256 of the raw public key, lowercase hex.
  final String fingerprint;
  final String keyId;
  final bool verified;

  Map<String, Object?> toJson() => {
        'fingerprint': fingerprint,
        'keyId': keyId,
        'verified': verified,
      };

  factory PluginSigner.fromJson(Map<String, Object?> json) => PluginSigner(
        fingerprint: json['fingerprint'] as String,
        keyId: json['keyId'] as String,
        verified: json['verified'] == true,
      );
}

/// One immutable, digest-addressed plugin version in the store.
class InstalledPlugin {
  const InstalledPlugin({
    required this.manifest,
    required this.manifestDigest,
    required this.artifactDigest,
    required this.platform,
    required this.artifact,
    required this.directory,
    required this.origin,
    this.signer,
  });

  final PluginManifest manifest;
  final String manifestDigest;
  final String artifactDigest;
  final String platform;
  final PluginArtifact artifact;
  final Directory directory;
  final PluginOrigin origin;
  final PluginSigner? signer;

  String get pluginId => manifest.pluginId;
  String get version => manifest.version;

  String get executablePath =>
      '${directory.path}${Platform.pathSeparator}${artifact.command.replaceAll('/', Platform.pathSeparator)}';
}

/// Digest that pins a plugin: SHA-256 of the canonical manifest JSON. Cloud
/// computes the same value (`pluginManifestDigest`); a shared vector proves it.
String pluginManifestDigest(Map<String, Object?> manifestJson) =>
    sha256.convert(utf8.encode(canonicalJson(manifestJson))).toString();

/// The Service-owned, immutable plugin store. Nothing here runs code: files
/// are copied, hashed and made read-only. Execution happens only in the
/// Engine, from these paths, after enablement.
class PluginStore {
  PluginStore({
    required this.root,
    this.forbiddenRoots = const [],
    this.platform,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// `<Application Support>/Plugins`.
  final Directory root;

  /// Directories a package may neither live in nor contain (application
  /// state, provider credential directories). The home directory is rejected
  /// only as an exact match or ancestor, never as a parent of a package.
  final List<String> forbiddenRoots;
  final String? platform;
  final DateTime Function() _clock;

  static int _counter = 0;

  Directory get storeDirectory => Directory('${root.path}/store');
  Directory get _staging => Directory('${root.path}/staging');

  String get hostPlatform =>
      platform ?? currentPluginPlatform() ?? 'unsupported';

  Directory dataDirectory(String pluginId) {
    final directory = Directory('${root.path}/data/$pluginId');
    directory.createSync(recursive: true);
    return directory;
  }

  Directory versionDirectory(
    String pluginId,
    String version,
    String manifestDigest,
  ) =>
      Directory('${storeDirectory.path}/$pluginId/$version/$manifestDigest');

  // ---- import ----------------------------------------------------------------

  /// Guard paths with symlinks resolved, so `/var` and `/private/var` (or any
  /// symlinked state directory) cannot be used to slip past the checks.
  List<String> _guardedPaths() => [
        for (final path in [root.path, ...forbiddenRoots])
          _resolveIfPresent(path),
      ];

  static String _resolveIfPresent(String path) {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) return path;
      return type == FileSystemEntityType.directory
          ? Directory(path).resolveSymbolicLinksSync()
          : File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path;
    }
  }

  /// Copies a package directory or `.zip` bundle into the store after full
  /// validation. Idempotent for an identical package.
  Future<InstalledPlugin> import(String source) async {
    final canonical = _canonicalSource(source);
    final staged = await _stage(canonical);
    try {
      final installed = await _verifyStaged(staged.directory, staged.origin);
      return await _install(installed, staged.directory);
    } finally {
      if (staged.directory.existsSync()) _forceDelete(staged.directory);
    }
  }

  String _canonicalSource(String source) {
    final String resolved;
    try {
      resolved =
          FileSystemEntity.typeSync(source) == FileSystemEntityType.notFound
              ? ''
              : (FileSystemEntity.isDirectorySync(source)
                  ? Directory(source).resolveSymbolicLinksSync()
                  : File(source).resolveSymbolicLinksSync());
    } on FileSystemException {
      throw const PluginServiceException(
        'plugin_package_invalid',
        'The package could not be read.',
      );
    }
    if (resolved.isEmpty) {
      throw const PluginServiceException(
        'plugin_package_invalid',
        'The package does not exist.',
      );
    }
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    bool inside(String path, String base) =>
        path == base || path.startsWith('$base${Platform.pathSeparator}');
    for (final base in _guardedPaths()) {
      if (inside(resolved, base) || inside(base, resolved)) {
        throw const PluginServiceException(
          'plugin_path_not_allowed',
          'That location cannot be imported from.',
        );
      }
    }
    if (home != null && inside(_resolveIfPresent(home), resolved)) {
      throw const PluginServiceException(
        'plugin_path_not_allowed',
        'That location cannot be imported from.',
      );
    }
    return resolved;
  }

  Future<_Staged> _stage(String canonical) async {
    _staging.createSync(recursive: true);
    final directory = Directory(
      '${_staging.path}/${_clock().microsecondsSinceEpoch}-${_counter++}',
    )..createSync(recursive: true);
    final basename = canonical.split(Platform.pathSeparator).last;
    try {
      if (FileSystemEntity.isDirectorySync(canonical)) {
        await _copyDirectory(Directory(canonical), directory);
        return _Staged(
          directory,
          PluginOrigin(
            kind: 'local_path',
            locator: basename,
            importedAt: _clock().toUtc(),
          ),
        );
      }
      final bundle = await _extractBundle(File(canonical), directory);
      return _Staged(
        directory,
        PluginOrigin(
          kind: bundle ? 'export_bundle' : 'local_path',
          locator: basename,
          importedAt: _clock().toUtc(),
        ),
      );
    } on Object {
      _forceDelete(directory);
      rethrow;
    }
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    var files = 0;
    var total = 0;
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw const PluginServiceException(
          'plugin_package_invalid',
          'Symbolic links are not allowed in a plugin package.',
        );
      }
      if (entity is! File) continue;
      final relative = entity.path
          .substring(source.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      if (!isSafePluginRelativePath(relative)) {
        throw const PluginServiceException(
          'plugin_package_invalid',
          'The package contains an unsafe file path.',
        );
      }
      files += 1;
      total += await entity.length();
      _checkLimits(files, total);
      final destination = File('${target.path}/$relative');
      destination.parent.createSync(recursive: true);
      await entity.copy(destination.path);
    }
  }

  /// Extracts a zip bundle. Returns true when it carries `bundle.json`.
  Future<bool> _extractBundle(File file, Directory target) async {
    if (await file.length() > maxPluginPackageBytes) {
      throw const PluginServiceException(
        'plugin_package_invalid',
        'The package is too large.',
      );
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    } on Object {
      throw const PluginServiceException(
        'plugin_package_invalid',
        'The package is not a readable bundle.',
      );
    }
    if (archive.isEmpty) {
      throw const PluginServiceException(
        'plugin_package_invalid',
        'The package is not a readable bundle.',
      );
    }
    var files = 0;
    var total = 0;
    var isBundle = false;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (entry.isSymbolicLink || !isSafePluginRelativePath(entry.name)) {
        throw const PluginServiceException(
          'plugin_package_invalid',
          'The bundle contains an unsafe entry.',
        );
      }
      files += 1;
      total += entry.size;
      _checkLimits(files, total);
      if (entry.name == 'bundle.json') {
        isBundle = true;
        continue; // Metadata about the bundle, not part of the package.
      }
      final destination = File('${target.path}/${entry.name}');
      destination.parent.createSync(recursive: true);
      await destination.writeAsBytes(entry.content as List<int>);
    }
    return isBundle;
  }

  void _checkLimits(int files, int total) {
    if (files > maxPluginPackageFiles || total > maxPluginPackageBytes) {
      throw const PluginServiceException(
        'plugin_package_invalid',
        'The package has too many files or is too large.',
      );
    }
  }

  Future<InstalledPlugin> _verifyStaged(
    Directory directory,
    PluginOrigin origin,
  ) async {
    final manifestFile = File('${directory.path}/plugin.json');
    if (!manifestFile.existsSync() ||
        manifestFile.lengthSync() > maxPluginManifestBytes) {
      throw const PluginServiceException(
        'plugin_manifest_invalid',
        'plugin.json is missing or too large.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await manifestFile.readAsString());
    } on FormatException {
      throw const PluginServiceException(
        'plugin_manifest_invalid',
        'plugin.json is not valid JSON.',
      );
    }
    final validation = validatePluginManifest(decoded);
    final manifest = validation.manifest;
    if (manifest == null) {
      throw PluginServiceException(
        'plugin_manifest_invalid',
        'plugin.json does not match the manifest schema.',
        details: [for (final issue in validation.issues) issue.toString()],
      );
    }
    if (negotiatePluginProtocol(manifest) == null) {
      throw const PluginServiceException(
        'plugin_protocol_unsupported',
        'This plugin supports no protocol version the Workspace offers.',
      );
    }
    final platformKey = hostPlatform;
    final artifact =
        manifest.artifacts[platformKey] ?? manifest.artifacts['any'];
    if (artifact == null) {
      throw PluginServiceException(
        'plugin_platform_unsupported',
        'This plugin has no build for $platformKey.',
      );
    }
    // Every artifact that is present must match its pinned hash and size.
    for (final entry in manifest.artifacts.entries) {
      final file = File('${directory.path}/${entry.value.command}');
      final local = identical(entry.value, artifact);
      if (!file.existsSync()) {
        if (local) {
          throw const PluginServiceException(
            'plugin_package_invalid',
            'The artifact for this platform is missing from the package.',
          );
        }
        continue;
      }
      if (file.lengthSync() != entry.value.size ||
          await _sha256(file) != entry.value.sha256) {
        throw const PluginServiceException(
          'plugin_digest_mismatch',
          'An artifact does not match the digest in plugin.json.',
        );
      }
    }
    final digest = pluginManifestDigest(manifest.raw);
    return InstalledPlugin(
      manifest: manifest,
      manifestDigest: digest,
      artifactDigest: artifact.sha256,
      platform: manifest.artifacts[platformKey] != null ? platformKey : 'any',
      artifact: artifact,
      directory: directory,
      origin: origin,
      signer: await _verifySignature(directory, digest),
    );
  }

  Future<PluginSigner?> _verifySignature(
    Directory directory,
    String manifestDigest,
  ) async {
    final file = File('${directory.path}/plugin.sig');
    if (!file.existsSync()) return null;
    try {
      final json = Map<String, Object?>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      if (json['alg'] != 'ed25519') throw const FormatException('alg');
      final publicKey = base64Decode(json['publicKey'] as String);
      final signature = base64Decode(json['signature'] as String);
      if (publicKey.length != 32 || signature.length != 64) {
        throw const FormatException('length');
      }
      final ok = await Ed25519().verify(
        utf8.encode(manifestDigest),
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
      if (!ok) throw const FormatException('signature');
      return PluginSigner(
        fingerprint: sha256.convert(publicKey).toString(),
        keyId: (json['keyId'] as String?) ?? '',
        verified: true,
      );
    } on Object {
      throw const PluginServiceException(
        'plugin_signature_invalid',
        'plugin.sig does not verify against the manifest.',
      );
    }
  }

  Future<InstalledPlugin> _install(
    InstalledPlugin staged,
    Directory stagingDirectory,
  ) async {
    final versionRoot = Directory(
      '${storeDirectory.path}/${staged.pluginId}/${staged.version}',
    );
    final destination = versionDirectory(
      staged.pluginId,
      staged.version,
      staged.manifestDigest,
    );
    if (versionRoot.existsSync()) {
      final existing = versionRoot
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split(Platform.pathSeparator).last)
          .toList();
      if (existing.any((d) => d != staged.manifestDigest)) {
        throw const PluginServiceException(
          'plugin_version_conflict',
          'This version is already imported with different contents.',
        );
      }
    }
    if (!destination.existsSync()) {
      destination.parent.createSync(recursive: true);
      stagingDirectory.renameSync(destination.path);
      await _lockdown(destination, staged.artifact.command);
    }
    return InstalledPlugin(
      manifest: staged.manifest,
      manifestDigest: staged.manifestDigest,
      artifactDigest: staged.artifactDigest,
      platform: staged.platform,
      artifact: staged.artifact,
      directory: destination,
      origin: staged.origin,
      signer: staged.signer,
    );
  }

  /// Read-only files, owner-only executable artifact. Best effort on Windows,
  /// where ACLs rather than mode bits apply.
  Future<void> _lockdown(Directory directory, String artifactCommand) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['-R', 'a-w', directory.path]);
    await Process.run('chmod', [
      '500',
      '${directory.path}/$artifactCommand',
    ]);
  }

  // ---- lookup, re-verification, removal, export ------------------------------------

  /// Loads an installed version and re-verifies every byte against its pinned
  /// digests. Throws `plugin_digest_mismatch` if anything changed on disk.
  Future<InstalledPlugin> load(
    String pluginId,
    String version,
    String manifestDigest, {
    PluginOrigin? origin,
    PluginSigner? signer,
  }) async {
    final directory = versionDirectory(pluginId, version, manifestDigest);
    if (!directory.existsSync()) {
      throw const PluginServiceException(
        'plugin_not_found',
        'That plugin version is not installed on this Workspace.',
      );
    }
    final installed = await _verifyStaged(
      directory,
      origin ??
          PluginOrigin(
            kind: 'local_path',
            locator: pluginId,
            importedAt: directory.statSync().modified.toUtc(),
          ),
    );
    if (installed.manifestDigest != manifestDigest) {
      throw const PluginServiceException(
        'plugin_digest_mismatch',
        'The installed files no longer match the pinned digest.',
      );
    }
    return installed;
  }

  Future<void> removeVersion(String pluginId, String version) async {
    final directory = Directory('${storeDirectory.path}/$pluginId/$version');
    if (directory.existsSync()) _forceDelete(directory);
    final parent = Directory('${storeDirectory.path}/$pluginId');
    if (parent.existsSync() && parent.listSync().isEmpty) parent.deleteSync();
  }

  /// Removes every version and, when [deleteData] is set, the plugin's data.
  Future<void> removePlugin(String pluginId, {bool deleteData = true}) async {
    final directory = Directory('${storeDirectory.path}/$pluginId');
    if (directory.existsSync()) _forceDelete(directory);
    if (deleteData) {
      final data = Directory('${root.path}/data/$pluginId');
      if (data.existsSync()) _forceDelete(data);
    }
  }

  /// Writes a credential-free bundle: the verified package files, the optional
  /// signature and `bundle.json`. The data directory, sessions, logs,
  /// environment and runtime credentials are never read.
  Future<void> export(InstalledPlugin plugin, String outputPath) async {
    final target = File(outputPath);
    final canonicalParent = target.parent.existsSync()
        ? target.parent.resolveSymbolicLinksSync()
        : '';
    if (canonicalParent.isEmpty) {
      throw const PluginServiceException(
        'plugin_path_not_allowed',
        'The destination folder does not exist.',
      );
    }
    for (final base in _guardedPaths()) {
      if (canonicalParent == base ||
          canonicalParent.startsWith('$base${Platform.pathSeparator}')) {
        throw const PluginServiceException(
          'plugin_path_not_allowed',
          'That destination cannot be written to.',
        );
      }
    }
    final archive = Archive();
    archive.addFile(
      ArchiveFile.bytes(
        'bundle.json',
        utf8.encode(
          jsonEncode({
            'kind': 'syntila-plugin-bundle',
            'version': 1,
            'pluginId': plugin.pluginId,
            'pluginVersion': plugin.version,
            'manifestDigest': plugin.manifestDigest,
          }),
        ),
      ),
    );
    for (final entity in plugin.directory.listSync(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(plugin.directory.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      archive.addFile(ArchiveFile.bytes(relative, await entity.readAsBytes()));
    }
    final bytes = ZipEncoder().encode(archive);
    final temporary = File('${target.path}.partial');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  }

  Future<String> _sha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  void _forceDelete(FileSystemEntity entity) {
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['-R', 'u+w', entity.path]);
    }
    try {
      entity.deleteSync(recursive: true);
    } on FileSystemException {
      // A later cleanup retries; the store entry is already unreferenced.
    }
  }
}

class _Staged {
  const _Staged(this.directory, this.origin);
  final Directory directory;
  final PluginOrigin origin;
}
