import 'dart:async';

import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';
import '../common/syntila_markdown_body.dart';
import '../common/composer_metrics.dart';
import '../common/dictation/dictation_button.dart';
import '../common/dictation/speech_dictation.dart';
import '../common/emoji_picker.dart';
import '../common/markdown_composer.dart';

typedef NoteSave = Future<AxNote> Function(
    {required String title, required String body, int? revision});

/// Commands for a mounted [NoteEditor].
class NoteEditorController {
  Future<void> Function()? _clear;

  Future<void> clear() => _clear?.call() ?? Future<void>.value();
}

/// Markdown editor for one private note. Text saves automatically shortly
/// after typing stops and when the editor closes. A save that lost to a newer
/// version (another device) reloads the latest text instead of overwriting it.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.load,
    required this.save,
    this.showTitle = false,
    this.hint = 'Write private notes…',
    this.saveDelay = const Duration(milliseconds: 800),
    this.onSaved,
    this.dictation,
    this.controller,
  });

  /// Loads the note; null means it does not exist yet (first save creates it).
  final Future<AxNote?> Function() load;
  final NoteSave save;
  final bool showTitle;
  final String hint;
  final Duration saveDelay;
  final ValueChanged<AxNote>? onSaved;
  final NoteEditorController? controller;

  /// Overrides the platform speech recognizer (tests).
  final SpeechDictation? dictation;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  AxNote? _note;
  bool _loading = true;
  late Future<void> _loadPending;
  String? _error;
  String? _status;
  Timer? _timer;
  Future<void>? _saving;
  bool _dirty = false;
  // Saved notes open formatted and read-only; empty ones open for writing.
  bool _editing = false;
  Duration? _lastPointerDown;
  bool _loadingText = false;
  final _focus = FocusNode();
  final _markdownMenu = MenuController();

  static const _formats = [
    (MarkdownFormat.bold, 'Bold', Icons.format_bold),
    (MarkdownFormat.italic, 'Italic', Icons.format_italic),
    (MarkdownFormat.heading, 'Heading', Icons.title),
    (MarkdownFormat.inlineCode, 'Inline code', Icons.code),
    (MarkdownFormat.codeBlock, 'Code block', Icons.data_object),
    (MarkdownFormat.quote, 'Quote', Icons.format_quote),
    (MarkdownFormat.link, 'Link', Icons.link),
    (MarkdownFormat.bulletList, 'Bullet list', Icons.format_list_bulleted),
    (MarkdownFormat.numberedList, 'Numbered list', Icons.format_list_numbered),
    (MarkdownFormat.taskList, 'Task list', Icons.checklist),
  ];

  String _lastBody = '';

  @override
  void initState() {
    super.initState();
    widget.controller?._clear = _clear;
    // Emoji, formatting and dictation edit the controller directly, so save
    // on any text change rather than only on typing.
    _body.addListener(_bodyChanged);
    _loadPending = _load();
  }

  @override
  void didUpdateWidget(covariant NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._clear = null;
      widget.controller?._clear = _clear;
    }
  }

  void _bodyChanged() {
    if (_body.text == _lastBody) return;
    _lastBody = _body.text;
    if (!_loadingText) _changed();
  }

  void _format(MarkdownFormat format) {
    formatMarkdown(_body, format);
    _focus.requestFocus();
  }

  void _insertEmoji(String emoji) {
    insertAtCursor(_body, emoji);
    _focus.requestFocus();
  }

  @override
  void dispose() {
    if (widget.controller?._clear == _clear) widget.controller?._clear = null;
    _timer?.cancel();
    if (_dirty) unawaited(_save());
    _title.dispose();
    _body.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _clear() async {
    // The header is available before the note finishes loading. Clear the
    // loaded content rather than treating the initial empty controller as saved.
    await _loadPending;
    if (!mounted || _error != null || _body.text.isEmpty) return;
    _timer?.cancel();
    if (mounted) setState(() => _editing = true);
    _body.clear();
    _timer?.cancel();
    await _save();
  }

  Future<void> _load({String? status}) async {
    try {
      final note = await widget.load();
      if (!mounted) return;
      setState(() {
        _note = note;
        _title.text = note?.title ?? '';
        _loadingText = true;
        _body.text = note?.body ?? '';
        _loadingText = false;
        // A reload (conflict) keeps the user in the editor.
        _editing = _editing || _body.text.trim().isEmpty;
        _loading = false;
        _error = null;
        _dirty = false;
        _status = status;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Notes could not be loaded.';
      });
    }
  }

  void _changed() {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(widget.saveDelay, () => unawaited(_save()));
    if (_status != null && mounted) setState(() => _status = null);
  }

  Future<void> _save() async {
    if (!_dirty) return;
    // Read the text now: this also runs from dispose, before the
    // controllers go away.
    _dirty = false;
    final title = _title.text;
    final body = _body.text;
    // One save at a time, in order, each with the latest revision.
    while (_saving != null) {
      await _saving;
    }
    final saving = () async {
      try {
        final saved = await widget.save(
            title: title, body: body, revision: _note?.revision);
        _note = saved;
        widget.onSaved?.call(saved);
        if (mounted) setState(() => _status = 'Saved');
      } on AxApiException catch (error) {
        if (error.statusCode == 409) {
          if (mounted) {
            await _load(
                status: 'This note changed elsewhere. Showing the latest '
                    'version.');
          }
        } else {
          _dirty = true;
          if (mounted) setState(() => _status = 'Not saved. Retrying…');
          _timer?.cancel();
          if (mounted) {
            _timer =
                Timer(const Duration(seconds: 5), () => unawaited(_save()));
          }
        }
      } on Object {
        _dirty = true;
        if (mounted) setState(() => _status = 'Not saved. Retrying…');
        _timer?.cancel();
        if (mounted) {
          _timer = Timer(const Duration(seconds: 5), () => unawaited(_save()));
        }
      }
    }();
    _saving = saving;
    try {
      await saving;
    } finally {
      _saving = null;
    }
  }

  @override
  Widget build(BuildContext context) => TooltipVisibility(
        visible: false,
        child: _buildContent(context),
      );

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              setState(() => _loading = true);
              _loadPending = _load();
            },
            child: const Text('Retry'),
          ),
        ]),
      );
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle)
          TextField(
            key: const ValueKey('note-title'),
            controller: _title,
            onChanged: (_) => _changed(),
            maxLength: 200,
            style: Theme.of(context).textTheme.titleMedium,
            decoration: const InputDecoration(
              hintText: 'Title',
              border: InputBorder.none,
              counterText: '',
            ),
          ),
        if (widget.showTitle) const SizedBox(height: 6),
        _toolbar(),
        Expanded(
          child: !_editing
              ? _readView()
              : TextField(
                  key: const ValueKey('note-body'),
                  controller: _body,
                  focusNode: _focus,
                  maxLines: null,
                  expands: true,
                  maxLength: 200000,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    border: InputBorder.none,
                    counterText: '',
                  ),
                ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.lock_outline_rounded, size: 14, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _status ?? 'Only you can see these notes.',
              key: const ValueKey('note-status'),
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _toolbar() {
    final color = Theme.of(context).colorScheme.onSurface;
    // Edit/Done on the left, a separator, then the editing tools. The tools
    // are always shown and stay disabled until editing starts.
    // The tools take an explicit colour, so they need the disabled one too.
    final toolColor = _editing ? color : Theme.of(context).disabledColor;
    final editStyle = TextButton.styleFrom(
      foregroundColor: color,
      minimumSize: const Size(0, composerButtonSize),
      fixedSize: const Size.fromHeight(composerButtonSize),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(composerButtonRadius),
      ),
    );
    return Row(children: [
      _editing
          ? TextButton(
              key: const ValueKey('note-done'),
              style: editStyle,
              onPressed: _finishEditing,
              child: const Text('Done'),
            )
          : TextButton(
              key: const ValueKey('note-edit'),
              style: editStyle,
              onPressed: _startEditing,
              child: const Text('Edit'),
            ),
      const SizedBox(
        height: 20,
        child:
            VerticalDivider(key: ValueKey('note-toolbar-separator'), width: 16),
      ),
      EmojiPickerButton(
        enabled: _editing,
        color: toolColor,
        onSelected: _insertEmoji,
      ),
      MenuAnchor(
        controller: _markdownMenu,
        style: SyntilaMenuStyle.surface(
            Theme.of(context).brightness == Brightness.dark,
            composer: true),
        menuChildren: [
          SizedBox(
            key: const ValueKey('note-markdown-controls'),
            width: 220,
            child: Wrap(children: [
              for (final (format, label, icon) in _formats)
                IconButton(
                  tooltip: label,
                  iconSize: 18,
                  color: color,
                  onPressed: !_editing
                      ? null
                      : () {
                          _markdownMenu.close();
                          _format(format);
                        },
                  icon: Icon(icon, semanticLabel: label),
                ),
            ]),
          ),
        ],
        builder: (context, controller, _) => IconButton(
          tooltip: 'Show Markdown controls',
          padding: EdgeInsets.zero,
          constraints: composerButtonConstraints,
          style: composerIconButtonStyle(),
          icon: Icon(Icons.text_format,
              size: composerIconSize,
              color: toolColor,
              semanticLabel: 'Show Markdown controls'),
          onPressed: !_editing
              ? null
              : () =>
                  controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
      DictationButton(
        controller: _body,
        dictation: widget.dictation,
        enabled: _editing,
        color: toolColor,
        onTextChanged: _focus.requestFocus,
      ),
    ]);
  }

  void _startEditing() {
    if (_editing) return;
    setState(() => _editing = true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => mounted ? _focus.requestFocus() : null);
  }

  void _finishEditing() {
    _timer?.cancel();
    unawaited(_save());
    setState(() => _editing = false);
  }

  /// Formatted, read-only note. A double click anywhere edits it; a raw
  /// pointer listener sees both clicks even though the text is selectable.
  Widget _readView() => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          final last = _lastPointerDown;
          _lastPointerDown = event.timeStamp;
          if (last != null && event.timeStamp - last < kDoubleTapTimeout) {
            _lastPointerDown = null;
            _startEditing();
          }
        },
        child: SizedBox.expand(
          child: SingleChildScrollView(
            key: const ValueKey('note-preview'),
            // Free space between the toolbar and the formatted note.
            padding: const EdgeInsets.only(top: 16),
            child:
                SyntilaMarkdownBody(data: _body.text, preserveBlankLines: true),
          ),
        ),
      );
}
