import 'dart:convert';

import 'view_preferences_stub.dart'
    if (dart.library.js_interop) 'view_preferences_web.dart' as platform;

/// App-wide text size. Standard is the original size.
enum TextSizeOption {
  standard('Default', 1.0),
  large('Large', 1.15),
  extraLarge('Extra large', 1.3);

  const TextSizeOption(this.label, this.scale);

  final String label;
  final double scale;

  static TextSizeOption fromName(Object? name) => values
      .firstWhere((option) => option.name == name, orElse: () => standard);
}

/// Sidebar and layout choices that apply to this device only.
class ViewPreferences {
  const ViewPreferences({
    this.showRecentThreads = true,
    this.recentThreadsCount = defaultRecentThreadsCount,
    this.textSize = TextSizeOption.standard,
  });

  static const defaultRecentThreadsCount = 7;

  /// Fixed choices offered in Settings; stored values snap to the nearest one.
  static const recentThreadsCountOptions = [4, 7, 10];

  final bool showRecentThreads;
  final int recentThreadsCount;
  final TextSizeOption textSize;

  ViewPreferences copyWith(
          {bool? showRecentThreads,
          int? recentThreadsCount,
          TextSizeOption? textSize}) =>
      ViewPreferences(
        textSize: textSize ?? this.textSize,
        showRecentThreads: showRecentThreads ?? this.showRecentThreads,
        recentThreadsCount:
            _clampCount(recentThreadsCount ?? this.recentThreadsCount),
      );

  static int _clampCount(int value) =>
      recentThreadsCountOptions.reduce((best, option) =>
          (option - value).abs() < (best - value).abs() ? option : best);

  String encode() => jsonEncode({
        'showRecentThreads': showRecentThreads,
        'recentThreadsCount': recentThreadsCount,
        'textSize': textSize.name,
      });

  static ViewPreferences decode(String? raw) {
    if (raw == null) return const ViewPreferences();
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const ViewPreferences();
      final show = json['showRecentThreads'];
      final count = json['recentThreadsCount'];
      return ViewPreferences(
        showRecentThreads: show is bool ? show : true,
        recentThreadsCount:
            count is int ? _clampCount(count) : defaultRecentThreadsCount,
        textSize: TextSizeOption.fromName(json['textSize']),
      );
    } catch (_) {
      return const ViewPreferences();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ViewPreferences &&
      other.showRecentThreads == showRecentThreads &&
      other.recentThreadsCount == recentThreadsCount &&
      other.textSize == textSize;

  @override
  int get hashCode =>
      Object.hash(showRecentThreads, recentThreadsCount, textSize);
}

/// Device-local storage for [ViewPreferences], independent of account and Cloud.
class ViewPreferencesStore {
  ViewPreferencesStore({required this.read, required this.write});

  final String? Function() read;
  final void Function(String value) write;

  ViewPreferences load() {
    try {
      return ViewPreferences.decode(read());
    } catch (_) {
      return const ViewPreferences();
    }
  }

  void save(ViewPreferences preferences) {
    try {
      write(preferences.encode());
    } catch (_) {
      // Storage can be unavailable; the current session still keeps its choice.
    }
  }
}

ViewPreferencesStore createViewPreferencesStore() =>
    platform.createViewPreferencesStore();
