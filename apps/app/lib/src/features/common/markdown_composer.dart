import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:syntila_design/syntila_design.dart';

import 'syntila_markdown_body.dart';
import 'dictation/dictation_button.dart';
import 'dictation/speech_dictation.dart';
import 'composer_metrics.dart';
import 'emoji_picker.dart';

enum MarkdownFormat {
  bold,
  italic,
  heading,
  inlineCode,
  codeBlock,
  quote,
  link,
  bulletList,
  numberedList,
  taskList,
}

/// Edits only Markdown source and keeps the edited content selected.
void formatMarkdown(TextEditingController controller, MarkdownFormat format) {
  final text = controller.text;
  final selection = controller.selection;
  var start = selection.isValid ? selection.start : text.length;
  var end = selection.isValid ? selection.end : text.length;
  final lineOperation = switch (format) {
    MarkdownFormat.heading ||
    MarkdownFormat.quote ||
    MarkdownFormat.bulletList ||
    MarkdownFormat.numberedList ||
    MarkdownFormat.taskList =>
      true,
    _ => false,
  };
  if (lineOperation) {
    start = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    if (end > start && text[end - 1] == '\n') end--;
    final nextNewline = text.indexOf('\n', end);
    end = nextNewline < 0 ? text.length : nextNewline;
    final lines = text.substring(start, end).split('\n');
    final unquote = format == MarkdownFormat.quote &&
        lines.every((line) => line.startsWith('> '));
    final replacement = [
      for (var i = 0; i < lines.length; i++)
        if (unquote)
          lines[i].substring(2)
        else
          '${switch (format) {
            MarkdownFormat.heading => '## ',
            MarkdownFormat.quote => '> ',
            MarkdownFormat.bulletList => '- ',
            MarkdownFormat.numberedList => '${i + 1}. ',
            _ => '- [ ] ',
          }}${lines[i]}',
    ].join('\n');
    controller.value = TextEditingValue(
      text: text.replaceRange(start, end, replacement),
      selection: TextSelection(
          baseOffset: start, extentOffset: start + replacement.length),
    );
    return;
  }
  final selected = text.substring(start, end);
  final (prefix, suffix, placeholder) = switch (format) {
    MarkdownFormat.bold => ('**', '**', 'bold text'),
    MarkdownFormat.italic => ('*', '*', 'italic text'),
    MarkdownFormat.inlineCode => ('`', '`', 'code'),
    MarkdownFormat.codeBlock => ('```\n', '\n```', 'code'),
    MarkdownFormat.link => ('[', '](url)', 'link text'),
    _ => ('', '', ''),
  };
  final content = selected.isEmpty ? placeholder : selected;
  controller.value = TextEditingValue(
    text: text.replaceRange(start, end, '$prefix$content$suffix'),
    selection: format == MarkdownFormat.link
        ? TextSelection(
            baseOffset: start + prefix.length + content.length + 2,
            extentOffset: start + prefix.length + content.length + 5)
        : TextSelection(
            baseOffset: start + prefix.length,
            extentOffset: start + prefix.length + content.length),
  );
}

class MarkdownComposer extends StatefulWidget {
  const MarkdownComposer(
      {super.key,
      required this.controller,
      this.onSend,
      this.onSubmit,
      this.additionalControlsBuilder,
      this.executionControlsBuilder,
      this.toolbarLeadingControls,
      this.leadingControls,
      this.attachments,
      this.inputHeight,
      this.showControlTooltips = true,
      this.sendEnabled = true,
      this.sendInToolbar = false,
      this.sendInFormattingToolbar = false,
      this.sendTooltip = 'Send message',
      this.sendIcon = Icons.send_rounded,
      this.focusNode,
      this.onCancel,
      this.showSendTooltip = true,
      this.compact = false,
      this.chatStyle = false,
      this.autofocus = false,
      this.enabled = true,
      this.labelText,
      this.hintText,
      this.minLines = 2,
      this.maxLines = 8,
      this.showMarkdownControls = true,
      this.showMarkdownControlsInSuffix = true,
      this.showSendInSuffix = true,
      this.showEmojiPicker = true,
      this.showDictation = true,
      this.dictation,
      this.twoRowLayout = false,
      this.showTrailingRail,
      this.onHistoryNavigate});

  final TextEditingController controller;
  final VoidCallback? onSend;
  final VoidCallback? onSubmit;

  /// Called for Arrow Up (-1) / Arrow Down (1) while the input is empty.
  /// Returns true when it handled the key (e.g. opened request history).
  final bool Function(int direction)? onHistoryNavigate;
  final Widget Function(GlobalKey inputKey)? additionalControlsBuilder;
  final Widget Function(GlobalKey inputKey)? executionControlsBuilder;

  /// Compact controls before emoji/Markdown in the two-row toolbar.
  final Widget? toolbarLeadingControls;

  /// Controls in the left rail beside the input and its bottom row.
  final Widget? leadingControls;

  /// File cards inside the composer, above the text control.
  final Widget? attachments;

  /// Height shared by the Thread's Message and Ask AI inputs.
  final ComposerInputHeight? inputHeight;
  final bool showControlTooltips;
  final bool sendEnabled;
  final bool sendInToolbar;
  final bool sendInFormattingToolbar;
  final String sendTooltip;

  /// Icon of the send button; editing swaps it for a check mark.
  final IconData sendIcon;

  /// Lets the owner move focus into the input, e.g. when editing starts.
  final FocusNode? focusNode;

  /// Escape in the input; null leaves Escape alone.
  final VoidCallback? onCancel;

  /// Hide the hover hint while retaining the send action’s semantic label.
  final bool showSendTooltip;
  final bool compact;
  final bool chatStyle;
  final bool autofocus;
  final bool enabled;
  final String? labelText;
  final String? hintText;
  final int minLines;
  final int maxLines;
  final bool showMarkdownControls;
  final bool showMarkdownControlsInSuffix;
  final bool showSendInSuffix;

  /// Shows the smile button that opens the emoji popup.
  final bool showEmojiPicker;

  /// Shows the mic button for browser speech-to-text in chat-style inputs.
  final bool showDictation;

  /// Overrides the platform speech recognizer (tests).
  final SpeechDictation? dictation;

  /// Chat input as two rows: the text field, then emoji and Markdown popup
  /// controls on the left and send on the right.
  final bool twoRowLayout;

  /// Shows the right rail aligned to the right (Send and Microphone controls).
  /// Defaults to true when [leadingControls] is present.
  final bool? showTrailingRail;

  @override
  State<MarkdownComposer> createState() => _MarkdownComposerState();
}

/// Height of the second (controls) row in the two-row layout: 32px buttons
/// with 6px above and below.
const double _twoRowControlsHeight = 44;

class _MarkdownComposerState extends State<MarkdownComposer> {
  final _ownFocus = FocusNode();
  FocusNode get _focus => widget.focusNode ?? _ownFocus;
  // The language selector lives only while the mic or the selector is focused.
  final _languageMenu = MenuController();
  final _inputKey = GlobalKey();
  bool _preview = false;
  bool _showFormatting = false;

  late final SpeechDictation _dictation =
      widget.dictation ?? createSpeechDictation();
  bool _dictationListening = false;
  // Ends from an earlier session (e.g. a language restart) must not reset a
  // newer one, so every callback carries the session it belongs to.
  int _dictationSession = 0;
  String _dictationPrefix = '';
  String _dictationSuffix = '';
  String? _dictationWritten;
  late String? _dictationLanguage = _dictation.preferredLanguage;

  String get _activeDictationLanguage =>
      _dictationLanguage ?? _dictation.browserLanguage;

  bool get _hasTrailingRail =>
      widget.showTrailingRail ?? (widget.leadingControls != null);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sourceChanged);
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MarkdownComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sourceChanged);
      widget.controller.addListener(_sourceChanged);
      _stopDictation();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus).removeListener(_onFocusChange);
      _focus.addListener(_onFocusChange);
    }
    if (!widget.enabled) _stopDictation();
  }

  void _submit() {
    final value = widget.controller.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    if (widget.enabled && widget.sendEnabled) {
      (widget.onSubmit ?? widget.onSend)?.call();
    }
  }

  void _sourceChanged() {
    if (widget.chatStyle && _preview && widget.controller.text.isEmpty) {
      setState(() => _preview = false);
    }
    if (_dictationListening &&
        _dictationWritten != null &&
        widget.controller.text != _dictationWritten) {
      _stopDictation();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sourceChanged);
    _focus.removeListener(_onFocusChange);
    _ownFocus.dispose();
    if (_dictationListening) _dictation.stop();
    super.dispose();
  }

  void _stopDictation() {
    if (!_dictationListening) return;
    _dictationSession++;
    _dictation.stop();
    _dictationListening = false;
    _dictationWritten = null;
    if (mounted) setState(() {});
  }

  void _startDictation() {
    final value = widget.controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final before = text.substring(0, start);
    _dictationPrefix =
        before.isEmpty || RegExp(r'\s$').hasMatch(before) ? before : '$before ';
    _dictationSuffix = text.substring(end);
    _dictationWritten = null;
    setState(() {
      _dictationListening = true;
    });
    final session = ++_dictationSession;
    _dictation.start(
      language: _activeDictationLanguage,
      onTranscript: (text) {
        if (session == _dictationSession) _onDictationTranscript(text);
      },
      onEnd: (error) {
        if (session == _dictationSession) _onDictationEnd(error);
      },
    );
  }

  void _onDictationTranscript(String transcript) {
    if (!_dictationListening || !mounted || transcript.isEmpty) return;
    final inserted =
        _dictationSuffix.isEmpty || RegExp(r'^\s').hasMatch(_dictationSuffix)
            ? transcript
            : '$transcript ';
    final text = '$_dictationPrefix$inserted$_dictationSuffix';
    _dictationWritten = text;
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
          offset: _dictationPrefix.length + transcript.length),
    );
    _focus.requestFocus();
  }

  void _onDictationEnd(String? error) {
    if (!mounted) return;
    final wasListening = _dictationListening;
    setState(() {
      _dictationListening = false;
      _dictationWritten = null;
    });
    final message = switch (error) {
      'not-allowed' ||
      'service-not-allowed' =>
        'Microphone access is blocked. Allow it in your browser settings.',
      'audio-capture' => 'No microphone was found.',
      'network' => 'Speech recognition is unavailable right now.',
      null || 'no-speech' || 'aborted' => null,
      _ => 'Dictation stopped.',
    };
    if (wasListening && message != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _selectDictationLanguage(String? language) {
    final wasListening = _dictationListening;
    _stopDictation();
    _dictation.preferredLanguage = language;
    setState(() => _dictationLanguage = language);
    // Restart so a switch made while recording takes effect immediately.
    if (wasListening) _startDictation();
  }

  /// One tap starts or stops dictation in the remembered language. The
  /// language menu lives on a long press (or secondary click) of the mic.
  void _toggleDictation() =>
      _dictationListening ? _stopDictation() : _startDictation();

  String _dictationLanguageName(String tag) {
    for (final (code, name) in dictationLanguages) {
      if (code.toLowerCase() == tag.toLowerCase()) return name;
    }
    return tag;
  }

  /// Anchors the language menu on the mic so the language stays reachable
  /// without a mandatory extra step before recording.
  Widget _dictationLanguageMenu(Widget child) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget item(String? tag, String label) => MenuItemButton(
          key: ValueKey('dictation-language-${tag ?? 'browser'}'),
          style: SyntilaMenuStyle.item(dark),
          leadingIcon:
              Icon(_dictationLanguage == tag ? Icons.check : null, size: 16),
          onPressed: () => _selectDictationLanguage(tag),
          child: Text(label, style: SyntilaMenuStyle.textStyle),
        );
    return MenuAnchor(
      controller: _languageMenu,
      style: SyntilaMenuStyle.surface(dark, composer: true),
      menuChildren: [
        item(null,
            'Browser default (${_dictationLanguageName(_dictation.browserLanguage)})'),
        for (final (tag, name) in dictationLanguages) item(tag, name),
      ],
      child: child,
    );
  }

  Widget _rightRailSendButton() => IconButton(
        key: ValueKey('composer-send-${widget.sendTooltip}'),
        tooltip: widget.showSendTooltip ? widget.sendTooltip : null,
        onPressed: widget.enabled && widget.sendEnabled ? widget.onSend : null,
        padding: EdgeInsets.zero,
        constraints: composerButtonConstraints,
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
        ),
        color: _controlColor,
        icon: Icon(widget.sendIcon,
            size: composerIconSize, semanticLabel: widget.sendTooltip),
      );

  Widget _rightRailMicButton() {
    final language = _dictationLanguageName(_activeDictationLanguage);
    final label =
        _dictationListening ? 'Stop dictation' : 'Start dictation ($language)';
    final colors = Theme.of(context).colorScheme;
    final canUse = widget.enabled && !_preview && _dictation.supported;
    void openLanguages() {
      if (canUse) _languageMenu.open();
    }

    return _dictationLanguageMenu(GestureDetector(
      // Long press must not clash with the touch tooltip, so it is manual.
      onLongPress: openLanguages,
      onSecondaryTap: openLanguages,
      child: Tooltip(
        message: '$label. Hold to change language',
        triggerMode: TooltipTriggerMode.manual,
        child: IconButton(
          key: const ValueKey('composer-dictation'),
          isSelected: _dictationListening,
          color: _dictationListening ? colors.error : _controlColor,
          onPressed: canUse ? _toggleDictation : null,
          padding: EdgeInsets.zero,
          constraints: composerButtonConstraints,
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
          ),
          icon: Icon(
            _dictationListening ? Icons.stop_circle_outlined : Icons.mic_none,
            size: composerIconSize,
            semanticLabel: label,
          ),
        ),
      ),
    ));
  }

  Widget _trailingRail() {
    final topSlot = widget.onSend != null
        ? _rightRailSendButton()
        : const SizedBox(width: composerButtonSize, height: composerButtonSize);
    final bottomSlot = _dictationVisible && _dictation.supported
        ? _rightRailMicButton()
        : const SizedBox(width: composerButtonSize, height: composerButtonSize);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        topSlot,
        const SizedBox(height: 4),
        bottomSlot,
      ],
    );
  }

  void _format(MarkdownFormat format) {
    if (!widget.enabled) return;
    formatMarkdown(widget.controller, format);
    _focus.requestFocus();
  }

  void _insertEmoji(String emoji) {
    if (!widget.enabled) return;
    insertAtCursor(widget.controller, emoji);
    _focus.requestFocus();
  }

  Widget _emojiButton() => EmojiPickerButton(
        enabled: widget.enabled && !_preview,
        color: _controlColor,
        onSelected: _insertEmoji,
      );

  bool get _dictationVisible => widget.chatStyle && widget.showDictation;

  Widget _dictationButton() => DictationButton(
        controller: widget.controller,
        dictation: widget.dictation,
        enabled: widget.enabled && !_preview,
        color: _controlColor,
        onTextChanged: _focus.requestFocus,
      );

  bool get _secondaryToolbarVisible =>
      widget.chatStyle &&
      (_showFormatting || _preview || !widget.showMarkdownControlsInSuffix);

  Color get _controlColor => Theme.of(context).colorScheme.onSurface;

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

  final _markdownMenu = MenuController();

  /// Two-row layout controls: emoji and Markdown popup left; mic and send
  /// right.
  Widget _twoRowControls() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        // Fixed minimum so the row height does not depend on the controls'
        // density-scaled tap targets (Message and Ask AI differ there).
        child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _twoRowControlsHeight),
            child: Row(children: [
              if (widget.toolbarLeadingControls != null)
                widget.toolbarLeadingControls!,
              if (widget.executionControlsBuilder != null)
                Expanded(child: widget.executionControlsBuilder!(_inputKey)),
              if (widget.showEmojiPicker) _emojiButton(),
              if (widget.showMarkdownControls)
                MenuAnchor(
                  controller: _markdownMenu,
                  style: SyntilaMenuStyle.surface(
                      Theme.of(context).brightness == Brightness.dark,
                      composer: true),
                  menuChildren: [
                    SizedBox(
                      key: const ValueKey('markdown-controls-popup'),
                      width: 220,
                      child: Wrap(children: [
                        for (final (format, label, icon) in _formats)
                          IconButton(
                            tooltip: label,
                            iconSize: 18,
                            color: _controlColor,
                            onPressed: widget.enabled && !_preview
                                ? () {
                                    _markdownMenu.close();
                                    _format(format);
                                  }
                                : null,
                            icon: Icon(icon, semanticLabel: label),
                          ),
                        TextButton(
                          style: TextButton.styleFrom(
                              foregroundColor: _controlColor),
                          onPressed: () {
                            _markdownMenu.close();
                            setState(() => _preview = !_preview);
                          },
                          child: Text(_preview ? 'Write' : 'Preview'),
                        ),
                      ]),
                    ),
                  ],
                  builder: (context, controller, _) => IconButton(
                    tooltip: 'Show Markdown controls',
                    isSelected: _preview,
                    padding: EdgeInsets.zero,
                    constraints: composerButtonConstraints,
                    style: composerIconButtonStyle(),
                    icon: Icon(Icons.text_format,
                        size: composerIconSize,
                        color: _controlColor,
                        semanticLabel: 'Show Markdown controls'),
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                  ),
                ),
              if (widget.executionControlsBuilder == null) const Spacer(),
              if (!_hasTrailingRail && _dictationVisible) _dictationButton(),
              if (!_hasTrailingRail && widget.onSend != null)
                IconButton(
                  key: ValueKey('composer-send-${widget.sendTooltip}'),
                  tooltip: widget.showSendTooltip ? widget.sendTooltip : null,
                  onPressed: widget.enabled && widget.sendEnabled
                      ? widget.onSend
                      : null,
                  color: _controlColor,
                  padding: EdgeInsets.zero,
                  constraints: composerButtonConstraints,
                  style: composerIconButtonStyle(),
                  icon: Icon(widget.sendIcon,
                      size: composerIconSize,
                      semanticLabel: widget.sendTooltip),
                ),
            ])),
      );

  Widget _formattingToolbar() =>
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final (format, label, icon) in const [
          (MarkdownFormat.bold, 'Bold', Icons.format_bold),
          (MarkdownFormat.italic, 'Italic', Icons.format_italic),
          (MarkdownFormat.heading, 'Heading', Icons.title),
          (MarkdownFormat.inlineCode, 'Inline code', Icons.code),
          (MarkdownFormat.codeBlock, 'Code block', Icons.data_object),
          (MarkdownFormat.quote, 'Quote', Icons.format_quote),
          (MarkdownFormat.link, 'Link', Icons.link),
          (
            MarkdownFormat.bulletList,
            'Bullet list',
            Icons.format_list_bulleted
          ),
          (
            MarkdownFormat.numberedList,
            'Numbered list',
            Icons.format_list_numbered
          ),
          (MarkdownFormat.taskList, 'Task list', Icons.checklist),
        ])
          IconButton(
              tooltip: label,
              color: _controlColor,
              iconSize: 18,
              style: widget.sendInFormattingToolbar
                  ? IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap)
                  : null,
              visualDensity: widget.sendInFormattingToolbar
                  ? VisualDensity.standard
                  : VisualDensity.compact,
              constraints: widget.sendInFormattingToolbar
                  ? const BoxConstraints.tightFor(width: 28, height: 32)
                  : null,
              padding: widget.sendInFormattingToolbar
                  ? const EdgeInsets.all(4)
                  : const EdgeInsets.all(8),
              onPressed:
                  widget.enabled && !_preview ? () => _format(format) : null,
              icon: Icon(icon, semanticLabel: label)),
        if (!widget.chatStyle && widget.showEmojiPicker) _emojiButton(),
        if (widget.chatStyle)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: _controlColor,
              padding: widget.sendInFormattingToolbar
                  ? const EdgeInsets.symmetric(horizontal: 8)
                  : null,
              minimumSize:
                  widget.sendInFormattingToolbar ? const Size(0, 32) : null,
              tapTargetSize: widget.sendInFormattingToolbar
                  ? MaterialTapTargetSize.shrinkWrap
                  : null,
            ),
            onPressed: () => setState(() => _preview = !_preview),
            child: Text(_preview ? 'Write' : 'Preview'),
          ),
        if (widget.chatStyle &&
            widget.showMarkdownControls &&
            !widget.showMarkdownControlsInSuffix)
          IconButton(
            tooltip: _showFormatting
                ? 'Hide Markdown controls'
                : 'Show Markdown controls',
            icon: Icon(
              Icons.text_format,
              size: 18,
              color: _controlColor,
            ),
            onPressed: () => setState(() => _showFormatting = !_showFormatting),
          ),
        if (widget.chatStyle &&
            widget.onSend != null &&
            !widget.sendInToolbar &&
            !widget.sendInFormattingToolbar &&
            (!widget.showSendInSuffix || _preview))
          IconButton(
            key: ValueKey('composer-send-${widget.sendTooltip}'),
            tooltip: widget.showSendTooltip ? widget.sendTooltip : null,
            onPressed:
                widget.enabled && widget.sendEnabled ? widget.onSend : null,
            color: _controlColor,
            icon: Icon(widget.sendIcon,
                size: 18, semanticLabel: widget.sendTooltip),
          ),
      ]);

  bool _isTouchPlatform(BuildContext context) {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  @override
  Widget build(BuildContext context) {
    final isTouch = _isTouchPlatform(context);
    final inputContent = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_preview) ...[
          CallbackShortcuts(
            key: _inputKey,
            bindings: {
              // Touch keyboards report their return key as Enter; there it must
              // insert a newline, and the send button sends.
              if (!isTouch &&
                  (widget.onSend != null || widget.onSubmit != null))
                const SingleActivator(LogicalKeyboardKey.enter): _submit,
              if (widget.onCancel != null)
                const SingleActivator(LogicalKeyboardKey.escape):
                    widget.onCancel!,
              for (final modifier in [true, false]) ...{
                SingleActivator(LogicalKeyboardKey.keyB,
                    meta: modifier,
                    control: !modifier): () => _format(MarkdownFormat.bold),
                SingleActivator(LogicalKeyboardKey.keyI,
                    meta: modifier,
                    control: !modifier): () => _format(MarkdownFormat.italic),
                SingleActivator(LogicalKeyboardKey.keyE,
                        meta: modifier, control: !modifier):
                    () => _format(MarkdownFormat.inlineCode),
                if (widget.onSend != null || widget.onSubmit != null)
                  SingleActivator(LogicalKeyboardKey.enter,
                      meta: modifier, control: !modifier): _submit,
              },
            },
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, event) {
                final navigate = widget.onHistoryNavigate;
                if (navigate == null || event is KeyUpEvent) {
                  return KeyEventResult.ignored;
                }
                final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
                final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
                final keyboard = HardwareKeyboard.instance;
                if ((!up && !down) ||
                    keyboard.isShiftPressed ||
                    keyboard.isMetaPressed ||
                    keyboard.isControlPressed ||
                    keyboard.isAltPressed) {
                  return KeyEventResult.ignored;
                }
                if (widget.controller.text.isNotEmpty) {
                  return KeyEventResult.ignored;
                }
                return navigate(up ? -1 : 1)
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored;
              },
              child: TextField(
                controller: widget.controller,
                enabled: widget.enabled,
                focusNode: _focus,
                autofocus: widget.autofocus,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: widget.chatStyle
                    ? SyntilaMessageTypography.fromTheme(Theme.of(context))
                    : null,
                minLines:
                    widget.chatStyle || widget.compact ? 1 : widget.minLines,
                maxLines: widget.maxLines,
                decoration: InputDecoration(
                  labelText: widget.labelText,
                  hintText: widget.hintText,
                  // Same muted color as the message date/time.
                  hintStyle: const TextStyle(
                    color: SyntilaColors.neutral,
                  ),
                  isDense: widget.chatStyle,
                  hoverColor: Colors.transparent,
                  contentPadding: widget.chatStyle
                      ? const EdgeInsets.fromLTRB(10, 12, 10, 8)
                      : null,
                  suffixIcon: widget.chatStyle &&
                          !widget.twoRowLayout &&
                          (widget.showEmojiPicker ||
                              _dictationVisible ||
                              (widget.showMarkdownControls &&
                                  widget.showMarkdownControlsInSuffix) ||
                              (widget.onSend != null &&
                                  !widget.sendInToolbar &&
                                  widget.showSendInSuffix))
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.showEmojiPicker) _emojiButton(),
                            if (_dictationVisible) _dictationButton(),
                            if (widget.showMarkdownControls &&
                                widget.showMarkdownControlsInSuffix)
                              IconButton(
                                tooltip: _showFormatting
                                    ? 'Hide Markdown controls'
                                    : 'Show Markdown controls',
                                icon: Icon(
                                  Icons.text_format,
                                  size: 18,
                                  color: _controlColor,
                                ),
                                onPressed: () => setState(
                                    () => _showFormatting = !_showFormatting),
                              ),
                            if (widget.onSend != null &&
                                !widget.sendInToolbar &&
                                widget.showSendInSuffix)
                              IconButton(
                                key: ValueKey(
                                    'composer-send-${widget.sendTooltip}'),
                                tooltip: widget.showSendTooltip
                                    ? widget.sendTooltip
                                    : null,
                                onPressed: widget.enabled && widget.sendEnabled
                                    ? widget.onSend
                                    : null,
                                color: _controlColor,
                                icon: Icon(widget.sendIcon,
                                    size: 18,
                                    semanticLabel: widget.sendTooltip),
                              ),
                          ],
                        )
                      : null,
                  border:
                      widget.chatStyle ? InputBorder.none : InputBorder.none,
                  enabledBorder: widget.chatStyle ? InputBorder.none : null,
                  focusedBorder: widget.chatStyle ? InputBorder.none : null,
                ),
              ),
            ),
          ),
        ] else
          ValueListenableBuilder<TextEditingValue>(
            key: _inputKey,
            valueListenable: widget.controller,
            builder: (context, value, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: value.text.isEmpty
                  ? const Text('Nothing to preview yet.')
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SingleChildScrollView(
                          child: SyntilaMarkdownBody(data: value.text)),
                    ),
            ),
          ),
        if (widget.chatStyle &&
            !widget.twoRowLayout &&
            (_showFormatting ||
                _preview ||
                !widget.showMarkdownControlsInSuffix)) ...[
          Padding(
            padding: widget.sendInFormattingToolbar
                ? const EdgeInsets.symmetric(horizontal: 6)
                : const EdgeInsets.fromLTRB(6, 2, 6, 4),
            child: widget.sendInFormattingToolbar
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: _formattingToolbar()),
                      if (widget.onSend != null)
                        IconButton(
                          key: ValueKey('composer-send-${widget.sendTooltip}'),
                          tooltip: widget.showSendTooltip
                              ? widget.sendTooltip
                              : null,
                          onPressed: widget.enabled && widget.sendEnabled
                              ? widget.onSend
                              : null,
                          color: _controlColor,
                          icon: Icon(widget.sendIcon,
                              size: 18, semanticLabel: widget.sendTooltip),
                        ),
                    ],
                  )
                : _formattingToolbar(),
          ),
        ],
      ],
    );

    final backgroundColor = SyntilaColors.composerBackground(
      Theme.of(context).brightness == Brightness.dark,
    );

    return TooltipVisibility(
        visible: widget.showControlTooltips,
        child: IconTheme.merge(
          data: IconThemeData(color: _controlColor),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(10),
            ),
            padding: EdgeInsets.all(widget.chatStyle
                ? 0
                : widget.compact
                    ? 6
                    : 10),
            child: Stack(children: [
              if (widget.leadingControls != null)
                // Distinct strip behind the mode rail, full composer height.
                Positioned(
                  key: const ValueKey('composer-leading-rail-background'),
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 40,
                  // Distinct rail shade: OKLCH L 93% light / 24% dark.
                  child: ColoredBox(
                    color: SyntilaColors.composerRail(
                        Theme.of(context).brightness == Brightness.dark),
                  ),
                ),
              if (_hasTrailingRail)
                Positioned(
                  key: const ValueKey('composer-trailing-rail-background'),
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: 40,
                  child: ColoredBox(
                    color: SyntilaColors.composerRail(
                        Theme.of(context).brightness == Brightness.dark),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.leadingControls != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: SizedBox(
                        key: const ValueKey('composer-leading-rail'),
                        width: 32,
                        child: widget.leadingControls!,
                      ),
                    ),
                  Expanded(
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!widget.chatStyle)
                        Row(children: [
                          TextButton(
                              onPressed: () => setState(() => _preview = false),
                              child: Text('Write',
                                  style: TextStyle(
                                      fontWeight:
                                          !_preview ? FontWeight.bold : null))),
                          TextButton(
                              onPressed: () => setState(() => _preview = true),
                              child: Text('Preview',
                                  style: TextStyle(
                                      fontWeight:
                                          _preview ? FontWeight.bold : null))),
                          const Spacer(),
                          Tooltip(
                            message:
                                'Thread content is GitHub-Flavored Markdown source.',
                            child: Text('Markdown',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    )),
                          ),
                        ]),
                      if (!widget.chatStyle && !_preview) _formattingToolbar(),
                      if (widget.attachments != null)
                        Padding(
                            padding: const EdgeInsets.all(10),
                            child: widget.attachments!),
                      if (widget.inputHeight case final height?)
                        ValueListenableBuilder<double>(
                          valueListenable: height,
                          builder: (context, minimum, child) => ConstrainedBox(
                            constraints: BoxConstraints(minHeight: minimum),
                            // Loose so the observer measures the natural
                            // height of this input's own content.
                            child: Align(
                              alignment: Alignment.topCenter,
                              heightFactor: 1,
                              child: _ComposerHeightObserver(
                                onHeight: (value) {
                                  if (mounted && widget.inputHeight == height) {
                                    height.report(widget.controller, value);
                                  }
                                },
                                child: child!,
                              ),
                            ),
                          ),
                          child: inputContent,
                        )
                      else
                        inputContent,
                      if (widget.chatStyle && widget.twoRowLayout)
                        _twoRowControls(),
                      if (widget.chatStyle &&
                          !widget.twoRowLayout &&
                          widget.sendInToolbar &&
                          widget.executionControlsBuilder != null &&
                          widget.additionalControlsBuilder != null)
                        widget.additionalControlsBuilder!(_inputKey),
                      if (widget.chatStyle &&
                          !widget.twoRowLayout &&
                          widget.sendInToolbar &&
                          (widget.executionControlsBuilder != null ||
                              widget.additionalControlsBuilder != null ||
                              !_secondaryToolbarVisible))
                        Row(children: [
                          if (widget.executionControlsBuilder != null)
                            Expanded(
                                child:
                                    widget.executionControlsBuilder!(_inputKey))
                          else if (widget.additionalControlsBuilder != null)
                            Expanded(
                                child: widget
                                    .additionalControlsBuilder!(_inputKey))
                          else
                            const Spacer(),
                          if (widget.onSend != null &&
                              !widget.sendInFormattingToolbar)
                            IconButton(
                              key: ValueKey(
                                  'composer-send-${widget.sendTooltip}'),
                              tooltip: widget.showSendTooltip
                                  ? widget.sendTooltip
                                  : null,
                              onPressed: widget.enabled && widget.sendEnabled
                                  ? widget.onSend
                                  : null,
                              color: _controlColor,
                              icon: Icon(widget.sendIcon,
                                  size: 18, semanticLabel: widget.sendTooltip),
                            ),
                        ])
                      else if (widget.additionalControlsBuilder != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                          child: widget.additionalControlsBuilder!(_inputKey),
                        ),
                      if (!widget.chatStyle &&
                          (widget.onSend != null || widget.onSubmit != null))
                        Row(children: [
                          Text(
                            widget.onSend != null && widget.onSubmit == null
                                ? 'Enter to send · Shift+Enter for a new line'
                                : '${Theme.of(context).platform == TargetPlatform.macOS || Theme.of(context).platform == TargetPlatform.iOS ? '⌘' : 'Ctrl+'} Enter to save',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                          ),
                          const Spacer(),
                          if (widget.onSend != null &&
                              !widget.sendInFormattingToolbar)
                            IconButton(
                              key: ValueKey(
                                  'composer-send-${widget.sendTooltip}'),
                              tooltip: widget.showSendTooltip
                                  ? widget.sendTooltip
                                  : null,
                              onPressed: widget.onSend,
                              icon: Icon(widget.sendIcon,
                                  semanticLabel: widget.sendTooltip),
                            ),
                        ]),
                    ],
                  )),
                  if (_hasTrailingRail)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: SizedBox(
                        key: const ValueKey('composer-trailing-rail'),
                        width: 32,
                        child: _trailingRail(),
                      ),
                    ),
                ],
              ),
            ]),
          ),
        ));
  }
}

/// Shared minimum input height: the tallest natural height among the inputs
/// that report to it. An input whose text is sent or cleared shrinks back,
/// even while it is hidden behind the other mode.
class ComposerInputHeight extends ValueNotifier<double> {
  ComposerInputHeight() : super(0);

  final _heights = <TextEditingController, double>{};
  final _emptyHeights = <TextEditingController, double>{};
  final _listeners = <TextEditingController, VoidCallback>{};

  void report(TextEditingController controller, double height) {
    if (!_listeners.containsKey(controller)) {
      void listener() {
        // A hidden input cannot re-measure; fall back to its empty height.
        if (controller.text.isNotEmpty) return;
        final empty = _emptyHeights[controller] ??
            (_emptyHeights.isEmpty
                ? null
                : _emptyHeights.values.reduce((a, b) => a < b ? a : b));
        if (empty == null) {
          _heights.remove(controller);
        } else {
          _heights[controller] = empty;
        }
        _recompute();
      }

      controller.addListener(listener);
      _listeners[controller] = listener;
    }
    if (controller.text.isEmpty) {
      final empty = _emptyHeights[controller];
      _emptyHeights[controller] =
          empty == null || height < empty ? height : empty;
    }
    _heights[controller] = height;
    _recompute();
  }

  void _recompute() {
    var tallest = 0.0;
    for (final height in _heights.values) {
      if (height > tallest) tallest = height;
    }
    value = tallest;
  }

  /// Forgets all measurements, e.g. when the Thread changes.
  void reset() {
    _heights.clear();
    value = 0;
  }

  @override
  void dispose() {
    for (final MapEntry(:key, value: listener) in _listeners.entries) {
      key.removeListener(listener);
    }
    _listeners.clear();
    super.dispose();
  }
}

class _ComposerHeightObserver extends SingleChildRenderObjectWidget {
  const _ComposerHeightObserver({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ComposerHeightRender(onHeight);
  @override
  void updateRenderObject(
      BuildContext context, _ComposerHeightRender renderObject) {
    renderObject.onHeight = onHeight;
  }
}

class _ComposerHeightRender extends RenderProxyBox {
  _ComposerHeightRender(this.onHeight);
  ValueChanged<double> onHeight;
  double? _lastHeight;
  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _lastHeight) return;
    _lastHeight = height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(height);
    });
  }
}
