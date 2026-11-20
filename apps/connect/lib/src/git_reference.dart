/// Mirrors packages/core/src/git-reference.ts: the Agent refuses a Git
/// reference the server should never have sent (credentials, local paths,
/// branch-only commits, unknown fields). No git command is run here.
final _https = RegExp(
  r'^https://[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::\d{1,5})?/[A-Za-z0-9._~/-]{1,300}$',
);
final _ssh = RegExp(
  r'^ssh://git@[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::\d{1,5})?/[A-Za-z0-9._~/-]{1,300}$',
);
final _commit = RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$');
final _ref = RegExp(r'^refs/(?:heads|tags)/[A-Za-z0-9._/-]{1,200}$');

const maxGitReferences = 8;

bool _validRemote(String remote) {
  if (!_https.hasMatch(remote) && !_ssh.hasMatch(remote)) return false;
  final path = remote.substring(remote.indexOf('/', remote.indexOf('//') + 2));
  return !path.split('/').any((part) => part == '..' || part == '.');
}

bool _validRef(String ref) =>
    _ref.hasMatch(ref) &&
    !ref.contains('..') &&
    !ref.contains('//') &&
    !ref.endsWith('/') &&
    !ref.endsWith('.lock') &&
    !ref.split('/').any((part) => part.startsWith('.') || part.endsWith('.'));

bool validGitReference(Object? value) {
  if (value is! Map) return false;
  const allowed = {'kind', 'remote', 'commit', 'ref'};
  if (value.keys.any((key) => !allowed.contains(key))) return false;
  final remote = value['remote'];
  final commit = value['commit'];
  final ref = value['ref'];
  if (value['kind'] != 'git' || remote is! String || commit is! String) {
    return false;
  }
  if (!_validRemote(remote) || !_commit.hasMatch(commit)) return false;
  return ref == null || (ref is String && _validRef(ref));
}

/// True when [raw] is absent or a list of at most [maxGitReferences] valid references.
bool validGitReferences(Object? raw) {
  if (raw == null) return true;
  if (raw is! List || raw.length > maxGitReferences) return false;
  return raw.every(validGitReference);
}
