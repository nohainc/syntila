import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';

import '../../ax/work_request_file_picker_stub.dart'
    if (dart.library.html) '../../ax/work_request_file_picker_web.dart'
    as work_request_files;

/// Bounded plain-text previews. Never interprets attached HTML or Markdown.
bool attachmentIsText(String name, String mediaType) {
  final type = mediaType.toLowerCase();
  return type.startsWith('text/') ||
      const {
        'application/json',
        'application/xml',
        'application/javascript',
        'application/x-yaml',
        'application/toml'
      }.contains(type) ||
      RegExp(r'\.(txt|md|csv|json|jsonl|yaml|yml|xml|toml|dart|ts|tsx|js|jsx|py|log|html|css|sql|sh|rs|go|java|c|h|cpp)$',
              caseSensitive: false)
          .hasMatch(name);
}

bool _attachmentIsText(Map<String, dynamic> file) => attachmentIsText(
    file['name']?.toString() ?? '', file['mediaType']?.toString() ?? '');

String? attachmentTextPreview(Map<String, dynamic> file) {
  if (file['previewText'] is String) return file['previewText'] as String;
  if (!_attachmentIsText(file)) return null;
  final encoded = file['contentBase64'];
  if (encoded is! String) return null;
  try {
    final bytes = base64Decode(encoded);
    return utf8
        .decode(bytes.take(1200).toList(), allowMalformed: true)
        .replaceAll('\u0000', '');
  } on FormatException {
    return null;
  }
}

class AttachmentCards extends StatelessWidget {
  const AttachmentCards({super.key, required this.files, this.onRemove});
  final List<Map<String, dynamic>> files;
  final ValueChanged<int>? onRemove;
  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (var i = 0; i < files.length; i++)
          AttachmentCard(
              key: ValueKey('work-attachment-$i'),
              file: files[i],
              onRemove: onRemove == null ? null : () => onRemove!(i)),
      ]);
}

class AttachmentCard extends StatefulWidget {
  const AttachmentCard({super.key, required this.file, this.onRemove});
  final Map<String, dynamic> file;
  final VoidCallback? onRemove;
  @override
  State<AttachmentCard> createState() => _AttachmentCardState();
}

bool attachmentIsImage(Map<String, dynamic> file) =>
    (file['mediaType']?.toString() ?? '').startsWith('image/') ||
    RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false)
        .hasMatch(file['name']?.toString() ?? '');

class _AttachmentCardState extends State<AttachmentCard> {
  static const double _size = 96;
  bool _busy = false;
  bool _hovered = false;
  String? _thumbnailSource;
  Uint8List? _thumbnailBytes;

  /// Decodes the thumbnail once per source string. Re-decoding on every
  /// hover rebuild created a new MemoryImage and made the card flicker.
  Uint8List? _thumbnail() {
    final encoded = widget.file['previewImage'];
    if (encoded is! String || encoded.length > 32000) return null;
    if (encoded != _thumbnailSource) {
      _thumbnailSource = encoded;
      try {
        _thumbnailBytes = base64Decode(encoded);
      } on FormatException {
        _thumbnailBytes = null; // Fall back to file metadata.
      }
    }
    return _thumbnailBytes;
  }

  Future<List<int>> _bytes(AttachmentDownloadScope? scope) async {
    final encoded = widget.file['contentBase64'];
    if (encoded is String) return base64Decode(encoded);
    if (scope == null || widget.file['fileId'] is! String) {
      throw StateError('File content is unavailable');
    }
    return scope.load(widget.file);
  }

  Future<void> _run(Future<void> Function(AttachmentDownloadScope?) action,
      String failure) async {
    final scope =
        context.getInheritedWidgetOfExactType<AttachmentDownloadScope>();
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(scope);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$failure: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() => _run((scope) async {
        final bytes = await _bytes(scope);
        final name = widget.file['name']?.toString() ?? 'Attachment';
        if (!attachmentIsImage(widget.file)) {
          if (_attachmentIsText(widget.file)) {
            if (!mounted) return;
            const limit = 1024 * 1024;
            final text = utf8
                .decode(bytes.take(limit).toList(), allowMalformed: true)
                .replaceAll('\u0000', '');
            await showDialog<void>(
                context: context,
                builder: (context) => TextFileViewerDialog(
                      name: name,
                      text: text,
                      truncated: bytes.length > limit,
                      onDownload:
                          scope == null || widget.file['fileId'] is! String
                              ? null
                              : () async {
                                  try {
                                    await scope.download(widget.file, bytes);
                                  } catch (error) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(SnackBar(
                                              content: Text(
                                                  'Could not download file: $error')));
                                    }
                                  }
                                },
                    ));
          } else {
            (scope?.open ?? defaultAttachmentOpener)(
                bytes, name, widget.file['mediaType']?.toString() ?? '');
          }
          return;
        }
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => ImageViewerDialog(
            bytes: Uint8List.fromList(bytes),
            dialogKey: const ValueKey('attachment-image-viewer'),
          ),
        );
      }, 'Could not open file');

  Future<void> _download() => _run((scope) async {
        if (scope == null) return;
        await scope.download(widget.file, await _bytes(scope));
      }, 'Could not download file');

  @override
  Widget build(BuildContext context) {
    final preview = attachmentTextPreview(widget.file);
    final imageBytes = _thumbnail();
    final colors = Theme.of(context).colorScheme;
    final fallback = preview != null && preview.isNotEmpty
        ? Padding(
            padding: const EdgeInsets.all(8),
            child: Text(preview,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: SyntilaTypography.monoSmall))
        : const Center(child: Icon(Icons.insert_drive_file_outlined, size: 32));
    final canDownload = widget.file['fileId'] is String &&
        context.getInheritedWidgetOfExactType<AttachmentDownloadScope>() !=
            null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        label: widget.file['name']?.toString() ?? 'Attachment',
        button: true,
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x12000000), blurRadius: 2, offset: Offset(0, 1))
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: const ValueKey('attachment-open'),
                    onTap: _busy ? null : _open,
                    child: imageBytes != null
                        // Cover keeps the thumbnail's aspect and crops it
                        // around its center to fill the square.
                        ? Image.memory(imageBytes,
                            gaplessPlayback: true,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            cacheWidth: 320,
                            errorBuilder: (_, error, stack) => fallback)
                        : fallback,
                  ),
                ),
                if (_hovered && widget.onRemove != null)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: _OverlayIconButton(
                      tooltip: 'Remove attachment',
                      icon: Icons.close,
                      onPressed: widget.onRemove,
                    ),
                  ),
                if (_hovered && canDownload)
                  Positioned(
                    bottom: 4,
                    left: 4,
                    child: _OverlayIconButton(
                      tooltip: 'Download attachment',
                      icon: Icons.download,
                      onPressed: _busy ? null : _download,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TextFileViewerDialog extends StatelessWidget {
  const TextFileViewerDialog(
      {super.key,
      required this.name,
      required this.text,
      required this.truncated,
      this.onDownload});
  final String name;
  final String text;
  final bool truncated;
  final Future<void> Function()? onDownload;

  @override
  Widget build(BuildContext context) => Dialog(
        key: const ValueKey('attachment-text-viewer'),
        constraints: const BoxConstraints(),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: Column(children: [
              Row(children: [
                const SizedBox(width: 16),
                Expanded(
                    child: Text(name,
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (onDownload != null)
                  IconButton(
                      tooltip: 'Download file',
                      onPressed: onDownload,
                      icon: const Icon(Icons.download)),
                IconButton(
                    tooltip: 'Close preview',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close)),
              ]),
              if (truncated)
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                        'Showing the first 1 MiB. Download the file to view it all.')),
              const Divider(height: 1),
              Expanded(
                  child: Scrollbar(
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: SizedBox(
                              width: double.infinity,
                              child: SelectableText(text,
                                  style: SyntilaTypography.monoSmall))))),
            ])),
      );
}

/// Control on a translucent dark backdrop, legible over any image.
class _OverlayIconButton extends StatelessWidget {
  const _OverlayIconButton(
      {required this.tooltip,
      required this.icon,
      required this.onPressed,
      this.size = 22});
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.black.withValues(alpha: 0.5),
          shape: SyntilaRadius.buttonShape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            hoverColor: Colors.white.withValues(alpha: 0.12),
            child: SizedBox.square(
              dimension: size,
              child: Icon(icon, size: size * 0.6, color: Colors.white),
            ),
          ),
        ),
      );
}

typedef AttachmentOpener = void Function(
    List<int> bytes, String name, String mediaType);

/// Opens non-image files outside the app; replaced in tests.
AttachmentOpener defaultAttachmentOpener = work_request_files.openThreadFile;

class AttachmentDownloadScope extends InheritedWidget {
  const AttachmentDownloadScope(
      {super.key,
      required this.load,
      required this.download,
      this.open,
      required super.child});

  /// Fetches the original file bytes.
  final Future<List<int>> Function(Map<String, dynamic>) load;
  final Future<void> Function(Map<String, dynamic>, List<int>) download;
  final AttachmentOpener? open;
  @override
  bool updateShouldNotify(AttachmentDownloadScope oldWidget) =>
      load != oldWidget.load ||
      download != oldWidget.download ||
      open != oldWidget.open;
}

/// Base64 JPEG preview budget for Worker output images; Cloud and the
/// Workspace enforce the same value.
const maxResponseImagePreviewChars = 48000;

/// Images a Worker attached to its answer, shown inline below the text.
class ImageViewerDialog extends StatefulWidget {
  const ImageViewerDialog(
      {super.key, required this.bytes, required this.dialogKey});
  final Uint8List bytes;
  final Key dialogKey;

  @override
  State<ImageViewerDialog> createState() => _ImageViewerDialogState();
}

class _ImageViewerDialogState extends State<ImageViewerDialog> {
  late final Future<Size> _imageSize = _decodeSize();

  Future<Size> _decodeSize() {
    final completer = Completer<Size>();
    final stream = MemoryImage(widget.bytes).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (!completer.isCompleted) {
        completer.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()));
      }
      info.dispose();
      stream.removeListener(listener);
    }, onError: (Object error, StackTrace? stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
      stream.removeListener(listener);
    });
    stream.addListener(listener);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, bounds) => FutureBuilder<Size>(
          future: _imageSize,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return AlertDialog(
                content: const Text('Could not open image'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'))
                ],
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final imageSize = snapshot.data!;
            // Dialog's default inset is 40 horizontally and 24 vertically.
            final insets = MediaQuery.viewInsetsOf(context);
            final availableWidth =
                math.max(0.0, bounds.maxWidth - 80 - insets.horizontal);
            final availableHeight =
                math.max(0.0, bounds.maxHeight - 48 - insets.vertical);
            final scale = math.min(
                1.0,
                math.min(
                  availableWidth / imageSize.width,
                  availableHeight / imageSize.height,
                ));
            // Keep the close control usable even for very small images.
            final width = math.min(
                availableWidth, math.max(44.0, imageSize.width * scale));
            final height = math.min(
                availableHeight, math.max(44.0, imageSize.height * scale));
            return Dialog(
              key: widget.dialogKey,
              constraints: const BoxConstraints(),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                key: const ValueKey('image-viewer-content'),
                width: width,
                height: height,
                child: Stack(children: [
                  Positioned.fill(
                      child: InteractiveViewer(
                    maxScale: 8,
                    child: Image.memory(widget.bytes, fit: BoxFit.scaleDown),
                  )),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _OverlayIconButton(
                      tooltip: 'Close preview',
                      icon: Icons.close,
                      size: 28,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
      );
}

class ResponseImages extends StatelessWidget {
  const ResponseImages({super.key, required this.files});
  final List<Map<String, dynamic>> files;
  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final file in files)
            ResponseImage(
                key: ValueKey('response-image-${file['fileId']}'), file: file),
        ],
      );
}

class ResponseImage extends StatefulWidget {
  const ResponseImage({super.key, required this.file});
  final Map<String, dynamic> file;
  @override
  State<ResponseImage> createState() => _ResponseImageState();
}

class _ResponseImageState extends State<ResponseImage> {
  static const double _maxSize = 420;

  /// Recently shown images by file id, so a rebuilt timeline does not
  /// download them again.
  static final _cache = <String, Future<Uint8List>>{};
  Future<Uint8List>? _bytes;

  /// Inline size: the Workspace's small JPEG preview, when present. The
  /// original is then loaded only to zoom or download.
  Uint8List? _preview;
  bool _previewDecoded = false;
  bool _busy = false;

  Uint8List? get _previewBytes {
    if (!_previewDecoded) {
      _previewDecoded = true;
      final encoded = widget.file['previewImage'];
      if (encoded is String &&
          encoded.length <= maxResponseImagePreviewChars &&
          encoded.startsWith('/9j/')) {
        try {
          _preview = base64Decode(encoded);
        } on FormatException {
          _preview = null;
        }
      }
    }
    return _preview;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_previewBytes == null) _bytes ??= _load();
  }

  /// Loads the original for [action], keeping the preview on screen.
  Future<void> _withOriginal(Future<void> Function(Uint8List) action) async {
    if (_busy) return;
    _bytes ??= _load();
    final future = _bytes;
    if (future == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await future;
      if (bytes.isEmpty) throw StateError('Image unavailable');
      if (mounted) await action(bytes);
    } catch (error) {
      _bytes = null; // Retry on the next tap.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not load image: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List>? _load() {
    final fileId = widget.file['fileId'];
    final scope =
        context.getInheritedWidgetOfExactType<AttachmentDownloadScope>();
    if (fileId is! String || scope == null) return null;
    final cached = _cache.remove(fileId);
    final future = cached ??
        scope.load(widget.file).then((bytes) => Uint8List.fromList(bytes));
    _cache[fileId] = future;
    if (_cache.length > 24) _cache.remove(_cache.keys.first);
    // A failed download is retried the next time the image is built.
    future.catchError((Object _) {
      _cache.remove(fileId);
      return Uint8List(0);
    });
    return future;
  }

  Future<void> _view(Uint8List bytes) => showDialog<void>(
        context: context,
        builder: (context) => ImageViewerDialog(
          bytes: bytes,
          dialogKey: const ValueKey('response-image-viewer'),
        ),
      );

  Future<void> _download(Uint8List bytes) async {
    final scope =
        context.getInheritedWidgetOfExactType<AttachmentDownloadScope>();
    try {
      await scope?.download(widget.file, bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not download image: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = widget.file['name']?.toString() ?? 'Image';
    Widget placeholder(Widget child) => Container(
          width: 240,
          height: 160,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: child,
        );
    final preview = _previewBytes;
    if (preview != null) {
      return Semantics(
        label: name,
        image: true,
        child: _frame(
          image: Image.memory(
            preview,
            gaplessPlayback: true,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                placeholder(const Icon(Icons.broken_image_outlined)),
          ),
          onOpen: () => _withOriginal(_view),
          onDownload: () => _withOriginal(_download),
        ),
      );
    }
    return Semantics(
      label: name,
      image: true,
      child: FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (snapshot.hasError ||
              (bytes != null && bytes.isEmpty) ||
              _bytes == null) {
            return placeholder(Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image_outlined,
                    color: colors.onSurfaceVariant),
                const SizedBox(height: 4),
                Text('Image unavailable',
                    style: TextStyle(
                        fontSize: 12, color: colors.onSurfaceVariant)),
              ],
            ));
          }
          if (bytes == null) {
            return placeholder(const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2)));
          }
          return _frame(
            image: Image.memory(
              bytes,
              gaplessPlayback: true,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  placeholder(const Icon(Icons.broken_image_outlined)),
            ),
            onOpen: () => _view(bytes),
            onDownload: () => _download(bytes),
          );
        },
      ),
    );
  }

  Widget _frame({
    required Widget image,
    required VoidCallback onOpen,
    required VoidCallback onDownload,
  }) =>
      ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: _maxSize, maxHeight: _maxSize),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(children: [
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: const ValueKey('response-image-open'),
                onTap: _busy ? null : onOpen,
                child: image,
              ),
            ),
            if (_busy)
              const Positioned.fill(
                child: Center(
                  child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: _OverlayIconButton(
                tooltip: 'Download image',
                icon: Icons.download_outlined,
                onPressed: _busy ? null : onDownload,
              ),
            ),
          ]),
        ),
      );
}
