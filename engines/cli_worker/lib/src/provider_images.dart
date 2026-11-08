import 'dart:convert';
import 'dart:io';

/// Images a Worker produces for the user are left in
/// `.syntila/outputs/<assignment-id>/` under the working directory; the
/// Workspace uploads them with the assignment result. Workers save there
/// themselves; providers that keep generated images elsewhere are copied in.
const maxCapturedImages = 10;
const maxCapturedImageBytes = 20 * 1024 * 1024;
final _imageName = RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false);
final _threadId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

String outputImagesDirectory(String workingDirectory, String assignmentId) => [
  workingDirectory,
  '.syntila',
  'outputs',
  assignmentId,
].join(Platform.pathSeparator);

/// The Codex thread id reported by `codex exec --json` (`thread.started`).
String? codexThreadId(String stdout) {
  for (final line in const LineSplitter().convert(stdout)) {
    if (!line.contains('thread.started')) continue;
    try {
      final event = jsonDecode(line);
      final id = event is Map ? event['thread_id'] : null;
      if (id is String && _threadId.hasMatch(id)) return id;
    } on FormatException {
      continue;
    }
  }
  return null;
}

/// Codex's image tool writes to `$CODEX_HOME/generated_images/<thread-id>/`
/// and reports nothing about it on the `exec --json` stream. Copies the
/// images written since [since] into the assignment's output directory and
/// returns how many were copied.
Future<int> captureCodexImages({
  required String stdout,
  required String workingDirectory,
  required String assignmentId,
  required DateTime since,
  Map<String, String> environment = const {},
}) async {
  final threadId = codexThreadId(stdout);
  if (threadId == null) return 0;
  final home =
      environment['CODEX_HOME'] ??
      Platform.environment['CODEX_HOME'] ??
      [
        Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '',
        '.codex',
      ].join(Platform.pathSeparator);
  final source = Directory(
    [home, 'generated_images', threadId].join(Platform.pathSeparator),
  );
  if (!await source.exists()) return 0;
  final images = <File>[];
  await for (final entity in source.list(followLinks: false)) {
    if (entity is! File || !_imageName.hasMatch(entity.path)) continue;
    final stat = await entity.stat();
    if (stat.modified.isBefore(since) || stat.size > maxCapturedImageBytes) {
      continue;
    }
    images.add(entity);
  }
  if (images.isEmpty) return 0;
  images.sort((a, b) => a.path.compareTo(b.path));
  final target = Directory(
    outputImagesDirectory(workingDirectory, assignmentId),
  );
  await target.create(recursive: true);
  var copied = 0;
  for (final image in images.take(maxCapturedImages)) {
    final name = image.uri.pathSegments.last;
    await image.copy('${target.path}${Platform.pathSeparator}$name');
    copied += 1;
  }
  return copied;
}
