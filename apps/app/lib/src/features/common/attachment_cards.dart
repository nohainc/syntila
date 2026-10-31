import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';

import '../../ax/work_request_file_picker_stub.dart'
    if (dart.library.html) '../../ax/work_request_file_picker_web.dart'
    as work_request_files;

/// Bounded plain-text previews. Never interprets attached HTML or Markdown.
String? attachmentTextPreview(Map<String, dynamic> file) {
  if (file['previewText'] is String) return file['previewText'] as String;
  final type = file['mediaType']?.toString() ?? '';
  final name = file['name']?.toString() ?? '';
  if (!type.startsWith('text/') &&
      !RegExp(r'\.(txt|md|csv|json|yaml|yml|dart|ts|js|py|log)$',
              caseSensitive: false)
          .hasMatch(name)) {
    return null;
  }
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
          (scope?.open ?? defaultAttachmentOpener)(
              bytes, name, widget.file['mediaType']?.toString() ?? '');
          return;
        }
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            key: const ValueKey('attachment-image-viewer'),
            clipBehavior: Clip.antiAlias,
            child: Stack(children: [
              InteractiveViewer(
                maxScale: 8,
                child: Image.memory(Uint8List.fromList(bytes),
                    fit: BoxFit.contain),
              ),
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
