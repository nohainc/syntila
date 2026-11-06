import 'dart:async';
import 'quiet_notices.dart';

import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'syntila_code_block.dart';

/// Represents a parsed local file, code location, or editor destination.
class ParsedCodeLink {
  const ParsedCodeLink({
    required this.filePath,
    this.line,
    this.endLine,
    this.editorScheme,
  });

  final String filePath;
  final int? line;
  final int? endLine;
  final String? editorScheme;

  /// Returns the formatted path with line specification (e.g. `main.dart:10` or `/Users/.../foo.dart:10-20`).
  String get formattedLocation {
    if (line == null) return filePath;
    if (endLine != null && endLine != line) return '$filePath:$line-$endLine';
    return '$filePath:$line';
  }

  /// Compact filename or last path segment for user-facing notices.
  String get displayTarget {
    final normalized = filePath.replaceAll(r'\', '/');
    final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
    final name = segments.isNotEmpty ? segments.last : filePath;
    if (line == null) return name;
    if (endLine != null && endLine != line) return '$name:$line-$endLine';
    return '$name:$line';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParsedCodeLink &&
          runtimeType == other.runtimeType &&
          filePath == other.filePath &&
          line == other.line &&
          endLine == other.endLine &&
          editorScheme == other.editorScheme;

  @override
  int get hashCode => Object.hash(filePath, line, endLine, editorScheme);

  @override
  String toString() =>
      'ParsedCodeLink(filePath: $filePath, line: $line, endLine: $endLine, editorScheme: $editorScheme)';
}

bool _looksLikeFilePath(String raw) {
  final hashIdx = raw.indexOf('#');
  var path = hashIdx != -1 ? raw.substring(0, hashIdx) : raw;
  final colonMatch = RegExp(r':\d+(?::\d+)?$').firstMatch(path);
  if (colonMatch != null) {
    path = path.substring(0, colonMatch.start);
  }

  if (path.isEmpty) return false;

  final normalized = path.replaceAll(r'\', '/');
  final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return false;
  final fileName = segments.last;

  final baseLower = fileName.toLowerCase();
  if (const {
    'dockerfile',
    'makefile',
    'license',
    'gemfile',
    'podfile',
    'procfile',
    'cmakelists.txt',
  }.contains(baseLower)) {
    return true;
  }

  final dotIdx = fileName.lastIndexOf('.');
  if (dotIdx > 0 && dotIdx < fileName.length - 1) {
    final ext = fileName.substring(dotIdx + 1).toLowerCase();
    return RegExp(r'^[a-z0-9_-]{1,10}$').hasMatch(ext);
  }

  return false;
}

ParsedCodeLink _extractPathAndLine(String input, {String? editorScheme}) {
  var path = input;
  int? line;
  int? endLine;

  final hashIndex = path.indexOf('#');
  if (hashIndex != -1) {
    final fragment = path.substring(hashIndex + 1);
    path = path.substring(0, hashIndex);
    final match = RegExp(r'^L?(\d+)(?:[-:]L?(\d+))?', caseSensitive: false)
        .firstMatch(fragment);
    if (match != null) {
      line = int.tryParse(match.group(1)!);
      if (match.group(2) != null) {
        endLine = int.tryParse(match.group(2)!);
      }
    }
  }

  final colonMatch = RegExp(r':(\d+)(?::\d+)?$').firstMatch(path);
  if (colonMatch != null) {
    line ??= int.tryParse(colonMatch.group(1)!);
    path = path.substring(0, colonMatch.start);
  }

  return ParsedCodeLink(
    filePath: path,
    line: line,
    endLine: endLine,
    editorScheme: editorScheme,
  );
}

/// Extracts a local code or file location from a link destination, supporting
/// `file://` URIs, editor URIs (`vscode://file/...`, `cursor://file/...`),
/// and relative/workspace file paths with optional `#L10-L20` or `:10` line numbers.
ParsedCodeLink? parseCodeOrFileLink(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final trimmed = raw.trim();

  if (trimmed.startsWith('#')) return null;

  final lower = trimmed.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('javascript:') ||
      lower.startsWith('data:') ||
      lower.startsWith('vbscript:') ||
      lower.startsWith('mailto:')) {
    return null;
  }

  if (lower.startsWith('vscode://file/') ||
      lower.startsWith('cursor://file/')) {
    final scheme = lower.startsWith('vscode://file/') ? 'vscode' : 'cursor';
    var rest = trimmed.substring(scheme.length + 8);
    try {
      rest = Uri.decodeFull(rest);
    } catch (_) {}
    if (!rest.startsWith('/') && !RegExp(r'^[a-zA-Z]:').hasMatch(rest)) {
      rest = '/$rest';
    }
    return _extractPathAndLine(rest, editorScheme: scheme);
  }

  if (lower.startsWith('file:')) {
    var path = trimmed.substring(5);
    try {
      path = Uri.decodeFull(path);
    } catch (_) {}
    if (path.startsWith('///')) {
      path = path.substring(2);
    } else if (path.toLowerCase().startsWith('//localhost/')) {
      path = path.substring(12);
    } else if (path.startsWith('//')) {
      path = path.substring(1);
    }
    if (RegExp(r'^/[a-zA-Z]:').hasMatch(path)) {
      path = path.substring(1);
    }
    return _extractPathAndLine(path);
  }

  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(trimmed) &&
      !RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(trimmed)) {
    return null;
  }

  if (_looksLikeFilePath(trimmed)) {
    var path = trimmed;
    try {
      path = Uri.decodeFull(path);
    } catch (_) {}
    return _extractPathAndLine(path);
  }

  return null;
}

/// Accept only absolute web URLs. Uri parsing alone normalizes some malformed
/// input, so reject whitespace, backslashes and invalid escapes first.
Uri? validatedMarkdownLink(String? href) {
  if (href == null ||
      href.isEmpty ||
      RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(href) ||
      RegExp(r'^https?://[^/?#]*@', caseSensitive: false).hasMatch(href) ||
      RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(href)) {
    return null;
  }
  try {
    final uri = Uri.parse(href);
    if ((uri.scheme != 'https' && uri.scheme != 'http') ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.host.contains('%') ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

Future<bool> _launchMarkdownLink(Uri uri) => launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );

/// AX's authored-content contract: raw GFM source, never converted to HTML.
/// Diagnostics should continue to use plain text widgets.
class SyntilaMarkdownBody extends StatelessWidget {
  const SyntilaMarkdownBody({
    super.key,
    required this.data,
    this.openLink = _launchMarkdownLink,
    this.onOpenFile,
    this.onNavigateTo,
    this.fitContent = false,
    this.preserveBlankLines = false,
    this.onSelectionChanged,
  });

  final String data;
  final bool fitContent;

  /// Notes opt in to visible blank lines without changing saved Markdown or
  /// whitespace rendering in conversation messages.
  final bool preserveBlankLines;

  /// Reports the plain text selected inside this message boundary.
  ///
  /// The callback is intentionally scoped to this message. It does not expose
  /// Markdown source or selection from neighboring messages or shell UI.
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  /// Receives only validated web URLs; injectable for deterministic testing.
  final Future<bool> Function(Uri uri) openLink;

  /// Optional handler for code or file links. If null or if it returns false,
  /// falls back to launching an editor URI (e.g. `vscode://file/...`) and copying
  /// the path to the clipboard.
  final Future<bool> Function(ParsedCodeLink link)? onOpenFile;

  /// Optional handler for in-app navigation routes (e.g. `/spaces/...`).
  final ValueChanged<String>? onNavigateTo;

  Future<void> _handleCodeOrFileLink(
    BuildContext context,
    ParsedCodeLink codeLink,
  ) async {
    if (onOpenFile != null) {
      try {
        final handled = await onOpenFile!(codeLink);
        if (handled) return;
      } catch (_) {}
    }

    var normalized = codeLink.filePath.replaceAll(r'\', '/');
    if (!normalized.startsWith('/') &&
        !RegExp(r'^[a-zA-Z]:').hasMatch(normalized)) {
      normalized = '/$normalized';
    }
    final scheme = codeLink.editorScheme ?? 'vscode';
    final lineParam = codeLink.line != null ? ':${codeLink.line}' : '';
    final editorUri = Uri.tryParse('$scheme://file$normalized$lineParam');

    var opened = false;
    if (editorUri != null) {
      try {
        opened = await openLink(editorUri);
      } catch (_) {
        opened = false;
      }
    }

    try {
      await Clipboard.setData(ClipboardData(text: codeLink.formattedLocation));
    } catch (_) {}

    if (context.mounted) {
      final message = opened
          ? 'Opened ${codeLink.displayTarget} in editor'
          : 'Copied path to clipboard: ${codeLink.displayTarget}';
      ScaffoldMessenger.maybeOf(context)?.showNotice(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    final raw = href?.trim();
    if (raw == null || raw.isEmpty) return;

    // 1. Intra-document anchors (#heading, #section) within messages:
    // Do not attempt external URL launch or show error notice.
    if (raw.startsWith('#')) return;

    // 2. Dangerous URI schemes:
    final lower = raw.toLowerCase();
    if (lower.startsWith('javascript:') ||
        lower.startsWith('data:') ||
        lower.startsWith('vbscript:')) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showNotice(
          const SnackBar(content: Text('Cannot open unsafe link.')),
        );
      }
      return;
    }

    // 3. Web links (http / https):
    final uri = validatedMarkdownLink(raw);
    if (uri != null) {
      String? failure;
      try {
        if (!await openLink(uri)) failure = 'Could not open this link.';
      } catch (_) {
        failure = 'Could not open this link.';
      }
      if (failure != null && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showNotice(
          SnackBar(content: Text(failure)),
        );
      }
      return;
    }

    // 4. Code / file / editor destinations:
    final codeLink = parseCodeOrFileLink(raw);
    if (codeLink != null) {
      await _handleCodeOrFileLink(context, codeLink);
      return;
    }

    // 5. In-app navigation routes:
    if (raw.startsWith('/') && onNavigateTo != null) {
      onNavigateTo!(raw);
      return;
    }

    // Fallback: unsupported scheme or malformed destination
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showNotice(
        const SnackBar(
            content: Text('Only valid HTTP or HTTPS links can be opened.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildGpt(context);
    // Keep the region at the message boundary: an ancestor SelectionArea could
    // otherwise make Select All include neighboring messages or shell UI.
    return SelectionArea(
      onSelectionChanged: onSelectionChanged,
      child: _MarkdownSelectionOrder(child: body),
    );
  }

  /// Conversation messages: gpt_markdown sized to content, one per message so
  /// the thread's list virtualizes messages while each body caches segments.
  Widget _buildGpt(BuildContext context) {
    final theme = Theme.of(context);
    final data =
        preserveBlankLines ? visibleBlankLinesMarkdown(this.data) : this.data;
    // gpt_markdown's image hook receives only the URL; recover the alt text.
    final imageAlts = {
      for (final m
          in RegExp(r'!\[([^\]]*)\]\(\s*<?([^)\s>]*)').allMatches(data))
        m.group(2)!: m.group(1)!,
    };
    final body = GptMarkdown(
      data,
      key: ValueKey<String>(data),
      style: SyntilaMessageTypography.fromTheme(theme),
      styleSheet: SyntilaGptMarkdownStyleSheet.fromTheme(theme),
      // Authored content is Markdown only; raw HTML stays literal text.
      html: false,
      isStreaming: false,
      onLinkTap: (url, _) => unawaited(_openLink(context, url)),
      // Fence bodies keep their trailing newline so copy matches the source.
      codeBuilder: (_, language, code, __) => SyntilaCodeBlock(
          code: code.endsWith('\n') ? code : '$code\n', language: language),
      // Read-only task markers; Material checkboxes need a Material ancestor.
      checkboxBuilder: (_, checked, content, __) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8, top: 2),
            child: Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: SyntilaColors.primary,
              semanticLabel: checked ? 'Checked' : 'Unchecked',
            ),
          ),
          Flexible(child: content),
        ],
      ),
      // Remote images are never fetched from message content.
      imageBuilder: (context, url, __, ___) => Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.image_outlined,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          Text(imageAlts[url]?.isNotEmpty == true ? imageAlts[url]! : 'Image',
              style: theme.textTheme.bodyMedium),
        ],
      ),
    );
    if (fitContent) return body;
    return SizedBox(width: double.infinity, child: body);
  }
}

/// Notes show extra blank lines as space, which Markdown would collapse.
/// Each blank line beyond the paragraph break becomes a zero-width-space
/// paragraph for display only (Dart's trim keeps U+200B, unlike U+00A0); the saved note is unchanged. Empty ATX
/// headings (left by heading-formatting a multiline selection) count as blank
/// lines. Fenced code keeps its whitespace untouched.
String visibleBlankLinesMarkdown(String source) {
  final lines = source.split('\n');
  if (source.endsWith('\n')) lines.removeLast();
  final blank = RegExp(r'^(?:[ \t]*| {0,3}#{1,6}(?:[ \t]+#*[ \t]*)?)$');
  final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
  final out = <String>[];
  String? openFence;
  var run = 0;
  var seenContent = false;
  void flush({required bool atEnd}) {
    if (run == 0) return;
    // Between blocks the first blank line is the normal paragraph break.
    final extra = seenContent && !atEnd ? run - 1 : run;
    out.add('');
    for (var i = 0; i < extra; i++) {
      out
        ..add('\u200B')
        ..add('');
    }
    run = 0;
  }

  for (final line in lines) {
    final marker = fence.firstMatch(line)?.group(1);
    if (openFence != null) {
      out.add(line);
      if (marker != null &&
          marker[0] == openFence[0] &&
          marker.length >= openFence.length) {
        openFence = null;
      }
      continue;
    }
    if (blank.hasMatch(line)) {
      run++;
      continue;
    }
    flush(atEnd: false);
    seenContent = true;
    if (marker != null) openFence = marker;
    out.add(line);
  }
  flush(atEnd: true);
  return out.join('\n');
}

// Horizontal scrollables treat a point to their left as preceding their
// content, even when it is below them. Indented code/tables therefore capture
// drags on later paragraphs. Resolve vertical block order before forwarding
// those out-of-bounds edges; in-block gestures retain native scrolling.
class _MarkdownSelectionOrder extends StatefulWidget {
  const _MarkdownSelectionOrder({required this.child});
  final Widget child;

  @override
  State<_MarkdownSelectionOrder> createState() =>
      _MarkdownSelectionOrderState();
}

class _MarkdownSelectionOrderState extends State<_MarkdownSelectionOrder> {
  final _delegate = _MarkdownSelectionDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionContainer(
        delegate: _delegate,
        child: widget.child,
      );
}

class _MarkdownSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectionResult dispatchSelectionEventToChild(
      Selectable selectable, SelectionEvent event) {
    if (event is SelectionEdgeUpdateEvent) {
      final bounds = MatrixUtils.transformRect(
        selectable.getTransformTo(null),
        Offset.zero & selectable.size,
      );
      final point = event.globalPosition;
      final Offset adjusted;
      if (point.dy > bounds.bottom) {
        adjusted = Offset(bounds.right + 1, point.dy);
      } else if (point.dy < bounds.top) {
        adjusted = Offset(bounds.left - 1, point.dy);
      } else {
        adjusted = point;
      }
      event = event.type == SelectionEventType.startEdgeUpdate
          ? SelectionEdgeUpdateEvent.forStart(
              globalPosition: adjusted, granularity: event.granularity)
          : SelectionEdgeUpdateEvent.forEnd(
              globalPosition: adjusted, granularity: event.granularity);
    }
    return super.dispatchSelectionEventToChild(selectable, event);
  }
}

/// One light/dark theme-derived style sheet for every AX Markdown surface.
abstract final class SyntilaMessageTypography {
  static TextStyle fromTheme(ThemeData theme) => TextStyle(
        fontFamily: SyntilaTypography.fontFamily,
        fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: SyntilaColors.textPrimary(theme.brightness == Brightness.dark),
      );
}

abstract final class SyntilaMarkdownStyleSheet {
  static MarkdownStyleSheet fromTheme(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final body = SyntilaMessageTypography.fromTheme(theme);
    TextStyle heading(double size) => body.copyWith(
          fontSize: size,
          fontWeight: FontWeight.w600,
          height: 1.3,
        );
    final code = body.copyWith(
      fontFamily: SyntilaTypography.fontFamilyMono,
      fontFamilyFallback: SyntilaTypography.fontFamilyMonoFallback,
      fontSize: (body.fontSize ?? 14) * 0.9,
      backgroundColor: SyntilaColors.codeBackground(isDark),
    );
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      a: TextStyle(
          color: SyntilaColors.primaryForeground(isDark),
          decoration: TextDecoration.underline),
      h1: heading(22),
      h2: heading(19),
      h3: heading(17),
      h4: heading(15),
      h5: heading(14),
      h6: heading(13),
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: const TextStyle(fontWeight: FontWeight.w700),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
      code: code,
      listBullet: body,
      listIndent: 24,
      blockSpacing: 10,
      checkbox: body.copyWith(color: SyntilaColors.primary),
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body,
      // Intrinsic columns let flutter_markdown_plus place wide tables in its
      // horizontal scroll container instead of forcing them into the message
      // width and causing overflow.
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableBorder: TableBorder.all(color: SyntilaColors.border(isDark)),
      tableCellsPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      tableHeadCellsDecoration: BoxDecoration(
        color: SyntilaColors.codeBackground(isDark),
      ),
      blockquote: body.copyWith(color: SyntilaColors.textSecondary(isDark)),
      blockquotePadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      blockquoteDecoration: BoxDecoration(
        color: isDark
            ? SyntilaColors.surfaceDark
            : SyntilaColors.surfaceHoverLight,
        border: Border(
            left: BorderSide(color: SyntilaColors.border(isDark), width: 3)),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: SyntilaColors.codeBackground(isDark),
        border: Border.all(color: SyntilaColors.border(isDark)),
        borderRadius: BorderRadius.circular(SyntilaRadius.md),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: SyntilaColors.border(isDark))),
      ),
    );
  }
}

/// gpt_markdown counterpart of [SyntilaMarkdownStyleSheet] for messages.
abstract final class SyntilaGptMarkdownStyleSheet {
  static GptMarkdownStyleSheet fromTheme(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final body = SyntilaMessageTypography.fromTheme(theme);
    return GptMarkdownStyleSheet(
      heading: HeadingStyle(
        textStyle: TextStyle(
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: body.color,
        ),
      ),
      link: LinkStyle(
        color: SyntilaColors.primaryForeground(isDark),
        hoverColor: SyntilaColors.primaryForeground(isDark),
        decoration: TextDecoration.underline,
      ),
      inlineCode: InlineCodeStyle(
        fontFamily: SyntilaTypography.fontFamilyMono,
        fontFamilyFallback: SyntilaTypography.fontFamilyMonoFallback,
        fontSizeFactor: 0.9,
        color: body.color,
        backgroundColor: SyntilaColors.codeBackground(isDark),
        borderColor: SyntilaColors.border(isDark),
      ),
      list:
          ListStyle(bulletColor: body.color, markerTextStyle: body, indent: 24),
      table: TableStyle(
        borderColor: SyntilaColors.border(isDark),
        cellPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        headerBackground: SyntilaColors.codeBackground(isDark),
        headerTextStyle: body.copyWith(fontWeight: FontWeight.w600),
      ),
      blockQuote: BlockQuoteStyle(
        barWidth: 3,
        barColor: SyntilaColors.border(isDark),
        backgroundColor: isDark
            ? SyntilaColors.surfaceDark
            : SyntilaColors.surfaceHoverLight,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: body.copyWith(color: SyntilaColors.textSecondary(isDark)),
      ),
      hr: HrStyle(color: SyntilaColors.border(isDark), thickness: 1),
    );
  }
}
