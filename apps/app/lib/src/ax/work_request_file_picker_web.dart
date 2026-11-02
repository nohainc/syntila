// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'attachment_limits.dart';
import 'ax_files.dart' show formatFileSize;

/// Opens a multi-select file dialog. Files that would break the count or
/// size limit are skipped individually and reported in `notice`.
Future<({List<Map<String, dynamic>> files, String? notice})>
    pickWorkRequestFiles({int existing = 0}) async {
  // Attach the input to the DOM and listen before clicking: detached inputs
  // can drop the change event in some browsers, leaving the selection unseen.
  final input = html.FileUploadInputElement()
    ..multiple = true
    ..style.display = 'none';
  final selected = Completer<List<html.File>>();
  input.onChange.first.then((_) {
    if (!selected.isCompleted) selected.complete(input.files ?? <html.File>[]);
  });
  input.addEventListener('cancel', (_) {
    if (!selected.isCompleted) selected.complete(<html.File>[]);
  });
  html.document.body?.append(input);
  input.click();
  final List<html.File> files;
  try {
    files = await selected.future;
  } finally {
    input.remove();
  }
  final admission = admitAttachments(existing: existing, candidates: [
    for (final file in files) (name: file.name, sizeBytes: file.size)
  ]);
  return (
    files: await readWorkRequestFiles(
        [for (final index in admission.accepted) files[index]]),
    notice: admission.notice,
  );
}

/// Reads browser files into the bounded request attachment payload.
Future<List<Map<String, dynamic>>> readWorkRequestFiles(
    List<html.File> files) async {
  final limit = AxAttachmentPolicy.instance.maxFileBytes;
  if (files.length > maxAttachmentCount ||
      files.any((file) => file.size > limit)) {
    throw FormatException(
      'Choose up to $maxAttachmentCount files, each at most ${formatFileSize(limit)}.',
    );
  }
  final result = <Map<String, dynamic>>[];
  for (final file in files) {
    final reader = html.FileReader();
    final loaded = Completer<void>();
    final load = reader.onLoad.listen((_) {
      if (!loaded.isCompleted) loaded.complete();
    });
    final error = reader.onError.listen((_) {
      if (!loaded.isCompleted) {
        loaded.completeError(FormatException('Could not read "${file.name}".'));
      }
    });
    final abort = reader.onAbort.listen((_) {
      if (!loaded.isCompleted) {
        loaded.completeError(
            FormatException('Reading "${file.name}" was cancelled.'));
      }
    });
    try {
      reader.readAsArrayBuffer(file);
      await loaded.future;
    } finally {
      await load.cancel();
      await error.cancel();
      await abort.cancel();
    }
    final data = reader.result;
    final Uint8List bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is ByteBuffer) {
      bytes = data.asUint8List();
    } else {
      throw FormatException('Could not read "${file.name}".');
    }
    result.add({
      'kind': 'file',
      'name': file.name,
      'mediaType': file.type.isEmpty ? 'application/octet-stream' : file.type,
      'sizeBytes': bytes.length,
      'contentBase64': base64Encode(bytes),
      if (await _imagePreview(file, bytes) case final preview?)
        'previewImage': preview,
    });
  }
  return result;
}

/// Upper bound for the base64 thumbnail; Cloud enforces the same value.
const maxPreviewImageChars = 32000;
const _thumbnailEdge = 256;

/// Square JPEG thumbnails for raster images, matching the square card.
/// Small JPEGs are used as-is; others are center-cropped to 256 px (sharp at
/// 2-3x density on the 96 px card), downscaled in halving steps with high
/// quality smoothing, and encoded at the best quality that fits the budget.
Future<String?> _imagePreview(html.File file, Uint8List bytes) async {
  if (!const {'image/png', 'image/jpeg', 'image/webp', 'image/gif'}
      .contains(file.type)) {
    return null;
  }
  if (file.type == 'image/jpeg' &&
      bytes.length * 4 / 3 <= maxPreviewImageChars) {
    final original = base64Encode(bytes);
    if (original.startsWith('/9j/')) return original;
  }
  final url = html.Url.createObjectUrlFromBlob(file);
  try {
    final image = html.ImageElement(src: url);
    await image.onLoad.first.timeout(const Duration(seconds: 5));
    final width = image.naturalWidth, height = image.naturalHeight;
    if (width == 0 || height == 0) return null;
    // Center square crop of the source.
    final side = width < height ? width : height;
    final sx = (width - side) ~/ 2, sy = (height - side) ~/ 2;
    final target = side < _thumbnailEdge ? side : _thumbnailEdge;
    var current = html.CanvasElement(width: side, height: side);
    current.context2D
      ..setFillColorRgb(255, 255, 255)
      ..fillRect(0, 0, side, side)
      ..drawImageScaledFromSource(image, sx, sy, side, side, 0, 0, side, side);
    // Halving steps avoid the aliasing of one large canvas downscale.
    var edge = side;
    while (edge > target) {
      edge = edge ~/ 2 < target ? target : edge ~/ 2;
      final next = html.CanvasElement(width: edge, height: edge);
      next.context2D
        ..imageSmoothingEnabled = true
        ..imageSmoothingQuality = 'high'
        ..drawImageScaled(current, 0, 0, edge, edge);
      current = next;
    }
    for (final quality in const [0.85, 0.75, 0.6]) {
      final encoded = current.toDataUrl('image/jpeg', quality).split(',').last;
      if (encoded.length <= maxPreviewImageChars) return encoded;
    }
    return null;
  } on Object {
    return null;
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}

/// Downloads an attachment without navigating away from the app.
void saveThreadFile(List<int> bytes, String name) {
  final url = html.Url.createObjectUrlFromBlob(
    html.Blob([Uint8List.fromList(bytes)], 'application/octet-stream'),
  );
  final link = html.AnchorElement(href: url)
    ..download = name
    ..style.display = 'none';
  html.document.body?.append(link);
  try {
    link.click();
  } finally {
    link.remove();
    Timer(const Duration(minutes: 1), () => html.Url.revokeObjectUrl(url));
  }
}

/// Opens browser-safe attachments; active content is downloaded instead.
void openThreadFile(List<int> bytes, String name, String mediaType) {
  final type = mediaType.split(';').first.trim().toLowerCase();
  if (!const {
    'application/pdf',
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'text/plain',
  }.contains(type)) {
    saveThreadFile(bytes, name);
    return;
  }
  final url = html.Url.createObjectUrlFromBlob(
    html.Blob([Uint8List.fromList(bytes)], type),
  );
  final link = html.AnchorElement(href: url)
    ..target = '_blank'
    ..rel = 'noopener noreferrer'
    ..style.display = 'none';
  html.document.body?.append(link);
  try {
    link.click();
  } finally {
    link.remove();
    Timer(const Duration(minutes: 1), () => html.Url.revokeObjectUrl(url));
  }
}
