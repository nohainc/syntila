/// One named check. [run] returns null when it passes, otherwise a short
/// reason code that is safe to show (no paths, secrets or provider output).
class ReadinessCheck {
  const ReadinessCheck(this.name, this.run);

  final String name;
  final Future<String?> Function() run;
}

class ReadinessReport {
  const ReadinessReport(this.failures);

  /// check name -> reason code
  final Map<String, String> failures;

  bool get ready => failures.isEmpty;

  Map<String, Object?> toJson() => {'ready': ready, 'failures': failures};
}

/// A Worker is Ready only when every check passes: credential, Profile
/// compatibility, local permissions, journal and Engine probe. A throwing
/// check counts as failed, never as passed.
class ReadinessChecker {
  ReadinessChecker(this.checks);

  final List<ReadinessCheck> checks;

  Future<ReadinessReport> evaluate() async {
    final failures = <String, String>{};
    for (final check in checks) {
      try {
        final reason = await check.run();
        if (reason != null) failures[check.name] = reason;
      } on Object {
        failures[check.name] = 'check_failed';
      }
    }
    return ReadinessReport(failures);
  }
}
