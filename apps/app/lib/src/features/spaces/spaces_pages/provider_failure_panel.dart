import 'package:flutter/material.dart';

import '../../../ax/ax_work_models.dart';
import '../../common/syntila_markdown_body.dart';

/// Shows why a Work step failed: the readable provider error, or its technical
/// diagnostic when no readable error is available, plus
/// any native code and response returned with the failed run.
class ProviderFailurePanel extends StatefulWidget {
  const ProviderFailurePanel({
    super.key,
    required this.canonicalMessage,
    this.errorCode,
    this.providerFailure,
    this.providerFailureUnavailable = false,
    this.canonicalStyle,
  });

  final String canonicalMessage;
  final String? errorCode;
  final AxProviderFailureDetails? providerFailure;
  final bool providerFailureUnavailable;
  final TextStyle? canonicalStyle;

  // Provider stderr can contain timestamped internal logs followed by a
  // separate user-facing error. Keep logs if they are the only information.
  static String _displayError(String text) {
    final logLine = RegExp(
      r'^\s*\d{4}-\d{2}-\d{2}T\S+\s+(?:ERROR|WARN|INFO|DEBUG|TRACE)\s+\S+[: ]',
    );
    final lines = text.split('\n');
    if (!lines.any(logLine.hasMatch)) return text;
    final readable =
        lines.where((line) => !logLine.hasMatch(line)).join('\n').trim();
    return readable.isEmpty ? text : readable;
  }

  /// The text the panel shows, for the Copy action: the provider's error (or
  /// the generic message without one), then the native code and failed-run
  /// response when present.
  static String visibleText(
      String canonicalMessage, AxProviderFailureDetails? details) {
    return [
      details?.providerErrorText == null
          ? canonicalMessage
          : _displayError(details!.providerErrorText!),
      if (details?.nativeErrorCode != null)
        'Native code: ${details!.nativeErrorCode}',
      if (details?.failedRunResponse != null) details!.failedRunResponse!,
    ].join('\n\n');
  }

  @override
  State<ProviderFailurePanel> createState() => _ProviderFailurePanelState();
}

class _ProviderFailurePanelState extends State<ProviderFailurePanel> {
  static const int _collapsedMaxChars = 600;
  bool _expanded = false;
  bool _errorExpanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = widget.providerFailure;
    final hasNativeCode = details?.nativeErrorCode != null;
    final hasProviderError = details?.providerErrorText != null;
    final hasFailedResponse = details?.failedRunResponse != null;
    final muted = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    // The provider's text is the message itself, so it uses the normal message
    // style; only the notes around it are small.
    final message = SyntilaMessageTypography.fromTheme(Theme.of(context));

    return Semantics(
      container: true,
      label: 'Failure details',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The provider's own message says more than our generic line, so it
          // replaces it. The generic message is shown only without one.
          if (hasProviderError)
            _collapsible(
              ProviderFailurePanel._displayError(details!.providerErrorText!),
              textKey: const ValueKey('provider-error-text'),
              toggleKey: const ValueKey('toggle-provider-error'),
              expanded: _errorExpanded,
              onToggle: () => setState(() => _errorExpanded = !_errorExpanded),
              style: widget.canonicalStyle ??
                  message.copyWith(color: scheme.error),
              semanticsLabel: details.source == 'agent'
                  ? 'Worker error text'
                  : 'Provider error text',
              showMore: 'Show more',
              showLess: 'Show less',
            )
          else
            SelectableText(
              widget.canonicalMessage,
              key: const ValueKey('canonical-failure-message'),
              style: widget.canonicalStyle ??
                  TextStyle(fontSize: 12, color: scheme.error),
            ),
          if (widget.providerFailureUnavailable) ...[
            const SizedBox(height: 6),
            Text('Provider details are unavailable.',
                key: const ValueKey('provider-failure-unavailable'),
                style: muted),
          ],
          if (hasNativeCode) ...[
            const SizedBox(height: 6),
            Semantics(
              label: 'Native error code ${details!.nativeErrorCode}',
              child: Text(
                'Native code: ${details.nativeErrorCode}',
                key: const ValueKey('provider-native-error-code'),
                style: muted.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ],
          if (hasFailedResponse) ...[
            const SizedBox(height: 8),
            Text(
              'Response from failed run',
              style: muted.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            _collapsible(
              details!.failedRunResponse!,
              textKey: const ValueKey('failed-run-response-text'),
              toggleKey: const ValueKey('toggle-failed-run-response'),
              expanded: _expanded,
              onToggle: () => setState(() => _expanded = !_expanded),
              style: message,
              semanticsLabel: 'Response from failed run',
              showMore: 'Show full response',
              showLess: 'Show less',
            ),
          ],
          if (details != null && (details.truncated || details.omitted)) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (details.truncated)
                  Text('Truncated to size limit.',
                      key: const ValueKey('provider-failure-truncated'),
                      style: muted),
                if (details.omitted)
                  Text(
                    details.omittedFields.isEmpty
                        ? 'Sensitive content omitted.'
                        : 'Omitted sensitive field(s): ${details.omittedFields.join(', ')}.',
                    key: const ValueKey('provider-failure-omitted'),
                    style: muted,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Selectable text that collapses after [_collapsedMaxChars] characters
  /// (never splitting a character) with a toggle to show all of it.
  Widget _collapsible(
    String text, {
    required Key textKey,
    required Key toggleKey,
    required bool expanded,
    required VoidCallback onToggle,
    required TextStyle style,
    required String semanticsLabel,
    required String showMore,
    required String showLess,
  }) {
    final runes = text.runes;
    final isLong = runes.length > _collapsedMaxChars;
    final displayed = !isLong || expanded
        ? text
        : '${String.fromCharCodes(runes.take(_collapsedMaxChars))}…';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            child: Semantics(
              label: semanticsLabel,
              child: SelectableText(displayed, key: textKey, style: style),
            ),
          ),
        ),
        if (isLong)
          TextButton(
            key: toggleKey,
            onPressed: onToggle,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(expanded ? showLess : showMore),
          ),
      ],
    );
  }
}
