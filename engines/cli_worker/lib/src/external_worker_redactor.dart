/// Best-effort redaction for text that leaves the plugin host: stderr, error
/// and progress messages, and probe check messages. Pattern matching is not a
/// guarantee (see WORKER_PLUGIN_PROTOCOL_V1.md §7). It is never applied to
/// `result.output`, which is the user's work product.
class ExternalWorkerRedactor {
  ExternalWorkerRedactor({Iterable<String> secrets = const []})
    : _secrets = [
        for (final secret in secrets)
          if (secret.length >= 4) secret,
      ]..sort((a, b) => b.length.compareTo(a.length));

  final List<String> _secrets;

  static final _patterns = <RegExp>[
    RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    ),
    RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
    RegExp(r'Basic\s+[A-Za-z0-9+/=]{8,}'),
    RegExp(r'\bsk-[A-Za-z0-9_-]{16,}'),
    RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*'),
  ];

  static final _unixPath = RegExp(r'(?:/[A-Za-z0-9._~@+-]+){2,}/?');
  static final _windowsPath = RegExp(
    r'[A-Za-z]:\\(?:[^\\/:*?"<>|\r\n\s]+\\?)+',
  );

  String redact(String text) {
    var out = text;
    for (final secret in _secrets) {
      out = out.replaceAll(secret, '<redacted>');
    }
    for (final pattern in _patterns) {
      out = out.replaceAll(pattern, '<redacted>');
    }
    out = out.replaceAll(_windowsPath, '<path>');
    out = out.replaceAll(_unixPath, '<path>');
    return out;
  }
}
