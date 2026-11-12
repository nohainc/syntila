import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:mime/mime.dart' as mime;

/// Worker output files: files a Worker produced for the user. Workers
/// save them in `.syntila/outputs/<assignment-id>/` under the working
/// directory (the Engine also copies provider-kept images there). After the
/// run the Workspace uploads them and lists them in the result's
/// `output.images`, so the AI message shows them.
const maxWorkerOutputImages = 10;

const _mediaTypes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
};

String workerOutputImagesRelativePath(String assignmentId) =>
    '.syntila/outputs/$assignmentId';

/// Tells the Worker where files for the user go.
String promptWithOutputImages(
  String prompt,
  String assignmentId, {
  String? workingDirectoryPath,
}) {
  final dir = workingDirectoryPath == null || workingDirectoryPath.isEmpty
      ? '${workerOutputImagesRelativePath(assignmentId)}/'
      : [
          workingDirectoryPath.replaceFirst(RegExp(r'[/\\]+$'), ''),
          '.syntila',
          'outputs',
          assignmentId,
          '',
        ].join(Platform.pathSeparator);
  final location = workingDirectoryPath == null || workingDirectoryPath.isEmpty
      ? '`$dir` in the current working directory'
      : '`$dir`';
  return '$prompt\n\nTo show the user an image (generated, rendered, or a '
      'screenshot), or provide a generated file, save it in $location. '
      'Do not embed them in Markdown or mention the output file path in your '
      'reply.';
}

String? workerOutputImageMediaType(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  return _mediaTypes[path.substring(dot + 1).toLowerCase()];
}

/// Regular files directly in the assignment's output directory under
/// [workingDirectory] (or any of [additionalDirectories]), in name order.
/// Links and empty files are ignored; Cloud enforces the owner’s plan limits.
Future<List<File>> collectWorkerOutputImages(
  Directory workingDirectory,
  String assignmentId, {
  List<String> additionalDirectories = const [],
}) async {
  final roots = <String>{
    workingDirectory.path,
    for (final path in additionalDirectories)
      if (path.isNotEmpty) path,
  };
  final files = <File>[];
  final seenNames = <String>{};
  for (final root in roots) {
    final directory = Directory([
      root,
      '.syntila',
      'outputs',
      assignmentId,
    ].join(Platform.pathSeparator));
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      continue;
    }
    final dirFiles = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final length = await entity.length();
      if (length == 0) continue;
      dirFiles.add(entity);
    }
    dirFiles.sort((a, b) => a.path.compareTo(b.path));
    for (final file in dirFiles) {
      if (seenNames.add(file.uri.pathSegments.last)) {
        files.add(file);
      }
    }
  }
  files.sort(
    (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
  );
  return files.take(maxWorkerOutputImages).toList(growable: false);
}

abstract class WorkerOutputImageCloud {
  /// Uploads one image and returns its descriptor for `output.images`.
  Future<Map<String, Object?>> upload(String assignmentId, File image);
}

/// HTTPS client authenticated with the Workspace runtime credential.
class HttpWorkerOutputImageCloud implements WorkerOutputImageCloud {
  HttpWorkerOutputImageCloud({
    required this.cloudUri,
    required this.workspaceRuntimeId,
    required this.authToken,
    HttpClient? client,
    this.timeout = const Duration(seconds: 60),
  }) : _client = client ?? HttpClient();

  final Uri cloudUri;
  final String workspaceRuntimeId;
  final String authToken;
  final Duration timeout;
  final HttpClient _client;

  Uri _uri(String assignmentId, String name) {
    final scheme = switch (cloudUri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      'https' || 'http' => cloudUri.scheme,
      _ => throw ArgumentError('Cloud URL must use HTTP or WebSocket'),
    };
    final existing = cloudUri.path.replaceFirst(RegExp(r'/$'), '');
    final prefix =
        existing.isEmpty || existing.endsWith('/api/workspace-gateway/connect')
            ? ''
            : existing;
    return cloudUri.replace(
      scheme: scheme,
      path: '$prefix/api/workspace-runtime/outputs',
      queryParameters: {
        'workspaceRuntimeId': workspaceRuntimeId,
        'assignmentId': assignmentId,
        'name': name,
      },
      fragment: null,
      userInfo: '',
    );
  }

  @override
  Future<Map<String, Object?>> upload(String assignmentId, File image) async {
    final name = image.uri.pathSegments.last;
    final mediaType = mime.lookupMimeType(name) ?? 'application/octet-stream';
    final request =
        await _client.postUrl(_uri(assignmentId, name)).timeout(timeout);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $authToken')
      ..set(HttpHeaders.contentTypeHeader, mediaType);
    request.contentLength = await image.length();
    await request.addStream(image.openRead());
    final response = await request.close().timeout(timeout);
    final text = await utf8.decodeStream(response).timeout(timeout);
    if (response.statusCode != HttpStatus.created) {
      throw HttpException('Image upload returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(text);
    final descriptor = decoded is Map ? decoded['image'] : null;
    if (descriptor is! Map || descriptor['fileId'] is! String) {
      throw const FormatException('Image upload returned no descriptor');
    }
    return Map<String, Object?>.from(descriptor);
  }
}

/// Uploads the assignment's output images. An image that fails to upload is
/// skipped so the text answer is never lost.
Future<List<Map<String, Object?>>> publishWorkerOutputImages({
  required WorkerOutputImageCloud cloud,
  required Directory workingDirectory,
  required String assignmentId,
  List<String> additionalDirectories = const [],
  Future<String?> Function(File image)? previewImage,
  void Function(Object error)? onError,
}) async {
  final images = <Map<String, Object?>>[];
  for (final file in await collectWorkerOutputImages(
    workingDirectory,
    assignmentId,
    additionalDirectories: additionalDirectories,
  )) {
    try {
      final descriptor = await cloud.upload(assignmentId, file);
      String? preview;
      try {
        if (workerOutputImageMediaType(file.path) != null) {
          preview = await (previewImage ?? workerOutputImagePreview)(file);
        }
      } on Object catch (error) {
        // The original stays usable; the app then loads it for display.
        onError?.call(error);
      }
      images.add({
        ...descriptor,
        if (preview != null) 'previewImage': preview,
      });
    } on Object catch (error) {
      onError?.call(error);
    }
  }
  return images;
}

/// Longest side of the inline preview, in pixels.
const workerOutputImagePreviewMaxSide = 480;

/// Base64 JPEG preview budget; Cloud and the app enforce the same value.
const maxWorkerOutputImagePreviewChars = 48000;

/// The small inline size of an output image: a base64 JPEG no longer than
/// [maxWorkerOutputImagePreviewChars], or null when the image cannot be
/// decoded. The uploaded original remains the zoom and download size.
Future<String?> workerOutputImagePreview(File image) async {
  final bytes = await image.readAsBytes();
  return Isolate.run(() => encodeWorkerOutputImagePreview(bytes));
}

String? encodeWorkerOutputImagePreview(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    return null; // Undecodable: the app falls back to the original.
  }
  if (decoded == null) return null;
  var side = workerOutputImagePreviewMaxSide;
  while (side >= 64) {
    final scaled = decoded.width >= decoded.height
        ? (decoded.width > side
            ? img.copyResize(decoded, width: side)
            : decoded)
        : (decoded.height > side
            ? img.copyResize(decoded, height: side)
            : decoded);
    // JPEG has no alpha; flatten onto white so transparent areas stay light.
    final flat = scaled.hasAlpha
        ? img.compositeImage(
            img.Image(width: scaled.width, height: scaled.height)
              ..clear(img.ColorRgb8(255, 255, 255)),
            scaled)
        : scaled;
    for (final quality in const [82, 68, 54]) {
      final encoded = base64Encode(img.encodeJpg(flat, quality: quality));
      if (encoded.length <= maxWorkerOutputImagePreviewChars) return encoded;
    }
    side = side * 3 ~/ 4;
  }
  return null;
}
