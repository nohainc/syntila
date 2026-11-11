import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// One usage window (for example "5 hours" or "Week") of a Worker's provider.
@immutable
class AxUsageWindow {
  const AxUsageWindow({
    required this.label,
    required this.usedPercent,
    this.group,
    this.resetsAt,
    this.resetsText,
  });

  final String label;

  /// Optional model group the window belongs to (Gemini reports several).
  final String? group;

  /// Percentage of the window already used, 0-100.
  final double usedPercent;

  /// Exact reset instant when the provider reports one.
  final DateTime? resetsAt;

  /// Reset time exactly as printed, for providers that omit a time zone
  /// offset or an absolute instant.
  final String? resetsText;

  double get remainingPercent => 100 - usedPercent;
}

/// Provider usage normalized into a common shape.
@immutable
class AxParsedUsage {
  const AxParsedUsage({required this.windows, this.notes = const []});

  final List<AxUsageWindow> windows;
  final List<String> notes;
}

/// Normalizes a provider CLI usage report. Returns null whenever the text does
/// not match a known format exactly, so callers show the original output
/// instead of a partial or guessed table.
///
/// The format is detected from the text, not from the Worker, because the
/// usage command is defined by the Worker's Tool Profile and may change.
AxParsedUsage? parseWorkerUsage(String output, {DateTime? now}) {
  final text = output.trim();
  if (text.isEmpty) return null;
  try {
    if (text.startsWith('{')) {
      final json = jsonDecode(text);
      if (json is Map &&
          json['config'] is Map &&
          ((json['config'] as Map).containsKey('creditUsagePercent') ||
              (json['config'] as Map).containsKey('currentPeriod') ||
              (json['config'] as Map).containsKey('billingPeriodEnd') ||
              (json['config'] as Map).containsKey('billingPeriodStart') ||
              (json['config'] as Map).containsKey('prepaidBalance') ||
              (json['config'] as Map).containsKey('isUnifiedBillingUser') ||
              json.containsKey('subscription_tier'))) {
        return _parseGrok(json);
      }
      return text.contains('"quotaSnapshots"')
          ? _parseCopilot(text, now ?? DateTime.now())
          : _parseCodex(text);
    }
    if (text.contains('Current session') || text.contains('Current week')) {
      return _parseClaude(text, now ?? DateTime.now());
    }
    return _parseGemini(text);
  } on Object {
    return null;
  }
}

bool _validPercent(num value) => value >= 0 && value <= 100;

AxParsedUsage? _parseClaude(String text, DateTime now) {
  final pattern = RegExp(
      r'^Current (session|week[^:]*):\s*(\d+(?:\.\d+)?)%\s*used'
      r'(?:\s*·\s*resets\s*(.+?))?\s*$',
      multiLine: true);
  final windows = <AxUsageWindow>[];
  for (final match in pattern.allMatches(text)) {
    final used = double.parse(match.group(2)!);
    if (!_validPercent(used)) return null;
    final kind = match.group(1)!;
    windows.add(AxUsageWindow(
      label: kind == 'session'
          ? 'Session'
          : kind.contains('all models')
              ? 'Week'
              : 'Week${kind.substring(4).trim().isEmpty ? '' : ' ${kind.substring(4).trim()}'}',
      usedPercent: used,
      resetsAt: _claudeReset(match.group(3), now),
      resetsText: match.group(3),
    ));
  }
  if (windows.isEmpty) return null;
  return AxParsedUsage(windows: windows);
}

String _minutesLabel(int minutes) {
  if (minutes == 10080) return 'Week';
  if (minutes % 1440 == 0) return '${minutes ~/ 1440} days';
  if (minutes % 60 == 0) {
    final hours = minutes ~/ 60;
    return hours == 1 ? '1 hour' : '$hours hours';
  }
  return '$minutes minutes';
}

AxParsedUsage? _parseCodex(String text) {
  final json = jsonDecode(text);
  if (json is! Map) return null;
  final limits = json['rateLimits'];
  if (limits is! Map) return null;
  final windows = <AxUsageWindow>[];
  for (final key in const ['primary', 'secondary']) {
    final entry = limits[key];
    if (entry == null) continue;
    if (entry is! Map) return null;
    final used = entry['usedPercent'];
    final minutes = entry['windowDurationMins'];
    final resets = entry['resetsAt'];
    if (used is! num || !_validPercent(used) || minutes is! int) return null;
    windows.add(AxUsageWindow(
      label: _minutesLabel(minutes),
      usedPercent: used.toDouble(),
      resetsAt: resets is int
          ? DateTime.fromMillisecondsSinceEpoch(resets * 1000, isUtc: true)
          : null,
    ));
  }
  if (windows.isEmpty) return null;
  final notes = <String>[];
  final credits = json['rateLimitResetCredits'];
  if (credits is Map && credits['availableCount'] is int) {
    final count = credits['availableCount'] as int;
    if (count > 0) {
      notes.add('$count free rate limit reset${count == 1 ? '' : 's'} '
          'available');
    }
  }
  if (json['ordinaryUsageAllowed'] == false) {
    notes.add('Ordinary usage is currently not allowed');
  }
  return AxParsedUsage(windows: windows, notes: notes);
}

/// Grok ACP billing reports the percentage already consumed, not remaining.
/// When creditUsagePercent is omitted (e.g. Free subscription tier), it defaults
/// to 0% used if period metadata is present.
/// Keep monetary balances in the original output: their units are unspecified.
AxParsedUsage? _parseGrok(Map json) {
  final config = json['config'] is Map ? json['config'] as Map : json;
  final hasCreditUsage = config.containsKey('creditUsagePercent');
  final rawUsed = config['creditUsagePercent'];
  if (hasCreditUsage) {
    if (rawUsed is! num || !_validPercent(rawUsed)) return null;
  }
  final period = config['currentPeriod'];
  if (period != null && period is! Map) return null;
  final type = period is Map ? period['type'] : null;
  final label = switch (type) {
    'USAGE_PERIOD_TYPE_WEEKLY' => 'Week',
    'USAGE_PERIOD_TYPE_MONTHLY' => 'Month',
    'USAGE_PERIOD_TYPE_DAILY' => 'Day',
    _ => 'Credits',
  };
  final end =
      (period is Map ? period['end'] : null) ?? config['billingPeriodEnd'];
  final reset = end is String ? DateTime.tryParse(end) : null;
  if (end != null && reset == null) return null;
  if (!hasCreditUsage && period == null && config['billingPeriodEnd'] == null) {
    return null;
  }
  final used = (rawUsed as num?)?.toDouble() ?? 0.0;
  final notes = <String>[];
  final tier = json['subscription_tier'];
  if (tier is String && tier.trim().isNotEmpty) {
    notes.add('Plan: $tier');
  }
  return AxParsedUsage(
    windows: [
      AxUsageWindow(
        label: label,
        usedPercent: used,
        resetsAt: reset?.toUtc(),
      ),
    ],
    notes: notes,
  );
}

const _copilotQuotas = {
  'chat': 'Chat requests',
  'completions': 'Code completions',
  'premium_interactions': 'Premium requests',
};

/// GitHub Copilot `account.getQuota`: monthly request allowances. Its
/// `resetDate` has been observed equal to the snapshot time (already past), so
/// only a future reset is shown.
AxParsedUsage? _parseCopilot(String text, DateTime now) {
  final json = jsonDecode(text);
  if (json is! Map) return null;
  final snapshots = json['quotaSnapshots'];
  if (snapshots is! Map) return null;
  final windows = <AxUsageWindow>[];
  final notes = <String>[];
  for (final entry in _copilotQuotas.entries) {
    final quota = snapshots[entry.key];
    if (quota == null) continue;
    if (quota is! Map) return null;
    final label = entry.value;
    if (quota['isUnlimitedEntitlement'] == true) {
      notes.add('$label: unlimited');
      continue;
    }
    final entitlement = quota['entitlementRequests'];
    final used = quota['usedRequests'];
    if (entitlement is! num || used is! num || used < 0) return null;
    if (entitlement <= 0) {
      notes.add('$label: not included in this plan');
      continue;
    }
    final percent = (used / entitlement * 100).clamp(0, 100).toDouble();
    final reset = DateTime.tryParse('${quota['resetDate']}');
    windows.add(AxUsageWindow(
      label: label,
      usedPercent: percent,
      resetsAt: reset != null && reset.isAfter(now) ? reset : null,
    ));
    notes.add('$label: ${_count(used)} of ${_count(entitlement)} used');
    final overage = quota['overage'];
    if (overage is num && overage > 0) {
      notes.add('$label: ${_count(overage)} over the allowance');
    }
  }
  if (windows.isEmpty) return null;
  return AxParsedUsage(windows: windows, notes: notes);
}

String _count(num value) =>
    value == value.roundToDouble() ? '${value.toInt()}' : '$value';

AxParsedUsage? _parseGemini(String text) {
  final windows = <AxUsageWindow>[];
  final notes = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    final cells = line.split('\t').map((cell) => cell.trim()).toList();
    if (cells.length != 4) return null;
    if (cells[2].toLowerCase() == 'disabled') {
      if (cells[3].isNotEmpty) return null;
      notes.add('${cells[0]}: ${cells[1]} disabled');
      continue;
    }
    final percent = RegExp(r'^(\d+(?:\.\d+)?)%$').firstMatch(cells[2]);
    final resets = DateTime.tryParse(cells[3]);
    if (percent == null || resets == null) return null;
    final remaining = double.parse(percent.group(1)!);
    if (!_validPercent(remaining)) return null;
    final detail = cells[1];
    final label = detail.contains('Five Hour')
        ? '5 hours'
        : detail.contains('Weekly')
            ? 'Week'
            : detail;
    windows.add(AxUsageWindow(
      group: cells[0],
      label: label,
      usedPercent: 100 - remaining,
      resetsAt: resets.toUtc(),
    ));
  }
  if (windows.isEmpty && notes.isEmpty) return null;
  return AxParsedUsage(windows: windows, notes: notes);
}

bool _timeZonesInitialized = false;

// Claude omits the year. Resolve against the report's fetch time, in the
// explicitly reported IANA zone, rather than the browser's timezone.
DateTime? _claudeReset(String? text, DateTime now) {
  if (text == null) return null;
  final match = RegExp(
    r'^(?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm) \(([^)]+)\)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (match == null) return null;
  try {
    if (!_timeZonesInitialized) {
      tz_data.initializeTimeZones();
      _timeZonesInitialized = true;
    }
    final location = tz.getLocation(match.group(6)!);
    final localNow = tz.TZDateTime.from(now, location);
    final hour = int.parse(match.group(3)!);
    final minute = int.parse(match.group(4) ?? '0');
    if (hour < 1 || hour > 12 || minute > 59) return null;
    final h = hour % 12 + (match.group(5)!.toLowerCase() == 'pm' ? 12 : 0);
    final monthName = match.group(1)?.toLowerCase();
    final month = monthName == null
        ? localNow.month
        : const [
              'jan',
              'feb',
              'mar',
              'apr',
              'may',
              'jun',
              'jul',
              'aug',
              'sep',
              'oct',
              'nov',
              'dec'
            ].indexOf(monthName) +
            1;
    final day = int.parse(match.group(2) ?? '${localNow.day}');
    if (month == 0 ||
        day < 1 ||
        day > DateTime.utc(localNow.year, month + 1, 0).day) {
      return null;
    }
    var reset = tz.TZDateTime(location, localNow.year, month, day, h, minute);
    if (reset.isBefore(localNow)) {
      reset = monthName == null
          ? tz.TZDateTime(location, localNow.year, month, day + 1, h, minute)
          : tz.TZDateTime(location, localNow.year + 1, month, day, h, minute);
    }
    return reset.toUtc();
  } on Object {
    return null;
  }
}

/// Minute-resolution countdown; expired reports never roll into a new window.
String usageResetLabel(AxUsageWindow window, DateTime now) {
  final at = window.resetsAt;
  if (at == null) {
    return window.resetsText == null ? '' : 'Resets ${window.resetsText}';
  }
  final remaining = at.difference(now);
  if (remaining <= Duration.zero) return 'Reset time reached — refresh usage';
  final minutes = (remaining.inMilliseconds / 60000).ceil();
  // Weekly and multi-day (for example monthly) windows count in days.
  final weekly = window.label.startsWith('Week') || minutes >= 2880;
  final days = minutes ~/ 1440;
  final hours = weekly ? minutes % 1440 ~/ 60 : minutes ~/ 60;
  return 'Resets in ${weekly ? '$days d ' : ''}$hours hr ${minutes % 60} min';
}
