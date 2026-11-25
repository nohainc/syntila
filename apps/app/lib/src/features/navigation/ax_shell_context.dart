import '../../ax/sync/ax_query_builder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../platform/view_preferences.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import '../../ax/sync/ax_space_threads.dart';
import '../../ax/sync/ax_session_catalogs.dart';

enum ExecutionStatusTone {
  usable,
  degraded,
  neutral,
  failed,
}

extension ExecutionStatusToneHelpers on ExecutionStatusTone {
  Color color(bool isDark) {
    switch (this) {
      case ExecutionStatusTone.usable:
        return SyntilaBrand.success;
      case ExecutionStatusTone.degraded:
        return SyntilaBrand.warning;
      case ExecutionStatusTone.neutral:
        return SyntilaColors.neutral;
      case ExecutionStatusTone.failed:
        return SyntilaBrand.error;
    }
  }
}

/// Context model encapsulating state needed by the Syntila App Shell (Sidebar & HUD).
class AxShellContext {
  const AxShellContext({
    required this.navigation,
    required List<AxSpace> spaces,
    this.spaceListenable,
    this.spaceThreads,
    this.threadsBySpace = const {},
    this.selectedSpace,
    this.selectedThread,
    this.selectedRun,
    List<AxWorker> workers = const [],
    int unreadNotificationCount = 0,
    this.unreadNotifications,
    this.invitationsListenable,
    this.isDarkTheme = true,
    this.themeMode = ThemeMode.system,
    this.viewPreferences = const ViewPreferences(),
    this.onViewPreferencesChanged,
    bool realtimeStale = false,
    String? realtimeNotice,
    this.realtimeListenable,
    this.viewerDisplayName,
    this.viewerEmail,
    this.viewerAvatarUrl,
    this.viewerAvatarBytes,
    this.expandedSpaceIds = const {},
    this.catalogs,
  })  : _spaces = spaces,
        _workers = workers,
        _unreadNotificationCount = unreadNotificationCount,
        _realtimeStale = realtimeStale,
        _realtimeNotice = realtimeNotice;

  final AxNavigation navigation;
  final AxSessionCatalogs? catalogs;
  final List<AxSpace> _spaces;
  final ValueListenable<List<AxSpace>>? spaceListenable;
  List<AxSpace> get spaces => spaceListenable?.value ?? _spaces;
  List<AxSpace> get directSpaces =>
      sortAxSpacesByLastUpdate(spaces.where((space) => space.isDirect));
  List<AxSpace> get ownedSpaces => sortAxSpacesByLastUpdate(
      spaces.where((space) => !space.isDirect && space.role == 'owner'));
  List<AxSpace> get sharedSpaces => sortAxSpacesByLastUpdate(
      spaces.where((space) => !space.isDirect && space.role != 'owner'));
  final AxSpaceThreads? spaceThreads;
  final Map<String, List<AxThread>> threadsBySpace;
  final AxSpace? selectedSpace;
  final AxThread? selectedThread;
  final AxRun? selectedRun;
  final List<AxWorker> _workers;
  List<AxWorker> get workers => _workers;
  final int _unreadNotificationCount;
  final ValueListenable<int>? unreadNotifications;
  final ValueListenable<List<AxSpaceInvitation>>? invitationsListenable;
  List<AxSpaceInvitation> get invitations =>
      invitationsListenable?.value ?? const [];
  int get unreadNotificationCount =>
      unreadNotifications?.value ?? _unreadNotificationCount;
  Widget watchNotifications(Widget Function() build) {
    final listenable = unreadNotifications;
    return listenable == null
        ? build()
        : ValueListenableBuilder<int>(
            valueListenable: listenable, builder: (context, _, __) => build());
  }

  Widget watchInvitations(Widget Function() build) {
    final listenable = invitationsListenable;
    return listenable == null
        ? build()
        : ValueListenableBuilder<List<AxSpaceInvitation>>(
            valueListenable: listenable, builder: (context, _, __) => build());
  }

  Widget watchSpacesAndThreads(Widget Function() build) {
    Widget collections(int index) {
      final cache = spaceThreads;
      if (cache == null || index >= spaces.length) return build();
      return AxQueryBuilder<List<AxThread>>(
          engine: cache.engine,
          query: cache.query(spaces[index].id),
          ensure: false,
          builder: (context, _) => collections(index + 1));
    }

    final listenable = spaceListenable;
    return listenable == null
        ? collections(0)
        : ValueListenableBuilder<List<AxSpace>>(
            valueListenable: listenable,
            builder: (context, _, __) => collections(0));
  }

  final bool isDarkTheme;
  final ThemeMode themeMode;
  final ViewPreferences viewPreferences;
  final ValueChanged<ViewPreferences>? onViewPreferencesChanged;
  final bool _realtimeStale;
  final String? _realtimeNotice;
  final ValueListenable<(bool, String?)>? realtimeListenable;
  bool get realtimeStale => realtimeListenable?.value.$1 ?? _realtimeStale;
  String? get realtimeNotice => realtimeListenable == null
      ? _realtimeNotice
      : realtimeListenable!.value.$2;
  Widget watchExecution(Widget Function() build) => ListenableBuilder(
      listenable: Listenable.merge([realtimeListenable]),
      builder: (context, _) => build());
  final String? viewerDisplayName;
  final String? viewerEmail;
  final String? viewerAvatarUrl;
  final List<int>? viewerAvatarBytes;

  ImageProvider<Object>? get viewerAvatarImage {
    if (viewerAvatarBytes != null && viewerAvatarBytes!.isNotEmpty) {
      return MemoryImage(Uint8List.fromList(viewerAvatarBytes!));
    }
    final url = viewerAvatarUrl;
    if (url == null || url.isEmpty || _isPrivateAvatarUrl(url)) return null;
    return NetworkImage(url);
  }

  static bool _isPrivateAvatarUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri?.path.startsWith('/api/users/') == true &&
        uri?.path.endsWith('/avatar') == true;
  }

  final Set<String> expandedSpaceIds;

  int get readyWorkerCount => workers.where((w) => w.isReady).length;

  bool get isThreadContext =>
      selectedThread != null ||
      navigation.kind == AxRouteKind.thread ||
      navigation.kind == AxRouteKind.run;

  String get executionStatusLabel {
    if (workers.isEmpty) return 'No Workers';
    final total = workers.length;
    return '$readyWorkerCount / $total ${total == 1 ? 'Worker' : 'Workers'} online';
  }

  ExecutionStatusTone get executionStatusTone {
    if (realtimeStale) return ExecutionStatusTone.degraded;
    if (workers.isEmpty) return ExecutionStatusTone.neutral;
    return readyWorkerCount > 0
        ? ExecutionStatusTone.usable
        : ExecutionStatusTone.failed;
  }

  String get viewerInitials {
    final name = (viewerDisplayName ?? viewerEmail ?? '').trim();
    if (name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+')).where((part) => part.isNotEmpty);
    final initials = parts.take(2).map((part) => part[0]).join();
    return initials.isNotEmpty ? initials.toUpperCase() : '?';
  }

  bool isSpaceExpanded(String spaceId) => expandedSpaceIds.contains(spaceId);

  bool isNavActive(AxNavigation? target) {
    if (target == null) return false;
    switch (target.kind) {
      case AxRouteKind.home:
        return navigation.kind == AxRouteKind.home;
      case AxRouteKind.spaces:
        return navigation.kind == AxRouteKind.spaces ||
            navigation.kind == AxRouteKind.space ||
            navigation.kind == AxRouteKind.spaceMembers ||
            navigation.kind == AxRouteKind.thread ||
            navigation.kind == AxRouteKind.run;
      case AxRouteKind.space:
        return (navigation.kind == AxRouteKind.space ||
                navigation.kind == AxRouteKind.spaceMembers ||
                navigation.kind == AxRouteKind.thread ||
                navigation.kind == AxRouteKind.run) &&
            target.spaceId != null &&
            navigation.spaceId == target.spaceId;
      case AxRouteKind.spaceMembers:
        return navigation.kind == target.kind &&
            target.spaceId != null &&
            navigation.spaceId == target.spaceId;
      case AxRouteKind.thread:
        return navigation.kind == AxRouteKind.thread &&
            target.threadId != null &&
            navigation.threadId == target.threadId;
      case AxRouteKind.people:
        return navigation.kind == AxRouteKind.people;
      case AxRouteKind.notes:
        return navigation.kind == AxRouteKind.notes;
      case AxRouteKind.files:
        return navigation.kind == AxRouteKind.files;
      case AxRouteKind.archivedSpaces:
        return navigation.kind == AxRouteKind.archivedSpaces;
      case AxRouteKind.workers:
        return navigation.kind == AxRouteKind.workers;
      case AxRouteKind.profileSecurity:
        return navigation.kind == AxRouteKind.profileSecurity;
      case AxRouteKind.settings:
        return navigation.kind == AxRouteKind.settings;
      case AxRouteKind.run:
        return navigation.kind == AxRouteKind.run &&
            target.runId != null &&
            navigation.runId == target.runId;
      case AxRouteKind.login:
        return navigation.kind == AxRouteKind.login;
      case AxRouteKind.desktopAuthApproval:
        return false;
      case AxRouteKind.search:
        return navigation.kind == AxRouteKind.search;
    }
  }
}
