import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:path/path.dart' as p;

/// Images a Worker made for the user (ADR-035 path). The Worker is told to
/// save them in the assignment's own `outputs` folder; providers that keep
/// generated images elsewhere and only link them in the reply (Antigravity's
/// `brain` folder, Codex's `generated_images`) are picked up from the links.
/// Connect uploads them and the result lists them in `output.images`.
const maxOutputImages = 10;
const maxOutputImageBytes = 20 * 1024 * 1024;

/// Local paths the Engine adapter hands to [ArtifactLauncher]; replaced by
/// uploaded descriptors and never sent to Cloud.
const localOutputImagesKey = 'localOutputImages';

final _imageName = RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false);

/// The prompt with the place to save images for the user.
String promptWithOutputImages(String prompt, String directory) =>
    '$prompt\n\nTo show the user an image (generated, rendered, or a '
    'screenshot), save it in `$directory`. Do not embed it in Markdown or '
    'mention the file path in your reply.';

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

/// Regular image files directly in [directories], then [linked] files, at most
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
      if (e is File && _imageName.hasMatch(e.path)) names.add(e.path);
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
