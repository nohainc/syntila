import 'dart:convert';

import 'view_preferences_stub.dart'
    if (dart.library.io) 'view_preferences_io.dart'
    if (dart.library.js_interop) 'view_preferences_web.dart' as platform;

/// App-wide text size. Standard is the original size.
enum TextSizeOption {
  standard('Default', 1.0),
  large('Large', 1.15),
  extraLarge('Extra large', 1.3);

  const TextSizeOption(this.label, this.scale);

  final String label;
  final double scale;

  double get pageWidth => switch (this) {
        standard => 500,
        large => 600,
        extraLarge => 700,
      };

  double get widePageWidth => this == extraLarge ? 1000 : 900;

  static TextSizeOption fromName(Object? name) => values
      .firstWhere((option) => option.name == name, orElse: () => standard);
}

/// Sidebar and layout choices that apply to this device only.
class ViewPreferences {
  const ViewPreferences({
    this.showRecentThreads = true,
    this.recentThreadsCount = defaultRecentThreadsCount,
    this.textSize = TextSizeOption.standard,
    this.sidebarCollapsed = false,
    this.sidebarWidth = defaultSidebarWidth,
    this.muteSound = false,
    this.collapsedSidebarGroups = const {},
  });

  static const defaultRecentThreadsCount = 7;
  static const defaultSidebarWidth = 200.0;
  static const minSidebarWidth = 200.0;
  static const maxSidebarWidth = 300.0;

  /// Fixed choices offered in Settings; stored values snap to the nearest one.
  static const recentThreadsCountOptions = [4, 7, 10];

  final bool showRecentThreads;
  final int recentThreadsCount;
  final TextSizeOption textSize;
  final bool sidebarCollapsed;
  final double sidebarWidth;
  final bool muteSound;

  /// Sidebar section labels the user has collapsed on this device.
  final Set<String> collapsedSidebarGroups;

  ViewPreferences copyWith(
          {bool? showRecentThreads,
          int? recentThreadsCount,
          TextSizeOption? textSize,
          bool? sidebarCollapsed,
          double? sidebarWidth,
          bool? muteSound,
          Set<String>? collapsedSidebarGroups}) =>
      ViewPreferences(
        textSize: textSize ?? this.textSize,
        showRecentThreads: showRecentThreads ?? this.showRecentThreads,
        recentThreadsCount:
            _clampCount(recentThreadsCount ?? this.recentThreadsCount),
        sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
        sidebarWidth: _clampSidebarWidth(sidebarWidth ?? this.sidebarWidth),
        muteSound: muteSound ?? this.muteSound,
        collapsedSidebarGroups:
            collapsedSidebarGroups ?? this.collapsedSidebarGroups,
      );

  static int _clampCount(int value) =>
      recentThreadsCountOptions.reduce((best, option) =>
          (option - value).abs() < (best - value).abs() ? option : best);

  static double _clampSidebarWidth(double value) => value.isFinite
      ? value.clamp(minSidebarWidth, maxSidebarWidth).toDouble()
      : defaultSidebarWidth;

  String encode() => jsonEncode({
        'showRecentThreads': showRecentThreads,
        'recentThreadsCount': recentThreadsCount,
        'textSize': textSize.name,
        'sidebarCollapsed': sidebarCollapsed,
        'sidebarWidth': sidebarWidth,
        'muteSound': muteSound,
        'collapsedSidebarGroups': collapsedSidebarGroups.toList()..sort(),
      });

  static ViewPreferences decode(String? raw) {
    if (raw == null) return const ViewPreferences();
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const ViewPreferences();
      final show = json['showRecentThreads'];
      final count = json['recentThreadsCount'];
      final collapsed = json['sidebarCollapsed'];
      final width = json['sidebarWidth'];
      final mute = json['muteSound'];
      final groups = json['collapsedSidebarGroups'];
      return ViewPreferences(
        showRecentThreads: show is bool ? show : true,
        recentThreadsCount:
            count is int ? _clampCount(count) : defaultRecentThreadsCount,
        textSize: TextSizeOption.fromName(json['textSize']),
        sidebarCollapsed: collapsed is bool ? collapsed : false,
        sidebarWidth: width is num
            ? _clampSidebarWidth(width.toDouble())
            : defaultSidebarWidth,
        muteSound: mute is bool ? mute : false,
        collapsedSidebarGroups:
            groups is List ? groups.whereType<String>().toSet() : const {},
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
      other.textSize == textSize &&
      other.sidebarCollapsed == sidebarCollapsed &&
      other.sidebarWidth == sidebarWidth &&
      other.muteSound == muteSound &&
      other.collapsedSidebarGroups.length == collapsedSidebarGroups.length &&
      other.collapsedSidebarGroups.containsAll(collapsedSidebarGroups);

  @override
  int get hashCode => Object.hash(
      showRecentThreads,
      recentThreadsCount,
      textSize,
      sidebarCollapsed,
      sidebarWidth,
      muteSound,
      Object.hashAllUnordered(collapsedSidebarGroups));
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
