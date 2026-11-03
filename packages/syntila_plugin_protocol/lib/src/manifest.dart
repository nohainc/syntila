import 'frames.dart';
import 'limits.dart';

const _platforms = <String>{
  'darwin-arm64',
  'darwin-x64',
  'linux-x64',
  'linux-arm64',
  'windows-x64',
  'any',
};

const maxPluginArtifactBytes = 256 * 1024 * 1024;

final _pluginIdPattern = RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$');
final _versionPattern =
    RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _envNamePattern = RegExp(r'^[A-Z][A-Z0-9_]{0,63}$');
final _protocolRangePattern = RegExp(r'^1\.(0|[1-9][0-9]*)$');
final _toolPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

class PluginManifestIssue {
  const PluginManifestIssue(this.path, this.message);
  final String path;
  final String message;

  @override
  String toString() => '$path: $message';
}

/// The artifact for one platform, as declared by the manifest.
class PluginArtifact {
  const PluginArtifact({
    required this.command,
    required this.args,
    required this.sha256,
    required this.size,
  });
  final String command;
  final List<String> args;
  final String sha256;
  final int size;
}

/// A validated plugin manifest. Obtain one with [validatePluginManifest].
class PluginManifest {
  const PluginManifest({
    required this.pluginId,
    required this.version,
    required this.displayName,
    required this.artifacts,
    required this.raw,
  });
  final String pluginId;
  final String version;
  final String displayName;
  final Map<String, PluginArtifact> artifacts;
  final Map<String, Object?> raw;
}

class PluginManifestValidation {
  const PluginManifestValidation(this.manifest, this.issues);
  final PluginManifest? manifest;
  final List<PluginManifestIssue> issues;
  bool get isValid => manifest != null && issues.isEmpty;
}

/// Strict validation mirroring `PluginManifestSchema` in
/// `packages/workspace-runtime-protocol`: unknown keys at any level are
/// errors, so a typo cannot hide an access declaration. The Service's
/// `plugins.validate` and author tooling use this one implementation.
PluginManifestValidation validatePluginManifest(Object? input) {
  final issues = <PluginManifestIssue>[];
  void issue(String path, String message) =>
      issues.add(PluginManifestIssue(path, message));

  if (input is! Map) {
    issue('', 'manifest must be a JSON object');
    return PluginManifestValidation(null, issues);
  }
  final m = Map<String, Object?>.from(input);

  void strictKeys(String path, Map<String, Object?> map, Set<String> allowed) {
    for (final key in map.keys) {
      if (!allowed.contains(key)) issue('$path$key', 'unknown key');
    }
  }

  String? str(Map<String, Object?> map, String path, String key,
      {int max = 256, int min = 1}) {
    final v = map[key];
    if (v is! String || v.length < min || v.length > max) {
      issue('$path$key', 'must be a string of $min..$max characters');
      return null;
    }
    return v;
  }

  strictKeys('', m, {
    'schemaVersion',
    'pluginId',
    'version',
    'displayName',
    'description',
    'author',
    'protocol',
    'artifacts',
    'capabilities',
    'access',
    'limits',
    'requires',
    'license',
    'homepage',
  });

  if (m['schemaVersion'] != 1) issue('schemaVersion', 'must be 1');

  final pluginId = str(m, '', 'pluginId', max: 48);
  if (pluginId != null && !_pluginIdPattern.hasMatch(pluginId)) {
    issue('pluginId', 'must be lowercase kebab-case');
  }
  final version = str(m, '', 'version', max: 64);
  if (version != null && !_versionPattern.hasMatch(version)) {
    issue('version', 'must be MAJOR.MINOR.PATCH');
  }
  final displayName = str(m, '', 'displayName', max: 128);
  final description = m['description'];
  if (description is! String || description.length > 512) {
    issue('description', 'must be a string of at most 512 characters');
  }

  final author = m['author'];
  if (author is! Map) {
    issue('author', 'must be an object');
  } else {
    final a = Map<String, Object?>.from(author);
    strictKeys('author.', a, {'name', 'contact'});
    str(a, 'author.', 'name', max: 128);
    if (a['contact'] != null) str(a, 'author.', 'contact', max: 256);
  }

  final protocol = m['protocol'];
  if (protocol is! Map) {
    issue('protocol', 'must be an object');
  } else {
    final p = Map<String, Object?>.from(protocol);
    strictKeys('protocol.', p, {'min', 'max'});
    final min = p['min'];
    final max = p['max'];
    if (min is! String || !_protocolRangePattern.hasMatch(min)) {
      issue('protocol.min', 'must be 1.x');
    }
    if (max is! String || !_protocolRangePattern.hasMatch(max)) {
      issue('protocol.max', 'must be 1.x');
    }
    if (min is String && max is String) {
      final minMinor = int.tryParse(min.split('.').last);
      final maxMinor = int.tryParse(max.split('.').last);
      if (minMinor != null && maxMinor != null && minMinor > maxMinor) {
        issue('protocol', 'min must not exceed max');
      }
    }
  }

  final artifacts = <String, PluginArtifact>{};
  final rawArtifacts = m['artifacts'];
  if (rawArtifacts is! Map || rawArtifacts.isEmpty) {
    issue('artifacts', 'at least one platform artifact is required');
  } else {
    rawArtifacts.forEach((key, value) {
      final path = 'artifacts.$key';
      if (key is! String || !_platforms.contains(key)) {
        issue(path, 'unknown platform');
        return;
      }
      if (value is! Map) {
        issue(path, 'must be an object');
        return;
      }
      final a = Map<String, Object?>.from(value);
      strictKeys('$path.', a, {'command', 'args', 'sha256', 'size'});
      final command = a['command'];
      if (command is! String || !isSafePluginRelativePath(command)) {
        issue('$path.command', 'must be a safe relative path');
      }
      final args = a['args'];
      if (args is! List ||
          args.length > 32 ||
          args.any((v) => v is! String || v.length > 256)) {
        issue('$path.args', 'must be at most 32 strings');
      }
      final sha = a['sha256'];
      if (sha is! String || !_sha256Pattern.hasMatch(sha)) {
        issue('$path.sha256', 'must be 64 lowercase hex characters');
      }
      final size = a['size'];
      if (size is! int || size < 1 || size > maxPluginArtifactBytes) {
        issue('$path.size', 'must be 1..$maxPluginArtifactBytes');
      }
      if (command is String &&
          args is List &&
          sha is String &&
          size is int &&
          issues.every((i) => !i.path.startsWith('$path.'))) {
        artifacts[key] = PluginArtifact(
          command: command,
          args: List<String>.from(args),
          sha256: sha,
          size: size,
        );
      }
    });
  }

  final capabilities = m['capabilities'];
  if (capabilities is! Map) {
    issue('capabilities', 'must be an object');
  } else {
    final c = Map<String, Object?>.from(capabilities);
    strictKeys('capabilities.', c,
        {'progress', 'activity', 'sessionResume', 'readOnly'});
    for (final key in ['progress', 'activity', 'sessionResume']) {
      if (c[key] != null && c[key] is! bool) {
        issue('capabilities.$key', 'must be a boolean');
      }
    }
    if (c['readOnly'] != null &&
        c['readOnly'] != 'honors' &&
        c['readOnly'] != 'never') {
      issue('capabilities.readOnly', 'must be honors or never');
    }
  }

  final access = m['access'];
  if (access is! Map) {
    issue('access', 'must be an object');
  } else {
    final a = Map<String, Object?>.from(access);
    strictKeys('access.', a, {'workRoot', 'network', 'subprocess', 'env'});
    if (!const {'none', 'read', 'write'}.contains(a['workRoot'])) {
      issue('access.workRoot', 'must be none, read or write');
    }
    if (a['subprocess'] is! bool) {
      issue('access.subprocess', 'must be a boolean');
    }
    final network = a['network'];
    if (network is! Map) {
      issue('access.network', 'must be an object');
    } else {
      final n = Map<String, Object?>.from(network);
      if (n['mode'] == 'none') {
        strictKeys('access.network.', n, {'mode'});
      } else if (n['mode'] == 'declared') {
        strictKeys('access.network.', n, {'mode', 'hosts'});
        final hosts = n['hosts'];
        if (hosts is! List ||
            hosts.isEmpty ||
            hosts.length > 16 ||
            hosts.any((h) => h is! String || h.isEmpty || h.length > 253)) {
          issue('access.network.hosts', 'must be 1..16 host names');
        }
      } else {
        issue('access.network.mode', 'must be none or declared');
      }
    }
    final env = a['env'];
    if (env is! List ||
        env.length > 16 ||
        env.any((v) =>
            v is! String ||
            !_envNamePattern.hasMatch(v) ||
            v.startsWith('SYNTILA_'))) {
      issue('access.env', 'must be at most 16 names, none SYNTILA_*');
    }
  }

  final limits = m['limits'];
  if (limits != null) {
    if (limits is! Map) {
      issue('limits', 'must be an object');
    } else {
      final l = Map<String, Object?>.from(limits);
      strictKeys('limits.', l, {'maxConcurrent', 'memoryMiB'});
      final c = l['maxConcurrent'];
      if (c != null && (c is! int || c < 1 || c > 4)) {
        issue('limits.maxConcurrent', 'must be 1..4');
      }
      final mem = l['memoryMiB'];
      if (mem != null && (mem is! int || mem < 64 || mem > 8192)) {
        issue('limits.memoryMiB', 'must be 64..8192');
      }
    }
  }

  final requires = m['requires'];
  if (requires != null) {
    if (requires is! List || requires.length > 8) {
      issue('requires', 'must be at most 8 entries');
    } else {
      for (var i = 0; i < requires.length; i++) {
        final r = requires[i];
        if (r is! Map) {
          issue('requires[$i]', 'must be an object');
          continue;
        }
        final entry = Map<String, Object?>.from(r);
        strictKeys('requires[$i].', entry, {'tool', 'minVersion'});
        final tool = entry['tool'];
        if (tool is! String || !_toolPattern.hasMatch(tool)) {
          issue('requires[$i].tool', 'must be a tool name');
        }
      }
    }
  }

  if (m['license'] != null) str(m, '', 'license', max: 64);
  final homepage = m['homepage'];
  if (homepage != null &&
      (homepage is! String ||
          homepage.length > 512 ||
          !homepage.startsWith('https://'))) {
    issue('homepage', 'must be an https URL');
  }

  if (issues.isNotEmpty ||
      pluginId == null ||
      version == null ||
      displayName == null) {
    return PluginManifestValidation(null, issues);
  }
  return PluginManifestValidation(
    PluginManifest(
      pluginId: pluginId,
      version: version,
      displayName: displayName,
      artifacts: Map.unmodifiable(artifacts),
      raw: Map.unmodifiable(m),
    ),
    issues,
  );
}

/// Highest protocol version both the manifest range and the host support,
/// or null when they do not overlap.
String? negotiatePluginProtocol(PluginManifest manifest) {
  final range = Map<String, Object?>.from(manifest.raw['protocol'] as Map);
  final minMinor = int.parse((range['min'] as String).split('.').last);
  final maxMinor = int.parse((range['max'] as String).split('.').last);
  String? best;
  var bestMinor = -1;
  for (final supported in PluginProtocolLimits.supportedProtocolVersions) {
    final minor = int.parse(supported.split('.').last);
    if (minor >= minMinor && minor <= maxMinor && minor > bestMinor) {
      best = supported;
      bestMinor = minor;
    }
  }
  return best;
}
