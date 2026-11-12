import 'package:syntila_design/syntila_design.dart';
import 'quiet_notices.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight_core.dart' as hl;
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/yaml.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/css.dart';
import 'package:markdown/markdown.dart' as md;

/// The renderer hook lacks a language argument. The block builder supplies
/// fence metadata to this same SyntaxHighlighter implementation per block.
class SyntilaSyntaxHighlighter extends SyntaxHighlighter {
  SyntilaSyntaxHighlighter(this.theme, {this.language = ''});
  final ThemeData theme;
  final String language;
  static final _engine = hl.Highlight()
    ..registerLanguage('dart', dart)
    ..registerLanguage('typescript', typescript)
    ..registerLanguage('javascript', javascript)
    ..registerLanguage('json', json)
    ..registerLanguage('yaml', yaml)
    ..registerLanguage('sql', sql)
    ..registerLanguage('bash', bash)
    ..registerLanguage('python', python)
    ..registerLanguage('xml', xml)
    ..registerLanguage('css', css);

  @override
  TextSpan format(String source) {
    final canonical = switch (language.toLowerCase()) {
      'ts' || 'tsx' => 'typescript',
      'js' || 'jsx' => 'javascript',
      'yml' => 'yaml',
      'sh' || 'shell' => 'bash',
      'py' => 'python',
      'html' => 'xml',
      _ => language.toLowerCase(),
    };
    const supported = {
      'dart',
      'typescript',
      'javascript',
      'json',
      'yaml',
      'sql',
      'bash',
      'python',
      'xml',
      'css'
    };
    final base = TextStyle(
        fontFamily: SyntilaTypography.fontFamilyMono,
        fontFamilyFallback: SyntilaTypography.fontFamilyMonoFallback,
        fontSize: 12.5,
        height: 1.45,
        color: theme.colorScheme.onSurface);
    if (!supported.contains(canonical) || source.length > 50000) {
      return TextSpan(text: source, style: base);
    }
    final dark = theme.brightness == Brightness.dark;
    Color? tokenColor(String? name) => switch (name) {
          'keyword' ||
          'selector-tag' ||
          'tag' =>
            SyntilaColors.syntaxKeyword(dark),
          'string' || 'attr' || 'attribute' => SyntilaColors.syntaxString(dark),
          'number' || 'literal' => SyntilaColors.syntaxNumber(dark),
          'comment' => theme.colorScheme.onSurfaceVariant,
          'title' || 'built_in' => SyntilaColors.syntaxTitle(dark),
          _ => null,
        };
    TextSpan span(hl.Node node) => TextSpan(
        text: node.value,
        style: TextStyle(color: tokenColor(node.className)),
        children: node.children?.map(span).toList());
    try {
      return TextSpan(
          style: base,
          children: _engine
              .parse(source, language: canonical)
              .nodes
              ?.map(span)
              .toList());
    } catch (_) {
      return TextSpan(text: source, style: base);
    }
  }
}

class SyntilaCodeBlock extends StatelessWidget {
  const SyntilaCodeBlock(
      {super.key, required this.code, this.language = '', this.wordWrap});
  final String code;
  final String language;

  /// Whether code lines should wrap or scroll horizontally.
  /// When not explicitly specified, languages like 'status' default to word wrapping.
  final bool? wordWrap;

  bool get _shouldWrap {
    if (wordWrap != null) return wordWrap!;
    return language.trim().toLowerCase() == 'status';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textWidget = Text.rich(
      SyntilaSyntaxHighlighter(theme, language: language).format(code),
      softWrap: _shouldWrap,
    );

    return Container(
      decoration: BoxDecoration(
          color: SyntilaColors.codeBackground(isDark),
          borderRadius: BorderRadius.circular(SyntilaRadius.md)),
      // Painted on top rather than as `decoration.border`: a bordered
      // decoration adds padding above the horizontal scrollable, after which
      // drags on text below the block select the code instead.
      foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
          border: Border.all(color: SyntilaColors.border(isDark))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SelectionContainer.disabled(
            child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(children: [
                  Text(language.isEmpty ? 'Code' : language,
                      style: theme.textTheme.labelSmall),
                  const Spacer(),
                  IconButton(
                      tooltip: 'Copy code',
                      iconSize: 16,
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: code));
                        if (context.mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showNotice(
                              const SnackBar(content: Text('Code copied')));
                        }
                      }),
                ]))),
        if (_shouldWrap)
          Padding(
            padding: const EdgeInsets.all(12),
            child: textWidget,
          )
        else
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: textWidget),
      ]),
    );
  }
}

class SyntilaCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final codeElement = element.children
        ?.whereType<md.Element>()
        .where((child) => child.tag == 'code')
        .firstOrNull;
    final tag = codeElement?.attributes['class'] ?? '';
    final language = tag.startsWith('language-') ? tag.substring(9) : '';
    return SyntilaCodeBlock(
        code: codeElement?.textContent ?? element.textContent,
        language: language);
  }
}
