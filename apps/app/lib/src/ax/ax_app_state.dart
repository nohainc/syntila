part of 'ax_app.dart';

mixin _AxAppStateMixin on State<SyntilaAppShell> {
  AxSnapshot get executionSnapshot => store.execution;
  String? selectedSpaceId;
  RunStatus? optimisticRunStatus;
  bool isLoading = true;
  String? loadError;
  String? selectedTaskId = 'implement';
  final Set<String> _readHomeAttentionIds = <String>{};
  final Set<String> expandedSpaceIds = <String>{};
  // Spaces whose stored `sidebarExpanded` has been applied this session, so
  // later refreshes never override a manual expand/collapse.
  final Set<String> _sidebarRestoredSpaceIds = <String>{};
  List<AxWorker> get workspaceWorkers =>
      store.syncEngine.peek(store.catalogs.workers).data ?? const [];
  bool get workspaceWorkerInventoryLoaded =>
      store.syncEngine.peek(store.catalogs.workers).hasData;
  final authNameController = TextEditingController();
  final authEmailController = TextEditingController();
  final authPasswordController = TextEditingController();
  final authConfirmPasswordController = TextEditingController();
  final authVerificationCodeController = TextEditingController();
  final AxBrowserAlerts browserAlerts = createAxBrowserAlerts();
  List<AxNotification> get notifications => store.notifications;
  void _updateNotifications(VoidCallback callback) {
    callback();
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'SyntilaAppShell',
      operation: 'notifications.changed',
    );
    store.unreadNotifications.value =
        notifications.where((n) => !n.read).length;
  }

  late final AxStore store;
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final AxBrowserNavigation browserNavigation;
  late AxNavigation navigation;
  StreamSubscription<Uri>? navigationSubscription;
  StreamSubscription<void>? lifecycleSubscription;
  Timer? _readTimer;
  StreamSubscription<bool>? connectivitySubscription;
  late final RealtimeClient realtimeClient;
  StreamSubscription<Map<String, dynamic>>? realtimeSubscription;
  bool realtimeStarted = false;
  bool realtimeReadyOnce = false;
  void Function()? _cancelWorkRealtime;

  bool authRequired = false;
  bool isReconnecting = false;
  bool get realtimeStale => store.realtimeStatus.value.$1;
  set realtimeStale(bool value) {
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'SyntilaAppShell',
      operation: 'realtime.stale.changed',
    );
    store.realtimeStatus.value = (value, realtimeNotice);
  }

  bool _realtimeTransportConnected = false;

  /// Invitation IDs already shown to the viewer. Null until the first load,
  /// so existing invitations are not announced as new.
  Set<String>? _knownInvitationIds;
  int _realtimeRecoveryGeneration = 0;
  String? get realtimeNotice => store.realtimeStatus.value.$2;
  set realtimeNotice(String? value) {
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'SyntilaAppShell',
      operation: 'realtime.notice.changed',
    );
    store.realtimeStatus.value = (realtimeStale, value);
  }

  void _updateLiveState(VoidCallback callback) => callback();
  bool authSignUp = false;
  bool authSignUpAwaitingCode = false;
  bool authResetRequest = false;
  bool authBusy = false;
  bool authPasswordVisible = false;
  bool authConfirmPasswordVisible = false;
  bool desktopAuthBusy = false;
  bool desktopAuthApproved = false;
  bool desktopAuthCancelled = false;
  AxDesktopAuthIntentStatus? desktopAuthIntentStatus;
  String? _desktopAuthIntentId;
  Timer? _desktopAuthStatusTimer;
  bool _desktopAuthStatusRequestActive = false;
  String? desktopAuthError;
  String? authNotice;
  String? authError;

  void _resetSensitiveAuthInputs() {
    authPasswordController.clear();
    authConfirmPasswordController.clear();
    authVerificationCodeController.clear();
    authPasswordVisible = false;
    authConfirmPasswordVisible = false;
    authSignUpAwaitingCode = false;
  }

  void _dismissOpenModalRoutes() {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.popUntil((route) => route.isFirst);
  }

  Future<void>? _accountSecurityLoadFlight;
  Future<void>? _disconnectSessionCheck;
  final promptResponseController = TextEditingController();
  final TextEditingController _searchQueryController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  AxNavigation? _navigationBeforeSearch;
  AxAccountSecurity? get accountSecurity => store.security.value;
  set accountSecurity(AxAccountSecurity? value) {
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'SyntilaAppShell',
      operation: 'account.security.changed',
    );
    store.security.value = value;
  }

  final Set<String> revokingAccountSessionTokens = <String>{};
  bool avatarUploadBusy = false;
  List<int>? viewerAvatarBytes;
  bool get accountSecurityLoading => store.securityLoading.value;
  set accountSecurityLoading(bool value) {
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'SyntilaAppShell',
      operation: 'account.security.loading.changed',
    );
    store.securityLoading.value = value;
  }

  void _updateSecurity(VoidCallback callback) => callback();
  bool _isCurrentAccountSession(AxAuthSession session) {
    final currentSessionId = store.auth.session?.sessionId;
    return currentSessionId != null &&
        currentSessionId != '—' &&
        (session.id == currentSessionId || session.token == currentSessionId);
  }

  bool revokingAllAccountSessions = false;
  bool deletingAccount = false;
  final unlinkingAccountIds = <String>{};
  String? accountUnlinkError;
  late final ThemePreference _themePreference;
  ThemeMode _themeMode = ThemeMode.system;
  late final ViewPreferencesStore _viewPreferencesStore;
  ViewPreferences _viewPreferences = const ViewPreferences();
  bool _desktopSidebarCollapsed = false;
  double _desktopSidebarWidth = ResizableSidebar.minWidth;
  final _mobileSpacesScroll = ScrollController();
  String? _mobileSpaceFilter;
  bool get showRunDetails => switch (navigation.kind) {
        AxRouteKind.home => false,
        _ => true,
      };

  /// Pop-ups are intentionally not shown (see quiet_notices.dart); callers
  /// keep reporting outcomes here so they can be surfaced differently later.
  void _showSnackBar(String message, {ToastType type = ToastType.info}) =>
      quietNotice(Text(message));

  void _onSearchQueryChanged() {
    final newQuery = _searchQueryController.text.trim();
    if (newQuery == _searchQuery) return;
    if (_searchQuery.isEmpty && newQuery.isNotEmpty) {
      if (navigation.kind != AxRouteKind.search) {
        _navigationBeforeSearch = navigation;
      }
      setState(() {
        _searchQuery = newQuery;
        navigation = AxNavigation.search(newQuery);
      });
    } else if (_searchQuery.isNotEmpty && newQuery.isEmpty) {
      final restoreNav = _navigationBeforeSearch ?? const AxNavigation.home();
      _navigationBeforeSearch = null;
      setState(() {
        _searchQuery = '';
        navigation = restoreNav;
      });
    } else {
      setState(() {
        _searchQuery = newQuery;
        if (navigation.kind == AxRouteKind.search) {
          navigation = AxNavigation.search(newQuery);
        }
      });
    }
  }

  void _clearSearch() {
    setState(() {
      _searchQuery = '';
      if (_searchQueryController.text.isNotEmpty) {
        _searchQueryController.clear();
      }
      if (navigation.kind == AxRouteKind.search) {
        final restoreNav = _navigationBeforeSearch ?? const AxNavigation.home();
        _navigationBeforeSearch = null;
        navigation = restoreNav;
      }
    });
  }

  void _focusSearch() {
    _searchFocusNode.requestFocus();
  }

  void _openCommandPalette() {
    _focusSearch();
  }

  AxSpace? get selectedSpace {
    final id = navigation.spaceId ?? selectedSpaceId;
    if (id == null) return null;
    return store.spaceDetails.peek(id) ??
        store.spaces.items.where((space) => space.id == id).firstOrNull;
  }

  List<AxWorkspace> get workspaces => store.workspaces.items;
  AxTask? get selectedTask => executionSnapshot.tasks
      .where((task) => task.id == selectedTaskId)
      .firstOrNull;
  AxThread? get selectedThread {
    final space = selectedSpace;
    return (space == null ? <AxThread>[] : store.spaceThreads.peek(space.id))
        .where((thread) =>
            thread.id == navigation.threadId ||
            thread.id == navigation.threadId)
        .firstOrNull;
  }

  bool get _tabVisible {
    final nav = browserNavigation;
    return nav is! AxBrowserVisibility || (nav as AxBrowserVisibility).visible;
  }

  /// The open Thread in a visible tab counts as read. [force] also advances
  /// the marker when no unread flag is cached, for activity that just arrived.
  void _scheduleMarkViewedRead({bool force = false}) {
    final threadId = navigation.threadId;
    final spaceId = navigation.spaceId;
    if (navigation.kind != AxRouteKind.thread ||
        threadId == null ||
        spaceId == null ||
        store.auth.session?.authenticated != true) {
      return;
    }
    _readTimer?.cancel();
    _readTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted ||
          !_tabVisible ||
          navigation.threadId != threadId ||
          navigation.spaceId != spaceId) {
        return;
      }
      final flagged = store.spaceThreads
          .peek(spaceId)
          .any((thread) => thread.id == threadId && thread.hasUnread);
      if (force || flagged) {
        unawaited(store.spaceThreads.markRead(spaceId, threadId));
      }
    });
  }

  bool _viewedThreadActivity(String threadId) {
    if (navigation.kind != AxRouteKind.thread ||
        navigation.threadId != threadId ||
        !_tabVisible) {
      return false;
    }
    _scheduleMarkViewedRead(force: true);
    return true;
  }

  String? get executionWorkspaceId => executionSnapshot.workspaceId;
  int get unreadNotificationCount =>
      notifications.where((notification) => !notification.read).length;
  AxShellContext get _shellContext => AxShellContext(
        navigation: navigation,
        spaces: store.spaces.items,
        spaceListenable: store.spaces,
        workspaceListenable: store.workspaces,
        spaceThreads: store.spaceThreads,
        selectedSpace: selectedSpace,
        selectedThread: selectedThread,
        selectedRun: executionSnapshot.run,
        workspaces: store.workspaces.items,
        unreadNotificationCount: unreadNotificationCount,
        unreadNotifications: store.unreadNotifications,
        invitationsListenable: store.invitations,
        workspaceInvitationsListenable: store.workspaceInvitations,
        isDarkTheme: _themeMode == ThemeMode.dark ||
            (_themeMode == ThemeMode.system &&
                Theme.of(context).brightness == Brightness.dark),
        themeMode: _themeMode,
        viewPreferences: _viewPreferences,
        realtimeStale: realtimeStale,
        realtimeListenable: store.realtimeStatus,
        realtimeNotice: realtimeNotice,
        viewerDisplayName: store.auth.viewer?.displayName,
        viewerEmail: store.auth.viewer?.email,
        viewerAvatarUrl: store.auth.viewer?.avatarUrl,
        viewerAvatarBytes: viewerAvatarBytes,
        expandedSpaceIds: expandedSpaceIds,
      );
  void _toggleSpaceExpanded(String spaceId) {
    final expanded = !expandedSpaceIds.contains(spaceId);
    setState(() {
      if (expanded) {
        expandedSpaceIds.add(spaceId);
      } else {
        expandedSpaceIds.remove(spaceId);
      }
    });
    _saveSpaceSidebarState(spaceId, {'sidebarExpanded': expanded});
  }

  /// Space sidebar state lives in Space settings; only the owner may write it,
  /// so other members keep the session-local expansion.
  void _saveSpaceSidebarState(String spaceId, Map<String, dynamic> settings) {
    final space =
        store.spaces.items.where((item) => item.id == spaceId).firstOrNull;
    if (space == null || space.role != 'owner') return;
    unawaited(store.collaboration
        .editSpace(space, settings: settings)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<void> _setSpacePinnedFromSidebar(AxSpace space, bool pinned) async {
    final source = store.dataSource;
    if (source is! AxPinDataSource) return;
    final before = store.spaces.items;
    final stamp = pinned ? DateTime.now().toUtc().toIso8601String() : '';
    final top = nextAxPinPosition([
      for (final s in before)
        if (s.isPinned) s.pinPosition
    ]);
    store.spaces.replace([
      for (final item in before)
        item.id == space.id
            ? item.copyWith(pinnedAt: stamp, pinPosition: pinned ? top : 0)
            : item
    ]);
    try {
      await (source as AxPinDataSource)
          .setPinned(kind: 'space', id: space.id, pinned: pinned);
    } catch (error) {
      store.spaces.replace(before);
      if (mounted) {
        _showSnackBar('Could not update the pin: $error',
            type: ToastType.error);
      }
    }
  }

  Future<void> _setSpacePinOrderFromSidebar(List<String> orderedIds) async {
    final source = store.dataSource;
    if (source is! AxPinDataSource) return;
    final before = store.spaces.items;
    final rank = {for (final e in orderedIds.asMap().entries) e.value: e.key};
    store.spaces.replace([
      for (final item in before)
        rank.containsKey(item.id)
            ? item.copyWith(pinPosition: rank[item.id])
            : item
    ]);
    try {
      await (source as AxPinDataSource)
          .setPinOrder(kind: 'space', ids: orderedIds);
    } catch (error) {
      store.spaces.replace(before);
      if (mounted) {
        _showSnackBar('Could not reorder pins: $error', type: ToastType.error);
      }
    }
  }

  Future<void> _setThreadPinOrderFromSidebar(
      AxSpace space, List<String> orderedIds) async {
    try {
      await store.spaceThreads.setPinOrder(space.id, orderedIds);
    } catch (error) {
      if (mounted) {
        _showSnackBar('Could not reorder pins: $error', type: ToastType.error);
      }
    }
  }

  Future<void> _setThreadPinnedFromSidebar(AxThread thread, bool pinned) async {
    try {
      await store.spaceThreads.setPinned(thread.spaceId, thread.id, pinned);
    } catch (error) {
      if (mounted) {
        _showSnackBar('Could not update the pin: $error',
            type: ToastType.error);
      }
    }
  }

  Future<void> _reorderThreadsFromSidebar(
      AxSpace space, List<String> orderedThreadIds) async {
    await store.collaboration
        .editSpace(space, settings: {'threadOrder': orderedThreadIds});
  }

  void _restoreSidebarExpansion() {
    var changed = false;
    for (final space in store.spaces.items) {
      if (!_sidebarRestoredSpaceIds.add(space.id)) continue;
      if (space.settings['sidebarExpanded'] == true &&
          expandedSpaceIds.add(space.id)) {
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  void _updateState(VoidCallback callback) => setState(callback);

  @override
  void initState() {
    super.initState();
    _themePreference = widget.themePreference ?? createThemePreference();
    _themeMode = _themePreference.load();
    _viewPreferencesStore =
        widget.viewPreferencesStore ?? createViewPreferencesStore();
    _viewPreferences = _viewPreferencesStore.load();
    store = AxStore(widget.dataSource);
    store.spaces.addListener(_restoreSidebarExpansion);
    store.invitations.addListener(_onInvitationsChanged);
    store.workspaceInvitations.addListener(_onInvitationsChanged);
    _searchQueryController.addListener(_onSearchQueryChanged);
    browserNavigation = widget.browserNavigation ?? createAxBrowserNavigation();
    final initialUri = widget.initialUri ?? browserNavigation.current;
    navigation = AxNavigation.fromUri(initialUri);
    // Expand deep links once; data refreshes must preserve manual collapse.
    if (navigation.kind == AxRouteKind.thread &&
        (navigation.spaceId != null || navigation.spaceId != null)) {
      expandedSpaceIds.add(navigation.spaceId!);
    }
    _desktopAuthIntentId = _intentIdFromNavigation(navigation);
    if (!_isCanonicalWorkspaceUri(initialUri, navigation.toUri())) {
      browserNavigation.replace(navigation.toUri());
    }
    navigationSubscription =
        browserNavigation.changes.listen(_onBrowserNavigation);
    realtimeClient = widget.realtimeClient ?? createRealtimeClient();
    realtimeSubscription = realtimeClient.events.listen(_onRealtimeEvent);
    store.viewedThreadActivity = _viewedThreadActivity;
    lifecycleSubscription = browserNavigation.lifecycleChanges.listen((_) {
      unawaited(() async {
        await _syncSession();
        if (mounted && store.auth.session?.authenticated == true) {
          _scheduleMarkViewedRead();
          await store.lifecycle.resume();
        }
      }());
    });
    final connectivity = browserNavigation;
    if (connectivity is AxBrowserConnectivity) {
      final network = connectivity as AxBrowserConnectivity;
      unawaited(store.lifecycle
          .connectivityChanged(network.online, revalidate: false));
      connectivitySubscription = network.connectivityChanges.listen((online) {
        unawaited(store.lifecycle.connectivityChanged(online,
            revalidate: store.auth.session?.authenticated == true));
      });
    }
    _cancelWorkRealtime = store.workRealtime.listen(realtimeClient.events);
    if (_desktopAuthIntentId != null) {
      unawaited(_pollDesktopAuthStatus());
      _desktopAuthStatusTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_pollDesktopAuthStatus()),
      );
    }
    unawaited(_loadSession());
  }

  @override
  void dispose() {
    _mobileSpacesScroll.dispose();
    _readTimer?.cancel();
    _desktopAuthStatusTimer?.cancel();
    store.spaces.removeListener(_restoreSidebarExpansion);
    store.invitations.removeListener(_onInvitationsChanged);
    store.workspaceInvitations.removeListener(_onInvitationsChanged);
    _searchQueryController.removeListener(_onSearchQueryChanged);
    _searchQueryController.dispose();
    _searchFocusNode.dispose();
    authNameController.dispose();
    authEmailController.dispose();
    authPasswordController.dispose();
    authConfirmPasswordController.dispose();
    authVerificationCodeController.dispose();
    promptResponseController.dispose();
    unawaited(navigationSubscription?.cancel());
    unawaited(lifecycleSubscription?.cancel());
    unawaited(connectivitySubscription?.cancel());
    _cancelWorkRealtime?.call();
    store.dispose();
    store.workRealtime.dispose();
    unawaited(realtimeSubscription?.cancel());
    unawaited(realtimeClient.close());
    browserNavigation.dispose();
    super.dispose();
  }

  String? _intentIdFromNavigation(AxNavigation value) {
    if (value.desktopAuthIntentId != null) return value.desktopAuthIntentId;
    if (value.loginReturnTo == null) return null;
    final returnTo = Uri.tryParse(value.loginReturnTo!);
    if (returnTo == null) return null;
    return AxNavigation.fromUri(returnTo).desktopAuthIntentId;
  }

  @override
  Widget build(BuildContext context) {
    AxRenderDiagnostics.instance.widgetRebuild(
      component: 'SyntilaAppShell',
      threadId: navigation.threadId,
      tab: navigation.kind.name,
    );
    return _buildApp(context);
  }

  Future<void> _createSpace() async {
    var name = '';
    var description = '';
    final values = await showDialog<(String, String?)>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) {
        void submit() {
          Navigator.pop(
            dialogContext,
            (
              name.isEmpty ? 'My first space' : name,
              description.trim().isEmpty ? null : description.trim(),
            ),
          );
        }

        return AlertDialog(
          title: const Text('Create Space'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  onChanged: (value) => name = value,
                  onSubmitted: (_) => submit(),
                  decoration: const InputDecoration(labelText: 'Space name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  onChanged: (value) => description = value,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: submit,
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    if (values == null) return;
    try {
      final space = await store.collaboration
          .createSpace(name: values.$1, description: values.$2);
      if (!mounted) return;
      _navigateTo(AxNavigation.space(space.id), replace: true);
      _showSnackBar('Space created. Create a Thread to get started.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _createThread([AxSpace? targetSpace]) async {
    final space = targetSpace ?? selectedSpace;
    if (space == null) return;
    final created = await showCreateThreadDialog(
      navigatorKey.currentContext ?? context,
    );
    if (created == null || created.isEmpty) return;
    try {
      final thread = await store.collaboration
          .createThread(spaceId: space.id, name: created);
      if (!mounted) return;
      setState(() => expandedSpaceIds.add(space.id));
      _navigateTo(AxNavigation.thread(space.id, thread.id));
      _showSnackBar('Thread created.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _renameThreadFromSidebar(AxThread thread, String name) async {
    try {
      await store.collaboration.editThread(thread, name: name);
      if (mounted) _showSnackBar('Thread renamed.');
    } catch (error) {
      if (mounted) {
        _showSnackBar('Failed to rename thread: $error', type: ToastType.error);
      }
    }
  }

  Future<void> _setThreadArchivedFromSidebar(
      AxThread thread, bool archived) async {
    try {
      await store.collaboration.editThread(
        thread,
        status: archived ? 'archived' : 'active',
      );
      if (mounted) {
        _showSnackBar(archived ? 'Thread archived.' : 'Thread restored.');
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar(
          'Failed to ${archived ? 'archive' : 'restore'} thread: $error',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _clearChatHistory(AxThread thread) async {
    try {
      // Cloud deletes Chat and every Work Request together.
      await store.discussion.clearHistory(thread.id);
      store.workHistory.resetHistory(thread.id);
      _discardNotificationsFor(threadId: thread.id);
      if (mounted) _showSnackBar('Conversation and AI History cleared.');
    } catch (error) {
      if (mounted) {
        _showSnackBar(
          'Failed to clear Conversation history: $error',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _clearWorkHistory(AxThread thread) async {
    try {
      // Only AI History is cut off; the Conversation stays as it was.
      await store.workHistory.clearHistory(thread.id);
      await store.discussion.synchronize(thread.id);
      _discardNotificationsFor(threadId: thread.id);
      if (mounted) _showSnackBar('AI History cleared.');
    } catch (error) {
      if (mounted) {
        _showSnackBar(
          'Failed to clear AI History: $error',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _deleteThreadFromSidebar(AxThread thread) async {
    try {
      await store.collaboration.deleteThread(thread);
      _discardNotificationsFor(threadId: thread.id);
      if (!mounted) return;
      _showSnackBar('Thread deleted.');
      if (navigation.threadId == thread.id) {
        _navigateTo(AxNavigation.space(thread.spaceId));
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar('Failed to delete thread: $error', type: ToastType.error);
      }
    }
  }

  /// Sidebar "Edit Space": edits the name and description in a dialog,
  /// without navigating. Errors stay in the dialog so nothing typed is lost.
  Future<void> _editSpace(AxSpace space) async {
    final nameController = TextEditingController(text: space.name);
    final descriptionController =
        TextEditingController(text: space.description);
    String? errorText;
    var saving = false;
    // The controllers are left to the garbage collector: disposing them right
    // after the dialog closes would break its closing animation.
    await showDialog<void>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> submit() async {
            if (saving) return;
            final name = nameController.text.trim();
            if (name.isEmpty) {
              setDialogState(() => errorText = 'Space name cannot be empty.');
              return;
            }
            setDialogState(() {
              saving = true;
              errorText = null;
            });
            final error = await _saveSpaceEdits(
                space, name, descriptionController.text.trim());
            if (!dialogContext.mounted) return;
            if (error == null) {
              Navigator.pop(dialogContext);
              return;
            }
            setDialogState(() {
              saving = false;
              errorText = error;
            });
          }

          return AlertDialog(
            key: const ValueKey('space-edit-dialog'),
            title: const Text('Edit Space'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      enabled: !saving,
                      onChanged: (_) {
                        if (errorText != null) {
                          setDialogState(() => errorText = null);
                        }
                      },
                      onSubmitted: (_) => submit(),
                      decoration: InputDecoration(
                        labelText: 'Space Name',
                        errorText: errorText,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descriptionController,
                      enabled: !saving,
                      decoration:
                          const InputDecoration(labelText: 'Description'),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: saving ? null : submit,
                child: Text(saving ? 'Saving…' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Saves an inline Space edit; returns an error for the form or null.
  Future<String?> _saveSpaceEdits(
      AxSpace space, String name, String description) async {
    final taken = store.spaces.items.any((other) =>
        other.id != space.id &&
        other.role == 'owner' &&
        other.name.trim().toLowerCase() == name.toLowerCase());
    if (taken) return 'You already have a Space with this name.';
    final current =
        store.spaces.items.where((item) => item.id == space.id).firstOrNull ??
            space;
    if (name != space.name && current.hasActiveWork) {
      final proceed = await _confirmSpaceAction(
        title: 'Rename Space while Work is running?',
        message: 'A Thread in this Space is running. Its folder is renamed '
            'on the next request, which can interrupt Work that is using it. '
            'Rename now, or wait until the Work finishes.',
        action: 'Rename',
      );
      if (!proceed) return 'Rename cancelled.';
    }
    try {
      await store.collaboration.editSpace(
        space,
        name: name,
        description: description,
        // Instructions are no longer part of the Space UI; preserve any
        // legacy value until a dedicated data migration removes it.
        instructions: space.instructions,
      );
      if (mounted) _showSnackBar('Space updated.');
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<void> _archiveSpace(AxSpace space) async {
    final confirmed = await _confirmSpaceAction(
      title: 'Archive Space?',
      message: 'Archived spaces leave the active Spaces list.',
      action: 'Archive',
    );
    if (!confirmed) return;
    try {
      await widget.dataSource.archiveSpace(spaceId: space.id);
      unawaited(store.archivedSpaces
          .refresh()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      store.syncEngine.remove(store.spaceDetails.query(space.id).key);
      store.spaceThreads.engine.remove(store.spaceThreads.query(space.id).key);
      expandedSpaceIds.remove(space.id);
      if (!mounted) return;
      store.spaces.replace(
          store.spaces.items.where((item) => item.id != space.id).toList());
      selectedSpaceId = null;
      _navigateTo(const AxNavigation.home(), replace: true);
      _showSnackBar('Space archived.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _deleteSpace(String spaceId) async {
    final confirmed = await _confirmSpaceAction(
      title: 'Delete Space?',
      message: 'This permanently removes the Space and its Threads.',
      action: 'Delete',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await widget.dataSource.deleteSpace(spaceId: spaceId);
      _discardNotificationsFor(spaceId: spaceId);
      unawaited(store.archivedSpaces
          .refresh()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      store.syncEngine.remove(store.spaceDetails.query(spaceId).key);
      store.spaceThreads.engine.remove(store.spaceThreads.query(spaceId).key);
      expandedSpaceIds.remove(spaceId);
      if (!mounted) return;
      store.spaces.replace(
          store.spaces.items.where((item) => item.id != spaceId).toList());
      selectedSpaceId = null;
      _navigateTo(const AxNavigation.home(), replace: true);
      _showSnackBar('Space deleted.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<bool> _confirmSpaceAction({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        constraints: SyntilaDialogStyle.small,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive ? SyntilaDialogStyle.destructiveButton() : null,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result == true;
  }
}

class _AxAppState extends State<SyntilaAppShell> with _AxAppStateMixin {}
