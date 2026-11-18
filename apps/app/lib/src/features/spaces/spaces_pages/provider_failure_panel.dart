import 'package:flutter/material.dart';

import '../../../ax/ax_work_models.dart';

/// Displays canonical failure text alongside separately labelled provider
/// failure details and any response returned with a failed run.
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

  @override
  State<ProviderFailurePanel> createState() => _ProviderFailurePanelState();
}

class _ProviderFailurePanelState extends State<ProviderFailurePanel> {
  static const int _collapsedMaxChars = 600;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = widget.providerFailure;
    final hasNativeCode = details?.nativeErrorCode != null;
    final hasProviderError = details?.providerErrorText != null;
    final hasFailedResponse = details?.failedRunResponse != null;

    return Semantics(
      container: true,
      label: 'Failure details',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
          if (details != null &&
              (hasNativeCode ||
                  hasProviderError ||
                  hasFailedResponse ||
                  details.truncated ||
                  details.omitted)) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: scheme.error.withValues(alpha: 0.35),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Provider details',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (hasNativeCode)
                        Semantics(
                          label: 'Native error code ${details.nativeErrorCode}',
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Native code: ${details.nativeErrorCode}',
                              key: const ValueKey('provider-native-error-code'),
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (hasProviderError) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Provider error',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.error,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Semantics(
                      label: 'Provider error text',
                      child: SelectableText(
                        details.providerErrorText!,
                        key: const ValueKey('provider-error-text'),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                  if (hasFailedResponse) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Response from failed run',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildResponseBox(context, details.failedRunResponse!),
                  ],
                  if (details.truncated || details.omitted) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (details.truncated)
                          Text(
                            'Truncated to size limit.',
                            key: const ValueKey('provider-failure-truncated'),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if (details.omitted)
                          Text(
                            details.omittedFields.isEmpty
                                ? 'Sensitive content omitted.'
                                : 'Omitted sensitive field(s): ${details.omittedFields.join(', ')}.',
                            key: const ValueKey('provider-failure-omitted'),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResponseBox(BuildContext context, String responseText) {
    final scheme = Theme.of(context).colorScheme;
    final runes = responseText.runes;
    final isLong = runes.length > _collapsedMaxChars;
    final displayed = !isLong || _expanded
        ? responseText
        : '${String.fromCharCodes(runes.take(_collapsedMaxChars))}…';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            child: Semantics(
              label: 'Response from failed run',
              child: SelectableText(
                displayed,
                key: const ValueKey('failed-run-response-text'),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
        if (isLong)
          TextButton(
            key: const ValueKey('toggle-failed-run-response'),
            onPressed: () => setState(() => _expanded = !_expanded),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(_expanded ? 'Show less' : 'Show full response'),
          ),
      ],
    );
  }
}
