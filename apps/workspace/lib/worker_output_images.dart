import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Worker output images: pictures a Worker produced for the user. Workers
/// save them in `.syntila/outputs/<assignment-id>/` under the working
/// directory (the Engine also copies provider-kept images there). After the
/// run the Workspace uploads them and lists them in the result's
/// `output.images`, so the AI message shows them.
const maxWorkerOutputImages = 10;
const maxWorkerOutputImageBytes = 20 * 1024 * 1024;

const _mediaTypes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
};

String workerOutputImagesRelativePath(String assignmentId) =>
    '.syntila/outputs/$assignmentId';

/// Tells the Worker where images for the user go.
String promptWithOutputImages(String prompt, String assignmentId) =>
    '$prompt\n\nTo show the user an image (generated, rendered, or a '
    'screenshot), save it as a PNG, JPEG, GIF or WebP file in '
    '`${workerOutputImagesRelativePath(assignmentId)}/` in the current '
    'working directory. Images saved there are attached to your reply; do '
    'not embed them in Markdown.';

String? workerOutputImageMediaType(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  return _mediaTypes[path.substring(dot + 1).toLowerCase()];
}

/// Regular image files directly in the assignment's output directory, in
/// name order. Links and oversized files are ignored.
Future<List<File>> collectWorkerOutputImages(
  Directory workingDirectory,
  String assignmentId,
) async {
  final directory = Directory([
    workingDirectory.path,
    '.syntila',
    'outputs',
    assignmentId,
  ].join(Platform.pathSeparator));
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return const [];
  }
  final files = <File>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || workerOutputImageMediaType(entity.path) == null) {
      continue;
    }
    final length = await entity.length();
    if (length == 0 || length > maxWorkerOutputImageBytes) continue;
    files.add(entity);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
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
    final mediaType = workerOutputImageMediaType(name)!;
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
  void Function(Object error)? onError,
}) async {
  final images = <Map<String, Object?>>[];
  for (final file
      in await collectWorkerOutputImages(workingDirectory, assignmentId)) {
    try {
      images.add(await cloud.upload(assignmentId, file));
    } on Object catch (error) {
      onError?.call(error);
    }
  }
  return images;
}
