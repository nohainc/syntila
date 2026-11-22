import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:path/path.dart' as p;

/// Files a Worker made for the user (ADR-035 path): images, audio, documents.
/// The Worker is told to save them in the assignment's own `outputs` folder,
/// and every regular file there is sent. Providers that keep
/// generated images elsewhere and only link them in the reply (Antigravity's
/// `brain` folder, Codex's `generated_images`) are picked up from the links.
/// Connect uploads them and the result lists them in `output.images`.
const maxOutputImages = 10;

/// A local cap only; Cloud enforces the owner's plan limit.
const maxOutputImageBytes = 100 * 1024 * 1024;

/// Local paths the Engine adapter hands to [ArtifactLauncher]; replaced by
/// uploaded descriptors and never sent to Cloud.
const localOutputImagesKey = 'localOutputImages';

final _imageName = RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false);

/// The prompt with the place to save images for the user.
String promptWithOutputImages(String prompt, String directory) =>
    '$prompt\n\nTo give the user a file (an image, screenshot, audio, '
    'document or any other generated file), save it in `$directory`. Do not '
    'embed it in Markdown or mention the file path in your reply. Save video '
    'as H.264 MP4 or WebM and audio as MP3, M4A or WAV so it plays in a '
    'browser.';

/// Markdown links (`![x](path)` or `[x](path)`) and bare `file://` URLs.
final _link = RegExp(
  r'!?\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?\s*\)|(file://[^\s)>\]]+)',
);

String? _localPath(String target) {
  var value = target;
  if (value.startsWith('file://')) {
    try {
      value = Uri.parse(value).toFilePath();
    } on Object {
      return null;
    }
  } else {
    value = Uri.decodeFull(value);
  }
  return p.isAbsolute(value) ? p.normalize(value) : null;
}

/// The image files the reply links to that lie under one of [roots]; other
/// paths are never read.
List<String> linkedImages(String text, List<String> roots) {
  final normalized = [for (final r in roots) p.normalize(r)];
  final found = <String>[];
  for (final match in _link.allMatches(text)) {
    final path = _localPath(match.group(1) ?? match.group(2)!);
    if (path == null || !_imageName.hasMatch(path)) continue;
    if (!normalized.any((root) => p.isWithin(root, path))) continue;
    if (!found.contains(path)) found.add(path);
  }
  return found;
}

/// Removes the links to [paths] from the reply; the images are shown instead.
String withoutImageLinks(String text, Iterable<String> paths) {
  final set = paths.toSet();
  if (set.isEmpty) return text;
  final stripped = text.replaceAllMapped(_link, (m) {
    final path = _localPath(m.group(1) ?? m.group(2)!);
    return path != null && set.contains(path) ? '' : m[0]!;
  });
  return stripped.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// Regular files directly in [directories], then [linked] images, at most
/// [maxOutputImages], each non-empty and within the size limit.
Future<List<String>> collectOutputImages(
  List<String> directories,
  List<String> linked,
) async {
  final candidates = <String>[];
  for (final dir in directories) {
    final directory = Directory(dir);
    if (await FileSystemEntity.type(dir, followLinks: false) !=
        FileSystemEntityType.directory) {
      continue;
    }
    final names = <String>[];
    await for (final e in directory.list(followLinks: false)) {
      if (e is File) names.add(e.path);
    }
    names.sort();
    candidates.addAll(names);
  }
  candidates.addAll(linked);
  final result = <String>[];
  final seen = <String>{};
  for (final path in candidates) {
    if (result.length >= maxOutputImages) break;
    if (!seen.add(p.normalize(path))) continue;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    final length = await File(path).length();
    if (length == 0 || length > maxOutputImageBytes) continue;
    result.add(path);
  }
  return result;
}

/// Where providers keep images they generate outside the working directory.
List<String> providerImageRoots(Map<String, String> environment) {
  final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '';
  if (home.isEmpty) return const [];
  return [
    p.join(home, '.gemini', 'antigravity-cli', 'brain'),
    p.join(
      environment['CODEX_HOME'] ?? p.join(home, '.codex'),
      'generated_images',
    ),
  ];
}

/// Longest side of the inline preview, in pixels.
const outputImagePreviewMaxSide = 480;

/// Base64 JPEG preview budget; Cloud and the app enforce the same value.
const maxOutputImagePreviewChars = 48000;

/// The small inline version of an output image, made off the main isolate:
/// a base64 JPEG within [maxOutputImagePreviewChars], or null when the image
/// cannot be decoded. The uploaded original stays the full size.
Future<String?> outputImagePreview(File image) async {
  final bytes = await image.readAsBytes();
  return Isolate.run(() => encodeOutputImagePreview(bytes));
}

String? encodeOutputImagePreview(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    return null;
  }
  if (decoded == null) return null;
  var side = outputImagePreviewMaxSide;
  while (side >= 64) {
    final scaled = decoded.width >= decoded.height
        ? (decoded.width > side
              ? img.copyResize(decoded, width: side)
              : decoded)
        : (decoded.height > side
              ? img.copyResize(decoded, height: side)
              : decoded);
    // JPEG has no alpha: flatten onto white so transparent areas stay light.
    final flat = scaled.hasAlpha
        ? img.compositeImage(
            img.Image(width: scaled.width, height: scaled.height)
              ..clear(img.ColorRgb8(255, 255, 255)),
            scaled,
          )
        : scaled;
    for (final quality in const [82, 68, 54]) {
      final encoded = base64Encode(img.encodeJpg(flat, quality: quality));
      if (encoded.length <= maxOutputImagePreviewChars) return encoded;
    }
    side = side * 3 ~/ 4;
  }
  return null;
}

const _mediaTypes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
  'html': 'text/html',
  'xml': 'application/xml',
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'wav': 'audio/wav',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
};

/// The media type the upload is sent with, from the file name.
String outputFileMediaType(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return _mediaTypes[ext] ?? 'application/octet-stream';
}

/// Whether a preview image can be made for [name].
bool isOutputImage(String name) => _imageName.hasMatch(name);

final _videoName = RegExp(
  r'\.(mp4|m4v|mov|webm|mkv|avi)$',
  caseSensitive: false,
);

/// Whether a poster frame can be tried for [name].
bool isOutputVideo(String name) => _videoName.hasMatch(name);

/// Finds `ffmpeg`: on PATH, then the usual Homebrew and system places (a GUI
/// app starts with a short PATH). Null when it is not installed.
String? findFfmpeg([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final windows = Platform.isWindows;
  final name = windows ? 'ffmpeg.exe' : 'ffmpeg';
  final dirs = [
    ...?env['PATH']?.split(windows ? ';' : ':'),
    if (!windows) ...['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'],
  ];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final candidate = p.join(dir, name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// A poster preview for a video: one frame taken by `ffmpeg` about a second
/// in (or the first frame for a short clip), made into the same small JPEG
/// as image previews. Null without `ffmpeg` or when no frame can be read.
Future<String?> outputVideoPreview(
  File video, {
  String? ffmpeg,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final tool = ffmpeg ?? findFfmpeg();
  if (tool == null) return null;
  final dir = await Directory.systemTemp.createTemp('syntila-poster-');
  try {
    final frame = p.join(dir.path, 'frame.png');
    for (final at in const ['1', '0']) {
      final result = await Process.run(tool, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-ss',
        at,
        '-i',
        video.path,
        '-frames:v',
        '1',
        '-y',
        frame,
      ]).timeout(timeout);
      final file = File(frame);
      if (result.exitCode == 0 &&
          await file.exists() &&
          await file.length() > 0) {
        return await outputImagePreview(file);
      }
    }
    return null;
  } on Object {
    return null;
  } finally {
    await dir.delete(recursive: true).catchError((_) => dir);
  }
}
