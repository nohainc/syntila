import 'sync/ax_people.dart';
import 'sync/ax_archived_spaces.dart';
import 'sync/ax_workflow_configurations.dart';
import 'sync/ax_mcp_inventories.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'sync/persistence/ax_persistent_read_cache.dart';
import 'sync/persistence/ax_thread_view_state_store.dart';
import '../notifications/notification_models.dart';
import 'ax_data.dart';
import 'ax_models.dart';
import 'sync/ax_space_threads.dart';
import 'sync/ax_space_details.dart';
import 'sync/ax_sync_engine.dart';
import 'sync/ax_discussion_cache.dart';
import 'sync/ax_work_history.dart';
import 'sync/ax_work_realtime_sync.dart';
import 'sync/ax_realtime_cache_router.dart';
import 'sync/ax_session_catalogs.dart';
import 'sync/ax_space_tab_queries.dart';
import 'sync/ax_owned_workspaces.dart';
import 'sync/ax_collaboration_mutations.dart';
import 'sync/ax_lifecycle_sync.dart';

/// Coalesces synchronous store changes until the current build stack has
/// unwound. This prevents a nested cache/query notification from marking a
/// ListenableBuilder dirty while Flutter is still rebuilding it.
class AxCoalescedListenable extends ChangeNotifier {
  AxCoalescedListenable(Iterable<Listenable> sources)
      : _sources = List<Listenable>.unmodifiable(sources) {
    for (final source in _sources) {
      source.addListener(_sourceChanged);
    }
  }

  final List<Listenable> _sources;
  bool _notificationScheduled = false;
  bool _disposed = false;

  void _sourceChanged() {
    if (_disposed || _notificationScheduled) return;
    _notificationScheduled = true;
    if (_isMidFrame) {
      _deferToPostFrame();
    } else {
      scheduleMicrotask(_deliverFromMicrotask);
    }
  }

  // The frame state is checked again when the microtask runs. It can change
  // between scheduling and delivery, for example when a frame starts first.
  void _deliverFromMicrotask() {
    if (_isMidFrame) {
      _deferToPostFrame();
      return;
    }
    _deliver();
  }

  void _deferToPostFrame() {
    // Do not explicitly request a frame here. On Flutter Web, a route or
    // browser view can be torn down between this notification and the next
    // scheduler turn; scheduleFrame() would then try to render the disposed
    // EngineFlutterView. The event-loop turn still gets us out of the current
    // build/frame stack, and any mounted listener can request its own frame.
    Timer.run(_deliverFromPostFrame);
  }

  void _deliver() {
    if (_isMidFrame) {
      _deferToPostFrame();
      return;
    }
    _notificationScheduled = false;
    if (!_disposed) notifyListeners();
  }

  // This callback is registered by _deferToPostFrame, so Flutter has already
  // completed the frame's build and layout work before listeners are notified.
  void _deliverFromPostFrame() {
    _notificationScheduled = false;
    if (!_disposed) notifyListeners();
  }

  // Build and layout (including LayoutBuilder callbacks that mount subtrees)
  // are unsafe for notifying listeners. Post-frame callbacks are safe because
  // the frame's build and layout have already finished.
  bool get _isMidFrame {
    final phase = SchedulerBinding.instance.schedulerPhase;
    final building = WidgetsBinding.instance.buildOwner?.debugBuilding ?? false;
    return building || phase != SchedulerPhase.idle;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final source in _sources) {
      source.removeListener(_sourceChanged);
    }
    super.dispose();
  }
}

/// Listens to a view signal without allowing a synchronous notification to
/// mark the current widget dirty while it is being mounted or rebuilt.
class AxDeferredListenableBuilder extends StatefulWidget {
  const AxDeferredListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
    this.child,
  });

  final Listenable listenable;
  final Widget Function(BuildContext context, Widget? child) builder;
  final Widget? child;

  @override
  State<AxDeferredListenableBuilder> createState() =>
      _AxDeferredListenableBuilderState();
}

class _AxDeferredListenableBuilderState
    extends State<AxDeferredListenableBuilder> {
  bool _rebuildScheduled = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _attachAfterFirstFrame();
  }

  void _attachAfterFirstFrame() {
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      Timer.run(() {
        if (!mounted || _listening) return;
        widget.listenable.addListener(_scheduleRebuild);
        _listening = true;
        setState(() {});
      });
    });
  }

  @override
  void didUpdateWidget(covariant AxDeferredListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_listening && oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_scheduleRebuild);
      widget.listenable.addListener(_scheduleRebuild);
    }
  }

  void _scheduleRebuild() {
    if (!mounted || _rebuildScheduled) return;
    _rebuildScheduled = true;
    final binding = WidgetsBinding.instance;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      _rebuildScheduled = false;
      setState(() {});
      return;
    }
    binding.addPostFrameCallback((_) {
      // Flutter Web can begin the next layout pass before a post-frame
      // callback has fully unwound. Cross one event-loop turn before marking
      // this element dirty so refresh/startup ordering cannot re-enter build.
      Timer.run(() {
        _rebuildScheduled = false;
        if (mounted) setState(() {});
      });
    });
  }

  @override
  void dispose() {
    if (_listening) widget.listenable.removeListener(_scheduleRebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}

/// Focused Cloud-backed stores. The API remains the source of truth.
/// A newer refresh or a cleared session replaced this Workspace recovery's
/// results. It is an expected outcome, not a failure to report to the user.
class AxRecoverySupersededException implements Exception {
  const AxRecoverySupersededException();
  @override
  String toString() => 'Workspace recovery superseded';
}

class AxStore {
  AxStore(this.dataSource,
      {AxReadCacheBackend? readCacheBackend,
      bool persistReadCache = const bool.fromEnvironment(
          'AX_PERSIST_READ_CACHE',
          defaultValue: true)})
      : _readCacheBackend = readCacheBackend,
        _persistReadCache = persistReadCache,
        auth = AuthStore(dataSource),
        runs = RunStore(dataSource) {
    invitations.addListener(_updateUnreadNotifications);
    workspaceInvitations.addListener(_updateUnreadNotifications);
  }

  /// Workspace invitations addressed to the signed-in person, surfaced in the
  /// Inbox like Space invitations.
  final ValueNotifier<List<AxMyWorkspaceInvitation>> workspaceInvitations =
      ValueNotifier(const []);

  /// Bumped when a Workspace invitation the viewer sent or received changes,
  /// so open sharing views reload without a page refresh.
  final ValueNotifier<int> workspaceInvitationRevision = ValueNotifier(0);

  Future<void>? _workspaceInvitationsFlight;

  /// Concurrent callers (bootstrap, realtime catch-up) share one request.
  Future<void> refreshWorkspaceInvitations() =>
      _workspaceInvitationsFlight ??= _loadWorkspaceInvitations()
          .whenComplete(() => _workspaceInvitationsFlight = null);

  Future<void> _loadWorkspaceInvitations() async {
    final AxDataSource raw = dataSource;
    if (raw is! AxWorkspaceSharingDataSource) return;
    final source = raw as AxWorkspaceSharingDataSource;
    try {
      workspaceInvitations.value = await source.loadMyWorkspaceInvitations();
    } catch (_) {
      // Optional; a failed check simply shows nothing.
    }
  }

  Future<void> declineWorkspaceInvitation(
      AxMyWorkspaceInvitation invite) async {
    final AxDataSource raw = dataSource;
    if (raw is! AxWorkspaceSharingDataSource) return;
    final source = raw as AxWorkspaceSharingDataSource;
    await source.declineWorkspaceInvitation(invite.id);
    await refreshWorkspaceInvitations();
  }

  Future<void> acceptWorkspaceInvitation(AxMyWorkspaceInvitation invite) async {
    final AxDataSource raw = dataSource;
    if (raw is! AxWorkspaceSharingDataSource) return;
    final source = raw as AxWorkspaceSharingDataSource;
    await source.acceptWorkspaceInvitation(invite.id);
    await refreshWorkspaceInvitations();
  }

  final AxReadCacheBackend? _readCacheBackend;
  final bool _persistReadCache;
  late final persistence = AxPersistentReadCache(syncEngine, dataSource,
      backend: _readCacheBackend, enabled: _persistReadCache);
  late final threadViewState = createAxThreadViewStateStore();
  Future<bool> hydrateReadCache() async {
    final session = auth.session;
    final id = session?.viewer?.id;
    if (session?.authenticated != true ||
        id == null ||
        id.isEmpty ||
        id == '—') {
      return false;
    }
    if (persistence.userId != null && persistence.userId != id) {
      clearServerState();
    }
    return persistence.hydrate(id);
  }

  Future<void> logout() async {
    final userId = auth.session?.viewer?.id;
    final clearing = persistence.clearUser();
    final clearingThreadView = userId == null
        ? Future<void>.value()
        : threadViewState.clearUser(userId);
    clearServerState();
    try {
      await auth.logout();
    } finally {
      await clearing;
      await clearingThreadView;
    }
  }

  Future<void> markAccountDeleted() async {
    final userId = auth.session?.viewer?.id;
    final clearing = persistence.clearUser();
    final clearingThreadView = userId == null
        ? Future<void>.value()
        : threadViewState.clearUser(userId);
    clearServerState();
    auth.markUnauthenticated();
    await clearing;
    await clearingThreadView;
  }

  int _sessionGeneration = 0;
  bool _disposed = false;
  AxSnapshot _execution = AxSnapshot.empty();
  final executionChanges = AxViewSignal();
  late final homeChanges = AxCoalescedListenable([
    spaces,
    workspaces,
    executionChanges,
    invitations,
    unreadNotifications,
    productUpdateReadStates,
    productUpdatesNotifier,
  ]);
  late final topBarChanges = AxCoalescedListenable([
    workspaces,
    executionChanges,
    realtimeStatus,
  ]);
  late final profileSecurityChanges = AxCoalescedListenable([
    security,
    securityLoading,
    securityError,
  ]);
  final lifecycleNotice = ValueNotifier<String?>(null);
  late final lifecycle = AxLifecycleSync(syncEngine,
      onNotice: (notice) => lifecycleNotice.value = notice);
  final realtimeStatus = ValueNotifier<(bool, String?)>((false, null));
  final notifications = <AxNotification>[];
  final unreadNotifications = ValueNotifier<int>(0);
  final security = ValueNotifier<AxAccountSecurity?>(null);
  final pendingRunPrompt = ValueNotifier<String?>(null);
  final securityError = ValueNotifier<String?>(null);
  final securityLoading = ValueNotifier<bool>(false);
  final productUpdatesNotifier = ValueNotifier<List<AxProductUpdate>>([]);
  List<AxProductUpdate> get productUpdates => productUpdatesNotifier.value;
  set productUpdates(List<AxProductUpdate> updates) {
    productUpdatesNotifier.value = updates;
  }

  void addProductUpdate(AxProductUpdate update) {
    if (productUpdates.any((u) => u.id == update.id)) return;
    productUpdatesNotifier.value = [update, ...productUpdatesNotifier.value];
  }

  final productUpdateReadStates =
      ValueNotifier<Map<String, AxUserProductUpdateState>>({});

  void markProductUpdatesSeen(List<String> updateIds) {
    final current = Map<String, AxUserProductUpdateState>.from(
        productUpdateReadStates.value);
    final now = DateTime.now();
    final userId = auth.session?.viewer?.id ?? 'viewer';
    var changed = false;
    for (final id in updateIds) {
      final existing = current[id];
      if (existing == null) {
        current[id] = AxUserProductUpdateState(
          userId: userId,
          updateId: id,
          seenAt: now,
        );
        changed = true;
      } else if (existing.seenAt == null) {
        current[id] = existing.copyWith(seenAt: now);
        changed = true;
      }
    }
    if (changed) {
      productUpdateReadStates.value = current;
    }
  }

  void markProductUpdateOpened(String updateId) {
    final current = Map<String, AxUserProductUpdateState>.from(
        productUpdateReadStates.value);
    final now = DateTime.now();
    final userId = auth.session?.viewer?.id ?? 'viewer';
    final existing = current[updateId];
    if (existing == null) {
      current[updateId] = AxUserProductUpdateState(
        userId: userId,
        updateId: updateId,
        seenAt: now,
        openedAt: now,
      );
    } else {
      current[updateId] = existing.copyWith(
        seenAt: existing.seenAt ?? now,
        openedAt: now,
      );
    }
    productUpdateReadStates.value = current;
  }

  void dismissProductUpdate(String updateId) {
    final current = Map<String, AxUserProductUpdateState>.from(
        productUpdateReadStates.value);
    final now = DateTime.now();
    final userId = auth.session?.viewer?.id ?? 'viewer';
    final existing = current[updateId];
    if (existing == null) {
      current[updateId] = AxUserProductUpdateState(
        userId: userId,
        updateId: updateId,
        seenAt: now,
        dismissedAt: now,
      );
    } else {
      current[updateId] = existing.copyWith(
        seenAt: existing.seenAt ?? now,
        dismissedAt: now,
      );
    }
    productUpdateReadStates.value = current;
  }

  /// Legacy execution-only projection. Collaboration state belongs to queries.
  AxSnapshot get execution => _execution;
  void replaceExecution(AxSnapshot value) {
    runs.replace(value.run);
    final previous = _execution;
    _execution = AxSnapshot(
      workspaceId: value.workspaceId,
      activeRunId: value.activeRunId,
      run: value.run,
      spaces: const [],
      tasks: List.unmodifiable(value.tasks),
      findings: List.unmodifiable(value.findings),
      events: List.unmodifiable(value.events),
      artifacts: List.unmodifiable(value.artifacts),
      candidateOutputs: List.unmodifiable(value.candidateOutputs),
      synthesisDecision: value.synthesisDecision,
    );
    if (previous.run != value.run ||
        previous.workspaceId != value.workspaceId ||
        previous.activeRunId != value.activeRunId ||
        !listEquals(previous.tasks, value.tasks) ||
        !listEquals(previous.findings, value.findings) ||
        !listEquals(previous.events, value.events) ||
        !listEquals(previous.artifacts, value.artifacts) ||
        !listEquals(previous.candidateOutputs, value.candidateOutputs) ||
        previous.synthesisDecision != value.synthesisDecision) {
      executionChanges.bump();
    }
  }

  void _updateUnreadNotifications() {
    unreadNotifications.value = notifications.where((n) => !n.read).length +
        invitations.items.length +
        workspaceInvitations.value.length;
  }

  Future<void> acceptInvitation(AxSpaceInvitation invite) =>
      collaboration.acceptInvitation(invite);

  Future<void> declineInvitation(AxSpaceInvitation invite) =>
      collaboration.declineInvitation(invite);

  void dispose() {
    homeChanges.dispose();
    topBarChanges.dispose();
    profileSecurityChanges.dispose();
    invitations.removeListener(_updateUnreadNotifications);
    workspaceInvitations.removeListener(_updateUnreadNotifications);
    workspaceInvitations.dispose();
    workspaceInvitationRevision.dispose();
    invitations.dispose();
    lifecycle.dispose();
    lifecycleNotice.dispose();
    persistence.dispose();
    threadViewState.dispose();
    workflowConfigurations.clear();
    people.clear();
    archivedSpaces.clear();
    mcpInventories.clear();
    _disposed = true;
    _sessionGeneration++;
    spaces.dispose();
    workspaces.dispose();
    executionChanges.dispose();
    realtimeStatus.dispose();
    unreadNotifications.dispose();
    security.dispose();
    securityLoading.dispose();
    securityError.dispose();
    pendingRunPrompt.dispose();
    productUpdatesNotifier.dispose();
    productUpdateReadStates.dispose();
  }

  final AxDataSource dataSource;
  final AxSyncEngine syncEngine = AxSyncEngine();
  late final UserInvitationsStore invitations =
      UserInvitationsStore(dataSource, engine: syncEngine);
  late final people = AxPeople(dataSource, engine: syncEngine);
  late final archivedSpaces = AxArchivedSpaces(dataSource, engine: syncEngine);
  late final workflowConfigurations =
      AxWorkflowConfigurations(dataSource, engine: syncEngine);
  late final AxMcpInventories mcpInventories =
      AxMcpInventories(dataSource, engine: syncEngine);
  late final AxSessionCatalogs catalogs =
      AxSessionCatalogs(dataSource, engine: syncEngine);
  late final AxSpaceTabQueries spaceTabs =
      AxSpaceTabQueries(dataSource, engine: syncEngine);
  late final AxSpaceThreads spaceThreads =
      AxSpaceThreads(dataSource, engine: syncEngine);
  late final AxSpaceDetails spaceDetails =
      AxSpaceDetails(dataSource, engine: syncEngine);
  late final AxDiscussionCache discussion =
      AxDiscussionCache(dataSource, engine: syncEngine);

  late final AxWorkHistoryCache workHistory =
      AxWorkHistoryCache(dataSource, engine: syncEngine);

  late final AxWorkRealtimeSync workRealtime =
      AxWorkRealtimeSync.forCache(workHistory);

  /// Set by the shell: true when the Thread is open in a visible tab, in
  /// which case the shell marks it read and no indicator refresh is needed.
  bool Function(String threadId) viewedThreadActivity = (_) => false;

  late final realtimeCacheRouter = AxRealtimeCacheRouter(syncEngine,
      viewedThreadActivity: (id) => viewedThreadActivity(id),
      discussionChanged: discussion.reconcileSignal,
      discussionObserved: discussion.isObserved,
      discussionResynchronize: (id) async {
        await discussion.synchronize(id, reconcileNewest: false);
      },
      discussionFullResynchronize: (id) async {
        await discussion.synchronize(id,
            reconcileNewest: true, reconcileAll: true);
      });

  /// Existing HTTP APIs expose user-wide lists. Merge only the affected
  /// Workspace into retained state; no bootstrap or route selection is involved.
  Future<({AxWorkspace? workspace, List<AxWorker> workers})>
      resynchronizeWorkspace(String id) async {
    final stateQuery = AxQuery<AxWorkspace?>(
        key: AxQueryKey(['execution_workspace', id, 'state']),
        load: () async {
          final values = await dataSource.loadWorkspaces();
          for (final value in values) {
            if (value.id == id) return value;
          }
          return null;
        });
    final results = await Future.wait<Object?>([
      syncEngine.refresh<AxWorkspace?>(stateQuery),
      catalogs.refreshWorkers(),
    ]);
    final workspace = results[0] as AxWorkspace?;
    final workers = results[1] as List<AxWorker>;
    // Cleared/superseded recovery cannot update the legacy view projection.
    if (_disposed ||
        !syncEngine.peek(stateQuery).hasData ||
        !identical(syncEngine.peek(stateQuery).data, workspace) ||
        !identical(syncEngine.peek(catalogs.workers).data, workers)) {
      throw const AxRecoverySupersededException();
    }
    workspaces.replace([
      for (final item in workspaces.items)
        if (item.id != id) item,
      if (workspace != null) workspace,
    ]);
    return (
      workspace: workspace,
      workers: workers.where((worker) => worker.workspaceId == id).toList()
    );
  }

  void clearServerState() {
    final source = dataSource;
    if (source is AxConditionalReadCache) {
      (source as AxConditionalReadCache).clearConditionalReads();
    }
    lifecycle.reset();
    workflowConfigurations.clear();
    people.clear();
    archivedSpaces.clear();
    mcpInventories.clear();
    unawaited(persistence.clearUser());
    _sessionGeneration++;
    spaces.clear();
    workspaces.clear();
    security.value = null;
    securityError.value = null;
    pendingRunPrompt.value = null;
    realtimeStatus.value = (false, null);
    securityLoading.value = false;
    notifications.clear();
    unreadNotifications.value = 0;
    realtimeCacheRouter.reset();
    workRealtime.reset();
    collaboration.clear();
    workHistory.clear();
    discussion.clear();
    syncEngine.clear();
    replaceExecution(AxSnapshot.empty());
  }

  final AuthStore auth;
  late final WorkspaceStore workspaces =
      WorkspaceStore(dataSource, engine: syncEngine);
  late final SpaceStore spaces = SpaceStore(dataSource, engine: syncEngine);
  late final collaboration =
      AxCollaborationMutations(dataSource, engine: syncEngine);
  final RunStore runs;

  /// Bootstrap/recovery only; navigation uses focused queries.
  Future<AxSnapshot> loadBootstrapState(
      {String? spaceId, String? workspaceId}) async {
    final generation = _sessionGeneration;
    final loaded = await dataSource.loadBootstrapState(
        spaceId: spaceId, workspaceId: workspaceId);
    if (_disposed || generation != _sessionGeneration) {
      throw StateError('Bootstrap superseded');
    }
    final snapshot = loaded.copyWith(
        spaces: loaded.spaces
            .map((space) => space.copyWith(threads: const []))
            .toList());
    spaces.replace(snapshot.spaces);
    workspaces.replace(snapshot.workspaces);
    auth.replace(snapshot.viewer);
    replaceExecution(snapshot);
    return snapshot;
  }
}

class SpaceStore extends ValueNotifier<List<AxSpace>> {
  SpaceStore(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine(),
        super(const []) {
    _cancel = this.engine.watch(
        query, (state) => value = state.data ?? const [],
        fireImmediately: true);
  }
  final AxDataSource source;
  final AxSyncEngine engine;
  late final void Function() _cancel;
  late final query = AxQuery<List<AxSpace>>(
      key: AxQueryKey(['spaces']),
      load: () async => List.unmodifiable(sortAxSpacesByLastUpdate(
          (await source.loadSpaces())
              .map((s) => s.copyWith(threads: const [])))));
  List<AxSpace> get items => value;
  void clear() => engine.remove(query.key);
  @override
  void dispose() {
    _cancel();
    engine.remove(query.key);
    super.dispose();
  }

  void replace(List<AxSpace> items) {
    if (listEquals(value, items)) return;
    engine.update(
        query,
        (_) =>
            List.unmodifiable(items.map((s) => s.copyWith(threads: const []))));
  }

  Future<List<AxSpace>> refresh() => engine.refresh(query, supersede: true);
}

class WorkspaceStore extends ValueNotifier<List<AxWorkspace>> {
  WorkspaceStore(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine(),
        super(const []) {
    _cancel = this.engine.watch(
        query, (state) => value = state.data ?? const [],
        fireImmediately: true);
  }
  final AxSyncEngine engine;
  late final void Function() _cancel;
  late final query = ownedWorkspacesQuery(source);
  final AxDataSource source;
  int _generation = 0;
  bool _disposed = false;
  void clear() {
    _generation++;
    _listFlight = null;
    engine.remove(query.key);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancel();
    engine.remove(query.key);
    super.dispose();
  }

  List<AxWorkspace> get items => value;

  void replace(List<AxWorkspace> items) {
    if (!listEquals(value, items)) {
      engine.update(query, (_) => List.unmodifiable(items));
    }
  }

  Future<List<AxWorkspace>>? _listFlight;

  /// Concurrent callers share one in-flight request.
  Future<List<AxWorkspace>> list() =>
      _listFlight ??= _list().whenComplete(() => _listFlight = null);

  Future<List<AxWorkspace>> _list() async {
    final generation = ++_generation;
    final value = await source.loadWorkspaces();
    if (!_disposed && generation == _generation) replace(value);
    return value;
  }

  Future<void> revoke(String workspaceId) =>
      source.revokeWorkspace(workspaceId: workspaceId);

  Future<void> setParallelSlots(String workspaceId, int slots) async {
    await source.setWorkspaceParallelSlots(
        workspaceId: workspaceId, slots: slots);
    replace(items
        .map((workspace) => workspace.id == workspaceId
            ? workspace.copyWith(parallelSlots: slots)
            : workspace)
        .toList());
  }

  Future<void> update(String workspaceId, String name) async {
    final updated =
        await source.updateWorkspace(workspaceId: workspaceId, name: name);
    replace(items
        .map((workspace) => workspace.id == workspaceId ? updated : workspace)
        .toList());
  }
}

class RunStore {
  RunStore(this.source);
  final AxDataSource source;
  AxRun? current;

  void replace(AxRun? value) => current = value;

  Future<void> control(String runId, String command) =>
      source.controlRun(runId, command);
}

class AuthStore {
  AuthStore(this.source);

  final AxDataSource source;
  AxSession? session;
  AxViewer? viewer;
  int _generation = 0;
  bool _loggingOut = false;

  void replace(AxViewer? value) {
    if (value != null) viewer = value;
  }

  Future<AxSession> load() async {
    if (_loggingOut) throw StateError('Logout in progress');
    final generation = ++_generation;
    final value = await source.loadSession();
    if (generation != _generation) {
      throw StateError('Authentication load superseded');
    }
    session = value;
    viewer = value.viewer;
    return value;
  }

  Future<void> logout() async {
    _generation++;
    _loggingOut = true;
    try {
      await source.logout();
      session = const AxSession(authenticated: false);
      viewer = null;
    } finally {
      _generation++;
      _loggingOut = false;
    }
  }

  void markUnauthenticated() {
    _generation++;
    session = const AxSession(authenticated: false);
    viewer = null;
  }
}

/// Explicit notification boundary for retained execution projections.
class AxViewSignal extends ChangeNotifier {
  void bump() => notifyListeners();
}

class UserInvitationsStore extends ValueNotifier<List<AxSpaceInvitation>> {
  UserInvitationsStore(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine(),
        super(const []) {
    _cancel = this.engine.watch(
        query, (state) => value = state.data ?? const [],
        fireImmediately: true);
  }
  final AxDataSource source;
  final AxSyncEngine engine;
  late final void Function() _cancel;
  late final query = AxQuery<List<AxSpaceInvitation>>(
      key: AxQueryKey(['me', 'invitations']),
      load: source.loadCurrentUserInvitations);

  List<AxSpaceInvitation> get items => value;
  void clear() => engine.remove(query.key);

  @override
  void dispose() {
    _cancel();
    engine.remove(query.key);
    super.dispose();
  }

  void replace(List<AxSpaceInvitation> items) {
    if (listEquals(value, items)) return;
    engine.update(query, (_) => List.unmodifiable(items));
  }

  Future<List<AxSpaceInvitation>> refresh() =>
      engine.refresh(query, supersede: true);
}
