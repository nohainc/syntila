part of '../spaces_pages.dart';

class ThreadPage extends StatefulWidget {
  /// Clears the session-wide Work queues so tests start independent.
  @visibleForTesting
  static void resetWorkQueues() {
    _ThreadPageState._queuedWorkByThread.clear();
    _ThreadPageState._workQueuePauses.clear();
    _BackgroundWorkQueue.reset();
  }

  const ThreadPage({
    super.key,
    required this.space,
    required this.thread,
    this.dataSource,
    this.discussionCache,
    this.workHistoryCache,
    this.threadViewStateStore,
    this.catalogs,
    this.workflowConfigurations,
    this.currentUserId,
    this.currentUserName,
    this.viewerEmail,
    required this.onBackToSpace,
    required this.onArchive,
    this.onRename,
    this.onRestore,
    this.onViewStateChanged,
    this.onRunWork,
    this.onRunWorkWithSelection,
    this.realtimeEvents,
    this.initialTab = 0,
    this.initialAiHistoryOpen = false,
    this.showAiHistory = true,
    this.onClearConversation,
    this.onClearAiHistory,
    this.isDraft = false,
    this.draftBusy = false,
    this.onSendDraftDiscussion,
  }) : assert(!isDraft ||
            (onSendDraftDiscussion != null && onRunWorkWithSelection != null));

  final AxSpace space;
  final AxThread thread;
  final AxDataSource? dataSource;
  final AxDiscussionCache? discussionCache;
  final AxWorkHistoryCache? workHistoryCache;
  final AxThreadViewStateStore? threadViewStateStore;
  final AxSessionCatalogs? catalogs;
  final AxWorkflowConfigurations? workflowConfigurations;
  final String? currentUserId;
  final String? currentUserName;
  final String? viewerEmail;
  final VoidCallback onBackToSpace;
  final VoidCallback onArchive;
  final Future<void> Function()? onRestore;
  final Future<void> Function(String name)? onRename;

  /// Persists the Thread's active tab and workflow/Worker/model/effort
  /// selection into the Thread metadata. Null values clear a stored key.
  final Future<void> Function(Map<String, dynamic> viewState)?
      onViewStateChanged;
  final Future<String> Function(String prompt, String workflowId,
      List<Map<String, dynamic>> attachments, String idempotencyKey)? onRunWork;
  final Future<String> Function(
      String prompt,
      String workflowId,
      List<Map<String, dynamic>> attachments,
      String idempotencyKey,
      Map<String, dynamic> executionSelection)? onRunWorkWithSelection;
  final Stream<Map<String, dynamic>>? realtimeEvents;
  final int initialTab;

  /// Opens the read-only AI History panel when the page is created.
  final bool initialAiHistoryOpen;

  /// Whether this host exposes AI History. The product host supplies the
  /// Space-level opt-in; the default keeps isolated component uses compatible.
  final bool showAiHistory;

  /// Deletes the Thread's Chat messages, including archived AI answers.
  final Future<void> Function()? onClearConversation;

  /// Resets AI context while preserving the visible conversation.
  final Future<void> Function()? onClearAiHistory;

  /// Draft views load Space configuration but never read or persist Thread data.
  final bool isDraft;
  final bool draftBusy;
  final Future<void> Function(String text)? onSendDraftDiscussion;

  // Compatibility getters

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late final AxThreadViewStateStore _threadViewStateStore =
      widget.threadViewStateStore ?? MemoryAxThreadViewStateStore();
  Timer? _threadViewStateSaveTimer;
  int _threadViewStateGeneration = 0;
  bool _threadViewStateRestored = false;
  bool _threadViewReady = false;
  bool _threadViewRevealScheduled = false;
  bool? _paneAwaitingReveal;
  AxThreadViewState? _pendingThreadViewState;
  String? _selectionUpdatedAt;
  Map<String, dynamic>? _lastRemoteViewState;
  final _requestController = TextEditingController();
  bool _requestHistoryOpen = false;
  int _requestHistoryDirection = 1;

  /// Work messages sent while a request was processing, per user and Thread,
  /// oldest first. Kept for the app session so leaving the Thread page and
  /// returning keeps the queue; see `_dispatchQueuedWork`.
  static final _queuedWorkByThread = <String, List<_QueuedWorkMessage>>{};

  /// Paused queues keep their messages until the user resumes them.
  static final _workQueuePauses = <String, _WorkQueuePause>{};
  bool _dispatchingQueuedWork = false;
  String get _workQueueKey =>
      '${widget.currentUserId ?? ''}|${widget.thread.id}';
  _WorkQueuePause? get _workQueuePause {
    if (_sharedQueueSource != null) {
      if (!_sharedQueue.paused) return null;
      return _sharedQueue.pauseReason == 'failure'
          ? _WorkQueuePause.failure
          : _WorkQueuePause.user;
    }
    return _workQueuePauses[_workQueueKey];
  }

  // Cloud pauses the shared queue itself; only the local queue is set here.
  set _workQueuePause(_WorkQueuePause? pause) {
    if (_sharedQueueSource != null) return;
    pause == null
        ? _workQueuePauses.remove(_workQueueKey)
        : _workQueuePauses[_workQueueKey] = pause;
  }

  /// The Thread's queue shared by all members, kept in Cloud, which sends
  /// each request as its author. Data sources without it keep a local,
  /// per-person queue instead.
  AxThreadQueueDataSource? get _sharedQueueSource =>
      widget.isDraft || widget.dataSource is! AxThreadQueueDataSource
          ? null
          : widget.dataSource as AxThreadQueueDataSource;
  AxThreadQueue _sharedQueue = AxThreadQueue.empty;

  /// Read receipts: when each other member last read this Thread. Kept in the
  /// shared engine so a live `thread.read` signal refreshes it.
  List<AxThreadReadState> _readStates = const [];
  void Function()? _cancelReadStates;

  void _watchReadStates() {
    _cancelReadStates?.call();
    _cancelReadStates = null;
    _readStates = const [];
    final source = widget.dataSource;
    if (widget.isDraft || source is! AxThreadReadReceiptsDataSource) return;
    final receipts = source as AxThreadReadReceiptsDataSource;
    final threadId = widget.thread.id;
    final query = AxQuery<List<AxThreadReadState>>(
        key: AxQueryKey(['thread', threadId, 'read-states']),
        load: () => receipts.loadThreadReadStates(threadId));
    final engine = _workHistoryCache.engine;
    _cancelReadStates = engine.watch(query, (state) {
      final next = state.data ?? const <AxThreadReadState>[];
      if (!mounted || identical(next, _readStates)) return;
      setState(() => _readStates = next);
    }, fireImmediately: false);
    unawaited(engine
        .ensure(query)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  /// Members who have read up to [date]: the line under my latest message.
  Widget? _seenBy(DateTime? date) {
    if (date == null) return null;
    final names = [
      for (final state in _readStates)
        if (!state.readAt.isBefore(date)) state.displayName
    ];
    if (names.isEmpty) return null;
    final shown = names.length <= 3
        ? names.join(', ')
        : '${names.take(3).join(', ')} +${names.length - 3}';
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 2, right: 4),
        child: Text('Seen by $shown',
            key: const ValueKey('discussion-seen-by'),
            style: TextStyle(
                fontSize: 11,
                color: SyntilaColors.textSecondary(
                    Theme.of(context).brightness == Brightness.dark))),
      ),
    );
  }

  int _sharedQueueGeneration = 0;
  final _workHistoryController = ScrollController();
  late final AxWorkerUsageController _workerUsage = AxWorkerUsageController(
      widget.dataSource is AxWorkerUsageDataSource
          ? widget.dataSource as AxWorkerUsageDataSource
          : null);
  final _chatHistoryController = ScrollController();
  final _chatIncomingAnchor = AxTimelineFollowAnchor();
  final _workIncomingAnchor = AxTimelineFollowAnchor();
  List<String>? _previousChatIds;
  Map<String, Object?>? _previousWorkReplies;
  bool _followWork = true;
  bool _followChat = true;

  /// Chat messages being edited in place. While any is open the page never
  /// scrolls on its own, so the edited text stays where the person put it.
  final _discussionFocus = FocusNode();

  /// The message being edited in the composer, with the draft that was in the
  /// composer before editing began (restored afterwards).
  String? _editingMessageId;
  String _editingOriginalText = '';
  String _draftBeforeEdit = '';
  // Opening a tab positions it once the Thread view state and history exist:
  // bottom when nothing is new, otherwise the first unread item at the top.
  bool _openChatPending = true;
  bool _openWorkPending = true;
  String? _chatSeenId;

  /// First Chat message the reader had not seen when the Thread opened. It
  /// always shows its sender line, even inside a same-author group.
  String? _firstUnreadChatId;

  /// True from opening a Thread until its first settled (non-fetching) Chat
  /// update, so messages delivered by the open-time revalidation count as
  /// unread rather than as live arrivals.
  bool _chatOpenSettling = true;
  String? _workSeenId;
  bool _chatFollowScheduled = false;
  bool _workFollowScheduled = false;
  int _interactionGeneration = 0;
  bool _loadingOlderChat = false;

  /// The saved Thread tab now selects the conversation composer target:
  /// index 0 sends a Chat message, index 1 asks AI (a Work Request).
  bool get _askAiMode => _tabController.index == 1;

  /// Read-only AI History (the former Work timeline) beside or, on narrow
  /// layouts, instead of the conversation.
  late bool _aiHistoryOpen =
      widget.showAiHistory && widget.initialAiHistoryOpen;
  // AI History stays mounted once opened so switching keeps both lists and
  // their scroll positions; a positioned pane is revealed without hiding.
  late bool _aiHistoryMounted = _aiHistoryOpen;
  // The caller's private Thread note; mounted on first open like AI History.
  bool _notesOpen = false;
  bool _notesMounted = false;
  final _noteEditorController = NoteEditorController();

  AxNotesDataSource? get _notesSource => widget.dataSource is AxNotesDataSource
      ? widget.dataSource as AxNotesDataSource
      : null;

  void _setNotesOpen(bool open) {
    if (open == _notesOpen) return;
    setState(() {
      _notesOpen = open;
      _notesMounted |= open;
    });
    _scheduleThreadViewStateSave();
  }

  bool _chatPositioned = false;
  bool _workPositioned = false;

  Future<void> _confirmClear({required bool history}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        constraints: SyntilaDialogStyle.small,
        title:
            Text(history ? 'Reset AI context' : 'Clear Conversation History'),
        content: Text(history
            ? 'Start fresh AI context for everyone? The visible conversation stays available. '
                'Files and completed work remain unchanged.'
            : 'Delete all human and AI messages for everyone and reset AI context? '
                'Only a notice of this action will remain. Files and completed work remain. '
                'This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await (history ? widget.onClearAiHistory : widget.onClearConversation)
        ?.call();
  }

  Future<void> _confirmClearNote() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        constraints: SyntilaDialogStyle.small,
        title: const Text('Clear Note'),
        content: const Text(
            'Delete all content from this note? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _noteEditorController.clear();
  }

  void _setAiHistoryOpen(bool open) {
    if (open && !widget.showAiHistory) return;
    if (open == _aiHistoryOpen) return;
    _scheduleThreadViewStateSave();
    if (open ? _workPositioned : _chatPositioned) {
      setState(() => _aiHistoryOpen = open);
      final controller = open ? _workHistoryController : _chatHistoryController;
      if (open ? _followWork : _followChat) _scheduleFollowLatest(controller);
      return;
    }
    setState(() {
      _aiHistoryMounted |= open;
      _aiHistoryOpen = open;
      // Lay out and position the destination without painting intermediate
      // scroll offsets. The follow callback reveals it after its final pass.
      _paneAwaitingReveal = open;
      _threadViewReady = false;
      if (open) _openWorkPending = true;
      if (!open) _openChatPending = true;
    });
    _scheduleFollowLatest(
        open ? _workHistoryController : _chatHistoryController);
  }

  void _invalidateInteractionCallbacks() {
    _interactionGeneration++;
    _paneAwaitingReveal = null;
    _chatIncomingAnchor.reset(clearKeys: true);
    _workIncomingAnchor.reset(clearKeys: true);
    _previousChatIds = null;
    _previousWorkReplies = null;
    _firstUnreadChatId = null;
    _chatOpenSettling = true;
    _chatFollowScheduled = false;
    _workFollowScheduled = false;
    _openChatPending = _openWorkPending = true;
    _chatPositioned = _workPositioned = false;
    _lastMaxExtent.clear();
  }

  /// The Conversation reads as Chat messages plus Work requests and answers,
  /// so an AI answer arriving in another Thread counts as unread there. An
  /// answer slot joins only once it has content, so seeing a pending request
  /// does not also mark its later answer as seen.
  List<(String, Object)> _chatSequence() {
    final answered = {
      for (final request in _workPresentation.requests)
        if (_workResponseText(request) != null || request.status == 'failed')
          'work-${request.id}-answer',
    };
    return [
      for (final id in _conversationIds())
        if (!id.startsWith('work-') ||
            !id.endsWith('-answer') ||
            answered.contains(id))
          (id, id),
    ];
  }

  /// Work reads as request/response items so a response arriving later in an
  /// already-seen request counts as new.
  List<(String, Object)> _workSequence() {
    final items = <(String, Object)>[];
    for (final request in _afterAiHistoryClear(_workPresentation.requests)) {
      items.add(('${request.id}|request', (request.id, 'request')));
      if (_workResponseText(request) != null || request.status == 'failed') {
        items.add(('${request.id}|response', (request.id, 'response')));
      }
    }
    return items;
  }

  /// A reader at the latest content keeps following it: a new item scrolls
  /// the timeline to its end. Callers only invoke this while following.
  /// Progress and new requests follow the end of the timeline. An answer is
  /// held at its first line instead, so a long response is read from the top;
  /// the hold lasts until the reader scrolls.
  void _anchorIncoming(AxTimelineFollowAnchor anchor,
      ScrollController controller, List<Object> sequence, Object target) {
    final isAnswer = switch (target) {
      (_, 'response') => true,
      String id => id.endsWith('-answer'),
      _ => false,
    };
    if (!isAnswer) {
      anchor.reset();
      _jumpToLatest(controller);
      return;
    }
    final index = sequence.indexOf(target);
    anchor.anchorAt(target,
        fraction: index < 0 || sequence.length < 2
            ? 1
            : index / (sequence.length - 1),
        once: false);
  }

  final _lastMaxExtent = <bool, double>{};

  /// Keeps a following timeline pinned to its end while content grows in
  /// place, such as a Worker's in-progress output or a row settling height.
  /// Only growth follows, so programmatic jumps elsewhere are left alone.
  bool _onTimelineMetricsChanged(ScrollMetricsNotification notification) {
    for (final (isWork, controller) in [
      (false, _chatHistoryController),
      (true, _workHistoryController),
    ]) {
      if (!(isWork ? _followWork : _followChat) ||
          (isWork ? _openWorkPending : _openChatPending) ||
          (isWork ? _workIncomingAnchor : _chatIncomingAnchor).active ||
          !controller.hasClients ||
          !controller.position.hasContentDimensions) {
        continue;
      }
      final position = controller.position;
      final previous = _lastMaxExtent[isWork];
      _lastMaxExtent[isWork] = position.maxScrollExtent;
      if (previous != null &&
          position.maxScrollExtent > previous + 0.5 &&
          previous - position.pixels <= 24) {
        _jumpToLatest(controller);
      }
    }
    return false;
  }

  bool _tabActive(bool isWork) => isWork ? _aiHistoryOpen : true;

  /// Returns true when the opening step ran and a rebuilt frame must reveal it.
  bool _openTab(bool isWork, ScrollController controller) {
    if (!(isWork ? _openWorkPending : _openChatPending)) return false;
    final hasData =
        isWork ? _workPresentation.hasData : _chatPresentation.hasData;
    if (!_threadViewStateRestored ||
        !hasData ||
        !_tabActive(isWork) ||
        !controller.hasClients ||
        !controller.position.hasContentDimensions) {
      return false;
    }
    final items = isWork ? _workSequence() : _chatSequence();
    final seen = isWork ? _workSeenId : _chatSeenId;
    final seenIndex =
        seen == null ? -1 : items.indexWhere((item) => item.$1 == seen);
    // A last-seen Work item is only found once Work history has loaded; the
    // Work update schedules this step again.
    if (!isWork &&
        seenIndex < 0 &&
        seen != null &&
        seen.startsWith('work-') &&
        !_workPresentation.hasData) {
      return false;
    }
    final anchor = isWork ? _workIncomingAnchor : _chatIncomingAnchor;
    if (isWork) {
      _openWorkPending = false;
      _followWork = true;
    } else {
      _openChatPending = false;
      _followChat = true;
    }
    if (seenIndex < 0 || seenIndex >= items.length - 1) {
      anchor.reset();
      return false;
    }
    if (!isWork) _firstUnreadChatId = items[seenIndex + 1].$1;
    // Hold the first unread item at the top, sender line included, until the
    // reader scrolls; rows settling height later must not follow to the end.
    anchor.anchorAt(items[seenIndex + 1].$2,
        fraction: (seenIndex + 1) / (items.length - 1), once: false);
    // The anchored row needs its GlobalKey attached by a rebuild first.
    setState(() {});
    return true;
  }

  void _markSeen(bool isWork, ScrollController controller) {
    if (isWork ? _openWorkPending : _openChatPending) return;
    if (!_tabActive(isWork) ||
        !controller.hasClients ||
        !controller.position.hasContentDimensions ||
        controller.position.extentAfter > 24) {
      return;
    }
    final items = isWork ? _workSequence() : _chatSequence();
    if (items.isEmpty) return;
    final last = items.last.$1;
    if (last == (isWork ? _workSeenId : _chatSeenId)) return;
    if (isWork) {
      _workSeenId = last;
    } else {
      _chatSeenId = last;
    }
    _scheduleThreadViewStateSave();
  }

  /// Scrolls to the end once the new row is laid out; a second pass covers
  /// rows whose height settles a frame later. A jump queued before an anchor
  /// took hold (such as the first unread message on open) is dropped.
  void _jumpToLatest(ScrollController controller, {int pass = 0}) {
    final generation = _interactionGeneration;
    final anchor = controller == _workHistoryController
        ? _workIncomingAnchor
        : _chatIncomingAnchor;
    final anchored = anchor.active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _interactionGeneration ||
          (!anchored && anchor.active) ||
          !controller.hasClients ||
          !controller.position.hasContentDimensions) {
        return;
      }
      final max = controller.position.maxScrollExtent;
      if (controller.position.pixels != max) controller.jumpTo(max);
      if (pass < 2) _jumpToLatest(controller, pass: pass + 1);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _scheduleFollowLatest(ScrollController controller, {int attempt = 0}) {
    final isWork = controller == _workHistoryController;
    final follow = isWork ? _followWork : _followChat;
    if (!follow && !(isWork ? _openWorkPending : _openChatPending)) return;
    if (isWork ? _workFollowScheduled : _chatFollowScheduled) return;
    final generation = _interactionGeneration;
    if (isWork) {
      _workFollowScheduled = true;
    } else {
      _chatFollowScheduled = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _interactionGeneration) return;
      if (isWork) {
        _workFollowScheduled = false;
      } else {
        _chatFollowScheduled = false;
      }
      if (!mounted || !controller.hasClients) return;
      if (_openTab(isWork, controller)) {
        _scheduleFollowLatest(controller);
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      final stillFollowing =
          controller == _workHistoryController ? _followWork : _followChat;
      if (stillFollowing && !(isWork ? _openWorkPending : _openChatPending)) {
        final anchor = isWork ? _workIncomingAnchor : _chatIncomingAnchor;
        if (anchor.reveal(controller) && attempt < 6) {
          _scheduleFollowLatest(controller, attempt: attempt + 1);
          WidgetsBinding.instance.scheduleFrame();
          return;
        }
      }
      _markSeen(isWork, controller);
      if (_tabActive(isWork) && _threadViewStateRestored) {
        if (isWork) {
          _workPositioned = true;
        } else {
          _chatPositioned = true;
        }
      }
      if (_paneAwaitingReveal == isWork) {
        setState(() {
          _paneAwaitingReveal = null;
          _threadViewReady = true;
        });
      }
    });
  }

  void _onChatPresentationChanged() {
    final state = _chatPresentation;
    final ids = state.messages.map((message) => message.id).toList();
    final previous = _previousChatIds;
    // Work requests and answers are conversation rows too; keep their keys.
    _chatIncomingAnchor.retainMessages([...ids, ..._conversationIds()]);
    if (previous != null) {
      // Only appended entries count: older-page prepends and edits retain
      // the reader's position and never become incoming-message anchors.
      final frontier = previous.isEmpty ? -1 : ids.indexOf(previous.last);
      for (final id in ids.skip(frontier + 1)) {
        if (!previous.contains(id)) {
          final own = state.messages.any((m) => m.id == id && m.isMe);
          if (own) {
            // A message you just sent: jump to the latest content even when
            // the reader had scrolled up.
            _followChat = true;
            _chatIncomingAnchor.reset();
            _jumpToLatest(_chatHistoryController);
          } else if (_chatOpenSettling && _firstUnreadChatId == null) {
            // Delivered by the revalidation of a freshly opened Thread: the
            // reader starts at the first unread message, as when it was
            // already cached.
            final conversation = List<Object>.of(_conversationIds());
            final at = conversation.indexOf(id);
            if (at > 0) {
              _firstUnreadChatId = id;
              _chatIncomingAnchor.anchorAt(id,
                  fraction: at / (conversation.length - 1), once: false);
              setState(() {});
            } else if (_followChat) {
              _anchorIncoming(_chatIncomingAnchor, _chatHistoryController,
                  conversation, id);
            }
          } else if (_followChat && !_chatIncomingAnchor.active) {
            // Another participant's message is read from its sender line, so
            // a long message or a burst of several starts at the first one.
            // Later arrivals keep that hold until the reader scrolls.
            final conversation = List<Object>.of(_conversationIds());
            final at = conversation.indexOf(id);
            _firstUnreadChatId = id;
            _chatIncomingAnchor.anchorAt(id,
                fraction: at < 0 || conversation.length < 2
                    ? 1
                    : at / (conversation.length - 1),
                once: false);
            setState(() {});
          }
          break;
        }
      }
    }
    if (state.hasData && !state.isFetching) _chatOpenSettling = false;
    if (state.hasData) _previousChatIds = ids;
    _scheduleFollowLatest(_chatHistoryController);
  }

  void _onWorkPresentationChanged() {
    final state = _workPresentation;
    final previous = _previousWorkReplies;
    final replies = <String, Object?>{};
    _workIncomingAnchor.retainMessages([
      for (final request in state.requests) ...[
        (request.id, 'request'),
        (request.id, 'response'),
      ],
    ]);
    final frontier =
        state.requests.indexWhere((r) => previous?.containsKey(r.id) == true);
    for (final (index, request) in state.requests.indexed) {
      final response = _workResponseText(request);
      final reply = response == null && request.status != 'failed'
          ? null
          : (response, request.error, request.status == 'failed');
      replies[request.id] = reply;
      // A failed request stops the queue: later messages would build on a
      // result that never arrived, so they wait until the user resumes.
      if (reply != null &&
          reply.$3 &&
          previous != null &&
          previous.containsKey(request.id) &&
          (previous[request.id] as (String?, String?, bool)?)?.$3 != true &&
          _workQueue.isNotEmpty) {
        _workQueuePause ??= _WorkQueuePause.failure;
      }
      if (previous != null) {
        if (!previous.containsKey(request.id)) {
          // Prepending a history page must not move the viewport.
          if (previous.isEmpty || index > frontier) {
            final viewerId = widget.currentUserId;
            if (viewerId != null && request.requestedByUserId == viewerId) {
              // A request you just sent: jump to the latest content even
              // when the reader had scrolled up.
              _followWork = true;
              _workIncomingAnchor.reset();
              _jumpToLatest(_workHistoryController);
              _followChat = true;
              _chatIncomingAnchor.reset();
              _jumpToLatest(_chatHistoryController);
              continue;
            }
            if (!_followWork) continue;
            _anchorIncoming(
                _workIncomingAnchor,
                _workHistoryController,
                [for (final item in _workSequence()) item.$2],
                (request.id, 'request'));
          }
        } else if (_followWork &&
            reply != null &&
            reply != previous[request.id]) {
          _anchorIncoming(
              _workIncomingAnchor,
              _workHistoryController,
              [for (final item in _workSequence()) item.$2],
              (request.id, 'response'));
        }
      }
    }
    if (state.hasData) _previousWorkReplies = replies;
    _scheduleFollowLatest(_workHistoryController);
    _followWorkInConversation(state, previous);
    _scheduleFollowLatest(_chatHistoryController);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => mounted ? _dispatchQueuedWork() : null);
  }

  /// Conversation item IDs in display order; see [_mergeWorkIntoConversation].
  List<String> _conversationIds() {
    final groups = <(DateTime?, List<String>)>[
      for (final message in _chatPresentation.messages)
        (DateTime.tryParse(message.createdAt)?.toLocal(), [message.id]),
      for (final request in _workPresentation.requests)
        (
          DateTime.tryParse(request.createdAt)?.toLocal(),
          ['work-${request.id}-request', 'work-${request.id}-answer'],
        ),
    ];
    final indexed = groups.indexed.toList()..sort(_byConversationTime);
    return [for (final entry in indexed) ...entry.$2.$2];
  }

  static int _byConversationTime(
      (int, (DateTime?, Object)) a, (int, (DateTime?, Object)) b) {
    final left = a.$2.$1, right = b.$2.$1;
    final byDate = left == null || right == null ? 0 : left.compareTo(right);
    return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
  }

  /// Work Requests are conversation entries too. The first Work page keeps a
  /// following reader at the latest content; later requests and answers are
  /// revealed from their opening like incoming Chat messages.
  void _followWorkInConversation(
      ThreadWorkPresentationSnapshot state, Map<String, Object?>? previous) {
    if (!state.hasData || !_followChat) return;
    if (previous == null) {
      if (!_chatIncomingAnchor.active) _jumpToLatest(_chatHistoryController);
      return;
    }
    for (final request in state.requests) {
      final reply = _previousWorkReplies?[request.id];
      final String target;
      if (!previous.containsKey(request.id)) {
        target = 'work-${request.id}-request';
      } else if (reply != null && reply != previous[request.id]) {
        target = 'work-${request.id}-answer';
      } else {
        continue;
      }
      _anchorIncoming(_chatIncomingAnchor, _chatHistoryController,
          List<Object>.of(_conversationIds()), target);
      return;
    }
  }

  void _onWorkActivityChanged() {
    _scheduleFollowLatest(_workHistoryController);
    // A held answer stays put; only unanswered progress follows the end.
    if (_followChat && !_openChatPending && !_chatIncomingAnchor.active) {
      _jumpToLatest(_chatHistoryController);
    }
    if (_followWork && !_openWorkPending && !_workIncomingAnchor.active) {
      _jumpToLatest(_workHistoryController);
    }
  }

  void _onWorkHistoryScroll() {
    if (!_workHistoryController.hasClients) return;
    final position = _workHistoryController.position;
    if (position.userScrollDirection == ScrollDirection.idle) {
      _markSeen(true, _workHistoryController);
      return;
    }
    _followWork = position.extentAfter <= 24;
    _workIncomingAnchor.reset();
    _markSeen(true, _workHistoryController);
    if (position.userScrollDirection == ScrollDirection.forward &&
        position.extentBefore <= 24 &&
        _workHistoryCache.peek(widget.thread.id).olderCursor != null &&
        !_workHistoryCache.loadingOlder(widget.thread.id) &&
        _workHistoryCache.error(widget.thread.id) == null) {
      unawaited(_loadOlderWorkHistory());
    }
  }

  void _onChatHistoryScroll() {
    if (!_chatHistoryController.hasClients) return;
    final position = _chatHistoryController.position;
    if (position.userScrollDirection == ScrollDirection.idle) {
      _markSeen(false, _chatHistoryController);
      return;
    }
    _followChat = position.extentAfter <= 24;
    _chatIncomingAnchor.reset();
    _markSeen(false, _chatHistoryController);
    if (position.userScrollDirection == ScrollDirection.forward &&
        position.extentBefore <= 24) {
      final state = _discussionCache.peek(widget.thread.id);
      if (state.olderCursor != null &&
          !state.loadingOlder &&
          state.error == null) {
        unawaited(_loadOlderDiscussion());
      }
    }
  }

  final _composerInputHeight = ComposerInputHeight();
  final _discussionController = TextEditingController();
  late AxSessionCatalogs _catalogs;
  void Function()? _cancelWorkflowWorkspace;
  void Function()? _cancelWorkflows;
  void Function()? _cancelWorkers;
  String? _selectedWorkflowWorkspaceId;
  int _choicesGeneration = 0;
  String _workflow = '';
  List<AxBuiltinWorkflow> _workflowCatalog = const [];
  List<AxBuiltinWorkflow> get _currentWorkflows =>
      _currentWorkflowVersions(_availableWorkflows);
  List<AxBuiltinWorkflow> get _availableWorkflows => _workflowCatalog
      .where((workflow) =>
          canPreviewUnimplementedWorkflows(widget.viewerEmail) ||
          implementedWorkflowIds.contains(workflow.id))
      // Workflows disabled in the configuration are not offered; Chat can
      // never be disabled.
      .where((workflow) =>
          workflow.id == 'chat' ||
          _userWorkflowConfigurations
              .where((value) => value.workflowId == workflow.id)
              .every((value) => value.enabled))
      .where((workflow) => workflow.id == 'chat'
          ? widget.space.effectivePermissions.chat
          : widget.space.effectivePermissions.work)
      .toList();
  String get _effectiveWorkflow =>
      _availableWorkflows.any((item) => item.reference == _workflow)
          ? _workflow
          : _availableWorkflows.firstOrNull?.reference ?? '';
  bool _loadingWorkflows = true;
  String? _workflowCatalogError;
  late AxDiscussionCache _fallbackDiscussionCache;
  AxDiscussionCache get _discussionCache =>
      widget.discussionCache ?? _fallbackDiscussionCache;
  late AxWorkHistoryCache _fallbackWorkHistoryCache;
  AxWorkHistoryCache get _workHistoryCache =>
      widget.workHistoryCache ?? _fallbackWorkHistoryCache;
  AxWorkRealtimeSync get _workRealtime =>
      AxWorkRealtimeSync.forCache(_workHistoryCache);
  final _workActivityStore = AxWorkActivityStore();
  late final ThreadPresentationController _presentation;
  // A terminal Worker activity precedes the result frame, so the request detail
  // is re-read shortly after only if Work status events have not caught up.
  final _terminalActivityChecks = <String, Timer>{};
  bool _loadingOlderWork = false;
  List<AxWorkRequest> get _workTimeline =>
      _presentation.work.value?.requests ?? const [];

  /// AI History starts after its last clear; the Conversation keeps every
  /// request through [_workTimeline].
  /// AI History responses the reader opened or closed, per request.
  final _historyResponseOverrides = <String, bool>{};

  List<AxWorkRequest> get _aiHistoryTimeline =>
      _afterAiHistoryClear(_workTimeline);

  List<AxWorkRequest> _afterAiHistoryClear(List<AxWorkRequest> requests) {
    final clearedAt = DateTime.tryParse(
        _workHistoryCache.aiHistoryClearedAt(widget.thread.id) ?? '');
    if (clearedAt == null) return requests;
    return requests
        .where((request) =>
            DateTime.tryParse(request.createdAt)?.isAfter(clearedAt) ?? true)
        .toList();
  }

  void _subscribeWorkHistory() {
    if (widget.isDraft) return;
    _presentation.attach(
      threadId: widget.thread.id,
      discussionCache: _discussionCache,
      workHistoryCache: _workHistoryCache,
    );
  }

  Map<String, String> get _localWorkProgress => _workPresentation.localProgress;

  ThreadWorkPresentationSnapshot get _workPresentation =>
      _presentation.work.value ??
      const ThreadWorkPresentationSnapshot(
        generation: 0,
        requests: [],
        hasData: false,
        isFetching: false,
        loadingOlder: false,
        olderCursor: null,
        error: null,
        submitting: false,
        localProgress: {},
      );

  ThreadChatPresentationSnapshot get _chatPresentation =>
      _presentation.chat.value ??
      const ThreadChatPresentationSnapshot(
        generation: 0,
        messages: [],
        hasData: false,
        isFetching: false,
        loadingOlder: false,
        olderCursor: null,
        error: null,
      );

  bool get _loadingWorkTimeline =>
      !_workPresentation.hasData && _workPresentation.isFetching;
  String? get _workTimelineError => _workPresentation.error?.toString();
  String? _workSubmitError;

  /// The last send was blocked by an incomplete Worker/model/effort choice.
  bool _workSelectionMissing = false;
  final _reportedIssues = <String, AxIssueReport>{};
  final _reportedIssueKeys = <String, String>{};
  final _issueReportErrors = <String, String>{};
  final _reportingIssueIds = <String>{};
  final _checkedIssueReportKeys = <String>{};
  final _issueReportLoads = <String, Future<void>>{};
  StreamSubscription<Map<String, dynamic>>? _workEventSubscription;
  void Function()? _cancelWorkRealtime;
  bool _draftSubmitting = false;
  bool get _submittingWork =>
      widget.draftBusy || _draftSubmitting || _workPresentation.submitting;
  List<Map<String, dynamic>> _workAttachments = [];
  List<Map<String, dynamic>> _discussionAttachments = [];

  /// The message the next Chat message or request replies to (Reply v1).
  /// One target per Thread, shared by both composers, cleared on send.
  AxReplyReference? _replyTarget;

  /// Keeps the timeline transparent during reply navigation until the target
  /// position is measured and settled, preventing jerky visible intermediate scroll.
  bool _navigatingToReply = false;

  /// Target message or work card currently highlighted with a pulse tint.
  String? _replyHighlightId;
  Timer? _replyHighlightTimer;
  Map<String, dynamic> _workExecutionSelection = {};

  /// The last Worker selection, kept while a Workflow that fixes its own
  /// Worker is selected so switching back restores the Thread's choice.
  Map<String, dynamic> _lastWorkerSelection = {};
  List<AxWorker> _spaceWorkers = const [];
  List<AxWorker> _eligibleWorkers = const [];

  /// Workers from Workspaces the viewer owns outside the Space Workspace.
  /// They answer only the Chat workflow, when the Space allows own Workers.
  List<AxWorker> _ownChatWorkers = const [];

  /// The Space Workspace query answered, even if the Space has none yet.
  bool _workflowWorkspaceLoaded = false;
  bool get _chatWorkflowSelected =>
      _effectiveWorkflow.split(':').first == 'chat';
  List<AxWorker> get _composerWorkers => _chatWorkflowSelected
      ? [..._spaceWorkers, ..._ownChatWorkers]
      : _spaceWorkers;
  List<AxWorker> get _composerEligibleWorkers => _chatWorkflowSelected
      ? [..._eligibleWorkers, ..._ownChatWorkers.where((w) => w.isReady)]
      : _eligibleWorkers;
  AxWorkflowConfigurations? _workflowConfigurations;
  void Function()? _cancelWorkflowConfigurations;
  void Function()? _cancelWorkflowDefault;
  String? _workflowDefaultId;
  List<AxUserWorkflowConfiguration> _userWorkflowConfigurations = const [];

  void _onPresentationWorkChanged() {
    if (!mounted) return;
    _scheduleIssueReportStatusLoads();
    _scheduleFollowLatest(_workHistoryController);
  }

  void _scheduleThreadViewStateSave() {
    if (widget.isDraft ||
        !_threadViewStateRestored ||
        widget.currentUserId == null) {
      return;
    }
    _threadViewStateSaveTimer?.cancel();
    _threadViewStateSaveTimer = Timer(const Duration(milliseconds: 180), () {
      _threadViewStateSaveTimer = null;
      unawaited(_saveThreadViewState());
    });
  }

  /// The Thread's own choice only. The Workflow binding shown when nothing
  /// is chosen is a default and must not be persisted as the Thread's choice.
  String? _explicitSelectionValue(String key) {
    final value = _workExecutionSelection[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  AxThreadViewState _currentThreadViewState() {
    final pending = _pendingThreadViewState;
    final workerId = _explicitSelectionValue('workerId');
    final workerTypeId = _composerWorkers
            .where((worker) => worker.id == workerId)
            .firstOrNull
            ?.workerTypeId ??
        (pending?.workerId == workerId ? pending?.workerTypeId : null);
    return AxThreadViewState(
      tabIndex: _tabController.index,
      // A selection still waiting for the catalogs must survive a save made
      // before it is applied; the live values are only defaults at that point.
      workflowReference: pending != null
          ? pending.workflowReference
          : (_effectiveWorkflow.isEmpty ? null : _effectiveWorkflow),
      workerId: pending != null ? pending.workerId : workerId,
      workerTypeId: pending != null ? pending.workerTypeId : workerTypeId,
      model: pending != null ? pending.model : _explicitSelectionValue('model'),
      reasoningEffort: pending != null
          ? pending.reasoningEffort
          : _explicitSelectionValue('reasoningEffort'),
      catalogRevision: pending != null
          ? pending.catalogRevision
          : _explicitSelectionValue('catalogRevision'),
      selectionUpdatedAt:
          pending != null ? pending.selectionUpdatedAt : _selectionUpdatedAt,
      chatDraft: _editingMessageId != null
          ? _draftBeforeEdit
          : _discussionController.text,
      workDraft: _requestController.text,
      chatSeenId: _chatSeenId,
      workSeenId: _workSeenId,
      pane: _notesOpen
          ? AxThreadViewState.notesPane
          : _aiHistoryOpen
              ? AxThreadViewState.aiHistoryPane
              : AxThreadViewState.conversationPane,
    );
  }

  Map<String, dynamic> _remoteViewStatePayload(AxThreadViewState state) => {
        'tabIndex': state.tabIndex.clamp(0, 1),
        'workflowReference': state.workflowReference,
        'workerId': state.workerId,
        'workerTypeId': state.workerTypeId,
        'model': state.model,
        'reasoningEffort': state.reasoningEffort,
        'catalogRevision': state.catalogRevision,
        'selectionUpdatedAt': state.selectionUpdatedAt,
      };

  AxThreadViewState? _withRemoteViewState(AxThreadViewState? local) =>
      AxThreadViewState.withRemote(local, widget.thread.viewState);

  Future<void> _saveThreadViewState() async {
    if (widget.isDraft) return;
    final userId = widget.currentUserId;
    if (!_threadViewStateRestored || userId == null || userId.isEmpty) return;
    final state = _currentThreadViewState();
    await _threadViewStateStore.save(
      userId: userId,
      threadId: widget.thread.id,
      state: state,
    );
    _persistRemoteViewState(state);
  }

  void _persistRemoteViewState(AxThreadViewState state, [ThreadPage? owner]) {
    final source = owner ?? widget;
    final callback = source.onViewStateChanged;
    // While a saved selection is still waiting for the catalogs, the current
    // state is only defaults and must not replace the stored choice.
    if (callback == null ||
        !source.thread.canConfigureWork ||
        (owner == null && _pendingThreadViewState != null)) {
      return;
    }
    final payload = _remoteViewStatePayload(state);
    final previous = _lastRemoteViewState;
    if (previous != null && mapEquals(previous, payload)) return;
    _lastRemoteViewState = payload;
    callback(payload).catchError((Object _) {
      // Leave the next change (or reopen) to retry; local state is intact.
      if (mapEquals(_lastRemoteViewState, payload)) {
        _lastRemoteViewState = previous;
      }
    });
  }

  /// An explicit choice supersedes a saved selection still waiting for the
  /// catalogs; otherwise saves keep the old values and the late restore
  /// overwrites the user's choice.
  void _markSelectionChangedByUser() {
    final pending = _pendingThreadViewState;
    if (pending != null) {
      if (pending.workflowReference != null &&
          _availableWorkflows
              .any((item) => item.reference == pending.workflowReference)) {
        _workflow = pending.workflowReference!;
      }
      _pendingThreadViewState = null;
    }
    _selectionUpdatedAt = DateTime.now().toUtc().toIso8601String();
  }

  void _reconcilePendingThreadViewState() {
    final saved = _pendingThreadViewState;
    if (saved == null || _availableWorkflows.isEmpty) return;
    if (saved.workerId != null &&
        !_catalogs.engine.peek(_catalogs.workers).hasData) {
      return;
    }
    // Match the exact reference first, then the same workflow code at its
    // current version so a version bump keeps the stored choice.
    final savedId = saved.workflowReference?.split(':').first;
    final workflow = _availableWorkflows
            .where((item) => item.reference == saved.workflowReference)
            .firstOrNull ??
        (savedId == null
            ? null
            : _currentWorkflowVersions(_availableWorkflows)
                .where((item) => item.id == savedId)
                .firstOrNull);
    // A saved Workflow that no longer exists falls back to the default
    // Workflow but keeps the saved Worker, model and effort.
    if (workflow == null && _loadingWorkflows) return;
    if (workflow != null) _workflow = workflow.reference;
    var workerId = saved.workerId;
    var catalogRevision = saved.catalogRevision;
    final knownWorkers = [..._spaceWorkers, ..._ownChatWorkers];
    if (workerId != null && _spaceWorkers.isNotEmpty) {
      // Worker IDs can change when a Worker is rebuilt or re-registered; the
      // Worker type code does not. Re-bind by code when the ID is gone. The
      // viewer's own Workers count too, so a saved own Worker is never
      // swapped for a Space Worker of the same type.
      var worker = knownWorkers.where((w) => w.id == workerId).firstOrNull;
      if (worker == null && saved.workerTypeId != null) {
        final sameType = knownWorkers
            .where((w) => w.workerTypeId == saved.workerTypeId)
            .toList();
        final ready = sameType.where((w) => w.isReady).toList();
        worker = ready.length == 1
            ? ready.single
            : sameType.length == 1
                ? sameType.single
                : null;
        if (worker != null) workerId = worker.id;
      }
      // The catalog revision changes with every rebuilt Worker catalog; model
      // and effort codes stay as saved.
      final current = worker?.executionOptions?.catalogRevision;
      if (current != null) catalogRevision = current;
    }
    // Restoring preferences never silently replaces unavailable saved choices.
    final selection = <String, dynamic>{
      if (workerId != null) 'workerId': workerId,
      if (saved.model != null) 'model': saved.model,
      if (saved.reasoningEffort != null)
        'reasoningEffort': saved.reasoningEffort,
      if (catalogRevision != null) 'catalogRevision': catalogRevision,
    };
    _workExecutionSelection = selection;
    _pendingThreadViewState = null;
    _updateComposerState(() {});
  }

  /// Reopens the Thread's last pane. Runs before the restored Thread's first
  /// frame, where both lists still wait to be positioned.
  void _restorePane(String? pane) {
    if (pane == null) return;
    _aiHistoryOpen =
        widget.showAiHistory && pane == AxThreadViewState.aiHistoryPane;
    _aiHistoryMounted |= _aiHistoryOpen;
    _notesOpen = _notesMounted =
        pane == AxThreadViewState.notesPane && _notesSource != null;
  }

  /// Both stores read synchronously, so the saved view is applied before the
  /// Thread's first frame instead of after an extra async round trip.
  void _restoreThreadViewState() {
    final userId = widget.currentUserId;
    final threadId = widget.thread.id;
    final generation = ++_threadViewStateGeneration;
    _threadViewStateRestored = false;
    _threadViewReady = false;
    _threadViewRevealScheduled = false;
    _pendingThreadViewState = null;
    if (widget.isDraft || userId == null || userId.isEmpty) {
      _threadViewStateRestored = true;
      _threadViewReady = true;
      return;
    }
    final saved = _withRemoteViewState(_threadViewStateStore.loadSync(
      userId: userId,
      threadId: threadId,
    ));
    if (!mounted ||
        generation != _threadViewStateGeneration ||
        widget.thread.id != threadId ||
        widget.currentUserId != userId) {
      return;
    }
    _threadViewStateRestored = true;
    if (widget.thread.viewState.isNotEmpty && saved != null) {
      _lastRemoteViewState = _remoteViewStatePayload(saved);
    }
    if (saved != null) {
      // Never overwrite non-empty input or an active edit session with the
      // persisted draft.
      if (_discussionController.text.isEmpty && saved.chatDraft.isNotEmpty) {
        _discussionController.value = TextEditingValue(
          text: saved.chatDraft,
          selection: TextSelection.collapsed(offset: saved.chatDraft.length),
        );
      }
      if (_requestController.text.isEmpty && saved.workDraft.isNotEmpty) {
        _requestController.value = TextEditingValue(
          text: saved.workDraft,
          selection: TextSelection.collapsed(offset: saved.workDraft.length),
        );
      }
      _chatSeenId = saved.chatSeenId;
      _workSeenId = saved.workSeenId;
      _restorePane(saved.pane);
      _selectionUpdatedAt = saved.selectionUpdatedAt;
      _pendingThreadViewState = saved;
      final targetIndex = saved.tabIndex.clamp(0, _tabController.length - 1);
      if (_tabController.index != targetIndex) {
        _tabController.index = targetIndex;
      }
      _reconcilePendingThreadViewState();
    }
    // Callers run in initState/didUpdateWidget, which always rebuild next.
    _scheduleThreadViewStateSave();
    _scheduleFollowLatest(_chatHistoryController);
    _scheduleFollowLatest(_workHistoryController);
  }

  void _onThreadTabChanged() {
    AxRenderDiagnostics.instance.updateContext(
      threadId: widget.thread.id,
      tab: _tabController.index == 1 ? 'work' : 'chat',
      component: 'ThreadPage',
      mounted: mounted,
      disposed: false,
    );
    if (!_tabController.indexIsChanging) _scheduleThreadViewStateSave();
  }

  Map<String, dynamic> get _composerWorkConfig {
    final id = _effectiveWorkflow.split(':').first;
    final definition = _availableWorkflows
        .where((workflow) => workflow.reference == _effectiveWorkflow)
        .firstOrNull;
    final configuration = _userWorkflowConfigurations
        .where((value) => value.workflowId == id)
        .firstOrNull;
    return {
      'bindings': {
        for (final step in definition?.steps ?? const <AxBuiltinWorkflowStep>[])
          (id == 'direct' ? 'direct' : step.kind): {
            if (configuration?.selectionFor(step.kind).worker != null)
              'workerId': configuration!.selectionFor(step.kind).worker,
            if (configuration?.selectionFor(step.kind).model != null)
              'model': configuration!.selectionFor(step.kind).model,
            if (configuration?.selectionFor(step.kind).effort != null)
              'reasoningEffort': configuration!.selectionFor(step.kind).effort,
            if (configuration?.selectionFor(step.kind).catalogRevision != null)
              'catalogRevision':
                  configuration!.selectionFor(step.kind).catalogRevision,
          }
      }
    };
  }

  void _subscribeWorkflowConfigurations() {
    final ds = widget.dataSource;
    _cancelWorkflowDefault?.call();
    _workflowConfigurations =
        widget.workflowConfigurations?.spaceId == widget.space.id
            ? widget.workflowConfigurations
            : ds is AxSpaceWorkflowConfigurationDataSource
                ? AxWorkflowConfigurations(ds!,
                    engine: _workHistoryCache.engine, spaceId: widget.space.id)
                : null;
    final cache = _workflowConfigurations;
    if (cache == null) return;
    _cancelWorkflowConfigurations = cache.engine.watch(cache.query, (state) {
      if (!mounted) return;
      _updateComposerState(() {
        _userWorkflowConfigurations = state.data ?? const [];
        if (!_threadViewStateRestored || widget.currentUserId == null) {
          _workExecutionSelection = {};
        }
      });
    });
    _workflowDefaultId = cache.engine.peek(cache.defaultQuery).data;
    _cancelWorkflowDefault = cache.engine.watch(cache.defaultQuery, (state) {
      if (!mounted) return;
      if (state.hasData) {
        _updateComposerState(() {
          _workflowDefaultId = state.data;
          if (!_threadViewStateRestored || widget.currentUserId == null) {
            _workExecutionSelection = {};
          }
          if ((!_threadViewStateRestored || widget.currentUserId == null) &&
              _workflowCatalog.isNotEmpty) {
            _workflow = _threadDefaultReference(_workflowCatalog,
                preferredId: _workflowDefaultId);
          }
        });
      }
    }, fireImmediately: false);
    unawaited(cache
        .ensure()
        .catchError((Object error) => <AxUserWorkflowConfiguration>[]));
    unawaited(cache.ensureDefault().catchError((Object error) => 'chat'));
  }

  @override
  void initState() {
    super.initState();
    _claimWorkQueue();
    AxRenderDiagnostics.instance.updateContext(
      threadId: widget.thread.id,
      tab: widget.initialTab == 1 ? 'work' : 'chat',
      component: 'ThreadPage',
      mounted: true,
      disposed: false,
    );
    _fallbackDiscussionCache = widget.discussionCache ??
        AxDiscussionCache.forSource(widget.dataSource);
    _fallbackWorkHistoryCache = widget.workHistoryCache ??
        AxWorkHistoryCache.forSource(widget.dataSource);
    _presentation = ThreadPresentationController(
      activityStore: _workActivityStore,
      onWorkChanged: _onPresentationWorkChanged,
    );
    _presentation.chat.addListener(_onChatPresentationChanged);
    _presentation.work.addListener(_onWorkPresentationChanged);
    _workActivityStore.addListener(_onWorkActivityChanged);
    _subscribeWorkHistory();
    _workHistoryController.addListener(_onWorkHistoryScroll);
    _chatHistoryController.addListener(_onChatHistoryScroll);
    _tabController = TabController(
      length: 2,
      initialIndex: widget.initialTab == 2 ? 1 : widget.initialTab.clamp(0, 1),
      vsync: this,
    );
    _tabController.addListener(_onThreadTabChanged);
    _refreshWorkTimeline();
    _requestController.addListener(_scheduleThreadViewStateSave);
    _discussionController.addListener(_scheduleThreadViewStateSave);
    _subscribeToWorkEvents();
    _subscribeWorkflowConfigurations();
    _subscribeCatalogs();
    _subscribeWorkflowWorkspace();
    _loadWorkChoices();
    _loadWorkflowCatalog();
    _restoreThreadViewState();
    _loadSharedQueue();
    _watchReadStates();
  }

  void _applyWorkers(List<AxWorker> workers) {
    _spaceWorkers = workers
        .where((worker) => worker.workspaceId == _selectedWorkflowWorkspaceId)
        .toList();
    // Until the Space Workspace is known, a Worker cannot be told apart from
    // the Space's own, so none is offered as the viewer's own.
    _ownChatWorkers = widget.space.effectivePermissions.useOwnWorkers &&
            (_selectedWorkflowWorkspaceId != null || _workflowWorkspaceLoaded)
        ? [
            for (final worker in workers)
              if (!worker.shared &&
                  worker.workspaceId != _selectedWorkflowWorkspaceId)
                worker.withDisplayName(
                    '${worker.displayName} · ${worker.workspaceName}'),
          ]
        : const [];
    _eligibleWorkers = _spaceWorkers
        .where((worker) =>
            worker.activationState == 'enabled' &&
            worker.readinessState == 'ready' &&
            worker.catalogLifecycleState == 'active' &&
            worker.catalogVisibilityState == 'visible')
        .toList();
  }

  void _subscribeCatalogs() {
    _cancelWorkflows?.call();
    _cancelWorkers?.call();
    _catalogs =
        widget.catalogs ?? AxSessionCatalogs.forSource(widget.dataSource);
    final workflows = _catalogs.engine.peek(_catalogs.workflows);
    _workflowCatalog = visibleWorkflowDefinitions(
        workflows.data ?? const <AxBuiltinWorkflow>[],
        viewerEmail: widget.viewerEmail);
    _loadingWorkflows = !workflows.hasData;
    if (_workflowCatalog.isNotEmpty &&
        !_workflowCatalog.any((item) => item.reference == _workflow)) {
      _workflow = _threadDefaultReference(_workflowCatalog,
          preferredId: _workflowDefaultId);
    }
    _applyWorkers(_catalogs.engine.peek(_catalogs.workers).data ?? const []);
    _cancelWorkflows = _catalogs.engine.watch(_catalogs.workflows, (state) {
      if (!mounted) return;
      _updateComposerState(() {
        if (state.hasData) {
          _workflowCatalog = visibleWorkflowDefinitions(state.data!,
              viewerEmail: widget.viewerEmail);
          if (!_workflowCatalog.any((item) => item.reference == _workflow)) {
            _workflow = _threadDefaultReference(_workflowCatalog,
                preferredId: _workflowDefaultId);
          }
          _reconcilePendingThreadViewState();
        }
        _loadingWorkflows = !state.hasData && state.isFetching;
        _workflowCatalogError = state.error != null
            ? 'Could not load the Workflow catalog.'
            : state.hasData && state.data!.isEmpty
                ? 'No built-in Workflows are available.'
                : null;
      });
    }, fireImmediately: false);
    _cancelWorkers = _catalogs.engine.watch(_catalogs.workers, (state) {
      if (!mounted) return;
      if (state.hasData) {
        _updateComposerState(() => _applyWorkers(state.data!));
      }
    }, fireImmediately: false);
  }

  Future<void> _loadWorkflowCatalog() async {
    final ds = widget.dataSource;
    final catalogs = _catalogs;
    if (ds == null) {
      _updateState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Workflow catalog is unavailable.';
      });
      return;
    }
    try {
      await catalogs.ensureWorkflows();
      if (!mounted || catalogs != _catalogs) return;
      final workflows = catalogs.engine.peek(catalogs.workflows).data ??
          const <AxBuiltinWorkflow>[];
      final visibleWorkflows = visibleWorkflowDefinitions(workflows,
          viewerEmail: widget.viewerEmail);
      _updateState(() {
        _workflowCatalog = visibleWorkflows;
        _loadingWorkflows = false;
        _workflowCatalogError = visibleWorkflows.isEmpty
            ? 'No built-in Workflows are available.'
            : null;
        if (visibleWorkflows.isEmpty) {
          _workflow = '';
        } else if (!visibleWorkflows
            .any((item) => item.reference == _workflow)) {
          _workflow = _threadDefaultReference(visibleWorkflows,
              preferredId: _workflowDefaultId);
        }
        _reconcilePendingThreadViewState();
      });
    } catch (_) {
      if (!mounted || catalogs != _catalogs) return;
      _updateState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Could not load the Workflow catalog.';
      });
    }
  }

  String _threadDefaultReference(List<AxBuiltinWorkflow> workflows,
      {String? preferredId}) {
    if (workflows.isEmpty) return '';
    final current = _currentWorkflowVersions(workflows);
    if (preferredId != null) {
      final preferred =
          current.where((item) => item.id == preferredId).firstOrNull;
      if (preferred != null) return preferred.reference;
    }
    // The Work composer needs a stable default after thread-level execution
    // settings are removed. Prefer the general-purpose work workflow when the
    // catalog exposes it, then fall back to the catalog's first current entry.
    for (final preferred in ['direct', 'work']) {
      final match = current.where((item) => item.id == preferred).firstOrNull;
      if (match != null) return match.reference;
    }
    return current.firstOrNull?.reference ?? '';
  }

  void _subscribeWorkflowWorkspace() {
    _cancelWorkflowWorkspace?.call();
    final cache = _workflowConfigurations;
    if (cache == null) {
      _selectedWorkflowWorkspaceId = null;
      _workflowWorkspaceLoaded = false;
      _applyWorkers(_catalogs.engine.peek(_catalogs.workers).data ?? const []);
      return;
    }
    final state = cache.engine.peek(cache.workspaceQuery);
    _selectedWorkflowWorkspaceId = state.data?.workspaceId;
    _workflowWorkspaceLoaded = state.data != null;
    _applyWorkers(_catalogs.engine.peek(_catalogs.workers).data ?? const []);
    _cancelWorkflowWorkspace =
        cache.engine.watch(cache.workspaceQuery, (state) {
      if (!mounted) return;
      _updateState(() {
        _selectedWorkflowWorkspaceId = state.data?.workspaceId;
        _workflowWorkspaceLoaded = state.data != null;
        _applyWorkers(
            _catalogs.engine.peek(_catalogs.workers).data ?? const []);
        _reconcilePendingThreadViewState();
      });
    });
  }

  Future<void> _loadWorkChoices() async {
    final ds = widget.dataSource;
    final generation = ++_choicesGeneration;
    final catalogs = _catalogs;
    final spaceId = widget.space.id;
    if (ds == null) {
      return;
    }
    try {
      await Future.wait([
        catalogs.ensureWorkers(),
        _workflowConfigurations?.ensureWorkspace() ?? Future.value(null),
      ]);
      if (!mounted) return;
      if (generation != _choicesGeneration || catalogs != _catalogs) return;
      if (spaceId != widget.space.id) return;
      _updateState(() {
        _selectedWorkflowWorkspaceId = _workflowConfigurations?.engine
            .peek(_workflowConfigurations!.workspaceQuery)
            .data
            ?.workspaceId;
        _applyWorkers(catalogs.engine.peek(catalogs.workers).data ?? const []);
        _reconcilePendingThreadViewState();
      });
    } catch (_) {
      // The shared queries retain their last valid data on refresh failure.
    }
  }

  @override
  void didUpdateWidget(ThreadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showAiHistory && !widget.showAiHistory) {
      _aiHistoryOpen = false;
      _aiHistoryMounted = false;
    }
    final threadChanged = oldWidget.thread.id != widget.thread.id;
    if (threadChanged ||
        oldWidget.currentUserId != widget.currentUserId ||
        oldWidget.isDraft != widget.isDraft) {
      _releaseWorkQueue(oldWidget);
      _claimWorkQueue();
    }

    if (threadChanged || oldWidget.dataSource != widget.dataSource) {
      _sharedQueue = AxThreadQueue.empty;
      _loadSharedQueue();
    }
    if (threadChanged) {
      _invalidateInteractionCallbacks();
      _discussionAttachments = [];
      _workAttachments = [];
      _replyTarget = null;
      _editingMessageId = null;
      _navigatingToReply = false;
      _replyHighlightTimer?.cancel();
      _replyHighlightId = null;
    }
    if (oldWidget.thread.id != widget.thread.id &&
        _threadViewStateRestored &&
        oldWidget.currentUserId != null &&
        oldWidget.currentUserId == widget.currentUserId) {
      _threadViewStateSaveTimer?.cancel();
      final leaving = _currentThreadViewState();
      unawaited(_threadViewStateStore.save(
        userId: oldWidget.currentUserId!,
        threadId: oldWidget.thread.id,
        state: leaving,
      ));
      // Persist the Cloud copy for the thread being left; otherwise the stale
      // Cloud metadata wins over the newer local copy when returning to it.
      _persistRemoteViewState(leaving, oldWidget);
    }
    if (oldWidget.thread.id != widget.thread.id ||
        oldWidget.space.id != widget.space.id ||
        oldWidget.currentUserId != widget.currentUserId) {
      // A data source swap alone (e.g. after a refresh re-creates the
      // session) keeps the same Thread and user, so the restored selection
      // stays; clearing it here would be saved back over the stored choice.
      _workExecutionSelection = {};
      _lastWorkerSelection = {};
      _reportedIssues.clear();
      _reportedIssueKeys.clear();
      _issueReportErrors.clear();
      _reportingIssueIds.clear();
      _checkedIssueReportKeys.clear();
      _issueReportLoads.clear();
    }
    if (oldWidget.workflowConfigurations != widget.workflowConfigurations ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.space.id != widget.space.id) {
      _cancelWorkflowConfigurations?.call();
      _subscribeWorkflowConfigurations();
    }
    if (oldWidget.catalogs != widget.catalogs ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.viewerEmail != widget.viewerEmail) {
      _subscribeCatalogs();
      unawaited(_loadWorkflowCatalog());
    }
    if (oldWidget.catalogs != widget.catalogs ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.space.id != widget.space.id) {
      _subscribeWorkflowWorkspace();
      unawaited(_loadWorkChoices());
    }
    var presentationSourcesChanged = false;
    if (oldWidget.dataSource != widget.dataSource ||
        oldWidget.discussionCache != widget.discussionCache) {
      _fallbackDiscussionCache = widget.discussionCache ??
          AxDiscussionCache.forSource(widget.dataSource);
      presentationSourcesChanged = true;
    }
    if (oldWidget.workHistoryCache != widget.workHistoryCache ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.thread.id != widget.thread.id) {
      _cancelWorkRealtime?.call();
      _fallbackWorkHistoryCache = widget.workHistoryCache ??
          AxWorkHistoryCache.forSource(widget.dataSource);
      _cancelWorkRealtime = AxWorkRealtimeSync.forCache(_workHistoryCache)
          .listen(widget.realtimeEvents, threadId: widget.thread.id);
      presentationSourcesChanged = true;
      unawaited(_refreshWorkTimeline());
    }
    if (threadChanged) {
      presentationSourcesChanged = true;
    }
    if (presentationSourcesChanged) _subscribeWorkHistory();
    if (oldWidget.thread.id != widget.thread.id) {
      _threadViewStateGeneration++;
      _threadViewStateRestored = false;
      _threadViewReady = false;
      _threadViewRevealScheduled = false;
      _pendingThreadViewState = null;
      _lastRemoteViewState = null;
      _composerInputHeight.reset();
      _discussionController.clear();
      _requestController.clear();
      _workExecutionSelection = {};
      _selectionUpdatedAt = null;
      _workflow = '';
      _followWork = _followChat = true;
      _chatSeenId = _workSeenId = null;
      _openChatPending = _openWorkPending = true;
      _chatPositioned = _workPositioned = false;
      // Each Thread reopens its own last pane; one never saved starts on the
      // default pane rather than inheriting the previous Thread's.
      _aiHistoryOpen = _aiHistoryMounted =
          widget.showAiHistory && widget.initialAiHistoryOpen;
      _notesOpen = _notesMounted = false;
      // Activity is keyed by assignment, so it is kept: returning to a Thread
      // shows its earlier operations immediately while details reload.
      _cancelTerminalActivityChecks();
      _restoreThreadViewState();
    } else if (oldWidget.currentUserId != widget.currentUserId) {
      _restoreThreadViewState();
    }
    if (oldWidget.initialTab != widget.initialTab) {
      final targetIndex =
          widget.initialTab == 2 ? 1 : widget.initialTab.clamp(0, 1);
      if (_tabController.index != targetIndex) {
        _tabController.index = targetIndex;
      }
    }
    if (oldWidget.realtimeEvents != widget.realtimeEvents) {
      _workEventSubscription?.cancel();
      _subscribeToWorkEvents();
    }
    // After the caches above are rebound to the new Thread.
    if (threadChanged || oldWidget.isDraft != widget.isDraft) {
      _watchReadStates();
    }
  }

  static const _terminalActivityTypes = {
    'execution.completed',
    'execution.failed',
    'execution.cancelled',
  };

  void _cancelTerminalActivityChecks() {
    for (final timer in _terminalActivityChecks.values) {
      timer.cancel();
    }
    _terminalActivityChecks.clear();
  }

  /// Worker activity can outrun the Work status events. When an execution
  /// reports a terminal activity, re-read the request once if it is still
  /// unfinished a moment later. This only triggers a sync; request status
  /// remains the authority for every terminal state.
  void _checkRequestAfterTerminalActivity(Map<String, dynamic> event) {
    final payload = event['payload'];
    if (payload is! Map ||
        !_terminalActivityTypes.contains(payload['activityType'])) {
      return;
    }
    final assignmentId = event['assignmentId'] ?? payload['entityId'];
    if (assignmentId is! String || assignmentId.isEmpty) return;
    if (_terminalActivityChecks.containsKey(assignmentId)) return;
    final threadId = widget.thread.id;
    _terminalActivityChecks[assignmentId] =
        Timer(const Duration(milliseconds: 1500), () {
      _terminalActivityChecks.remove(assignmentId);
      if (!mounted || widget.thread.id != threadId) return;
      final request = _workTimeline
          .where((r) =>
              AxWorkActivityStore.assignmentIdsFor(r).contains(assignmentId))
          .firstOrNull;
      if (request == null ||
          request.id.startsWith('local-') ||
          AxWorkProgress.terminalStatuses.contains(request.status)) {
        return;
      }
      unawaited(_workHistoryCache
          .refreshRequest(threadId, request.id)
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    });
  }

  void _subscribeToWorkEvents() {
    if (widget.isDraft) return;
    _cancelWorkRealtime?.call();
    _cancelWorkRealtime = AxWorkRealtimeSync.forCache(_workHistoryCache)
        .listen(widget.realtimeEvents, threadId: widget.thread.id);
    _workEventSubscription = widget.realtimeEvents?.listen((event) {
      if (_workActivityStore.handle(event, threadId: widget.thread.id)) {
        _checkRequestAfterTerminalActivity(event);
      }
      final type = event['type'];
      final payload = event['payload'];
      if ((type is String &&
          (type.startsWith('thread.discussion.') ||
              type.startsWith('thread.discussion.')) &&
          ((payload is Map &&
                  (payload['threadId'] == widget.thread.id ||
                      payload['threadId'] == widget.thread.id)) ||
              event['threadId'] == widget.thread.id ||
              event['threadId'] == widget.thread.id))) {
        unawaited(_discussionCache
            .synchronize(widget.thread.id, reconcileNewest: true)
            .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      }

      // Handle thread mutation events (archive, clear, rename)
      if (type is String &&
          payload is Map &&
          payload['threadId'] == widget.thread.id) {
        if (type == 'thread.queue_updated') {
          // A member changed the shared queue, or Cloud sent its next request.
          _loadSharedQueue();
        } else if (type == 'thread.archived') {
          // Thread was archived by another user or session
          _handleThreadArchived(Map<String, dynamic>.from(payload));
        } else if (type == 'thread.chat_cleared') {
          // The Conversation was cleared by another session: Chat and all
          // Work are gone. Drop retained data, then reconcile.
          _discussionCache.resetHistory(widget.thread.id);
          _workHistoryCache.resetHistory(widget.thread.id);
          unawaited(_discussionCache
              .synchronize(widget.thread.id, reconcileNewest: true)
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
          unawaited(_refreshWorkTimeline()
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
        } else if (type == 'thread.work_cleared') {
          // Metadata and read-state updates do not change conversation history.
          unawaited(_discussionCache
              .synchronize(widget.thread.id)
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
          // AI History moved its cutoff; Work itself is kept, so refreshing
          // brings the new cutoff without discarding the Conversation.
          unawaited(_refreshWorkTimeline()
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
        }
      }
    });
  }

  bool get _canExecute =>
      !widget.thread.archived &&
      widget.thread.status != 'archived' &&
      (widget.isDraft
          ? widget.space.effectivePermissions.work &&
              widget.space.effectivePermissions.manageOwnThreads
          : (widget.space.role == 'owner' || widget.thread.canExecuteWork)) &&
      _effectiveWorkflow.isNotEmpty;
  @override
  void dispose() {
    _cancelReadStates?.call();
    _releaseWorkQueue(widget);
    _invalidateInteractionCallbacks();
    AxRenderDiagnostics.instance.updateContext(
      component: 'ThreadPage',
      mounted: false,
      disposed: true,
    );
    _workerUsage.dispose();
    _cancelWorkflowConfigurations?.call();
    _cancelWorkflowDefault?.call();
    _cancelWorkflows?.call();
    _cancelWorkers?.call();
    _cancelWorkflowWorkspace?.call();
    _cancelWorkRealtime?.call();
    _workEventSubscription?.cancel();
    _cancelTerminalActivityChecks();
    _threadViewStateSaveTimer?.cancel();
    unawaited(_saveThreadViewState());
    _tabController.dispose();
    _presentation.chat.removeListener(_onChatPresentationChanged);
    _presentation.work.removeListener(_onWorkPresentationChanged);
    _workActivityStore.removeListener(_onWorkActivityChanged);
    _workActivityStore.dispose();
    _requestController.removeListener(_scheduleThreadViewStateSave);
    _discussionController.removeListener(_scheduleThreadViewStateSave);
    _workHistoryController.removeListener(_onWorkHistoryScroll);
    _chatHistoryController.removeListener(_onChatHistoryScroll);
    _tabController.removeListener(_onThreadTabChanged);
    _replyHighlightTimer?.cancel();
    _requestController.dispose();
    _workHistoryController.dispose();
    _chatHistoryController.dispose();
    _composerInputHeight.dispose();
    _discussionController.dispose();
    _discussionFocus.dispose();
    _presentation.dispose();
    super.dispose();
  }

  void _updateComposerState(VoidCallback callback) {
    callback();
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'ThreadPage',
      operation: 'work.composer.changed',
    );
    _presentation.markComposerChanged();
  }

  void _updateIssueState(VoidCallback callback) {
    callback();
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'ThreadPage',
      operation: 'work.issue.changed',
    );
    _presentation.markWorkChanged();
    _presentation.markComposerChanged();
  }

  void _updateState(VoidCallback callback) {
    if (widget.isDraft) {
      setState(callback);
      return;
    }
    callback();
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'ThreadPage',
      operation: 'thread.state.changed',
    );
    _presentation.markWorkChanged();
    _presentation.markComposerChanged();
  }

  @override
  Widget build(BuildContext context) => AttachmentDownloadScope(
        load: (file) async {
          final source = widget.dataSource;
          if (source == null) {
            throw StateError('File downloads are unavailable');
          }
          return source.downloadThreadFile(
              widget.thread.id, file['fileId'] as String);
        },
        download: (file, bytes) async => work_request_files.saveThreadFile(
            bytes, file['name']?.toString() ?? 'Attachment'),
        child: _buildThread(context),
      );

  Widget _buildThread(BuildContext context) {
    AxRenderDiagnostics.instance.widgetRebuild(
      component: 'ThreadPage',
      threadId: widget.thread.id,
      tab: _tabController.index == 1 ? 'work' : 'chat',
    );
    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
        if (_threadViewStateRestored &&
            _paneAwaitingReveal == null &&
            !_threadViewReady &&
            !_threadViewRevealScheduled) {
          _threadViewRevealScheduled = true;
          final generation = _interactionGeneration;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || generation != _interactionGeneration) return;
            // Let the hidden first frame attach both scroll controllers and
            // settle at the saved position before revealing the new Thread.
            setState(() {
              _threadViewReady = true;
              _threadViewRevealScheduled = false;
            });
          });
        }
        final notesOpen = !widget.isDraft && _notesOpen && _notesSource != null;
        final historyOpen = !widget.isDraft && _aiHistoryOpen && !notesOpen;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        // Tab strip: the active tab gets an accent underline that sits on the
        // header divider; inactive tabs stay transparent so nothing shifts.
        Widget tab(bool active, Widget button) => Semantics(
              selected: active,
              container: true,
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: button,
              ),
            );
        Widget header(String title,
                {required bool history, bool notes = false}) =>
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 46,
                  child: Row(children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          tab(
                              !history && !notes,
                              TextButton(
                                key: ValueKey(history
                                    ? 'ai-history-conversation'
                                    : notes
                                        ? 'notes-conversation'
                                        : 'conversation-tab'),
                                onPressed: () {
                                  _setNotesOpen(false);
                                  _setAiHistoryOpen(false);
                                },
                                style: TextButton.styleFrom(
                                  foregroundColor:
                                      SyntilaColors.textPrimary(isDark),
                                  textStyle: TextStyle(
                                    fontWeight: !history && !notes
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                child: const Text('Conversation'),
                              )),
                          if (!widget.isDraft && widget.showAiHistory)
                            tab(
                                history,
                                TextButton(
                                  key: ValueKey(history
                                      ? 'ai-history-tab'
                                      : notes
                                          ? 'notes-ai-history'
                                          : 'ai-history-toggle'),
                                  onPressed: () {
                                    _setNotesOpen(false);
                                    _setAiHistoryOpen(true);
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        SyntilaColors.textPrimary(isDark),
                                    textStyle: TextStyle(
                                      fontWeight: history
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                  child: const Text('AI History'),
                                )),
                          if (!widget.isDraft && _notesSource != null)
                            tab(
                                notes,
                                TextButton(
                                  key: ValueKey(notes
                                      ? 'notes-tab'
                                      : history
                                          ? 'ai-history-notes'
                                          : 'notes-toggle'),
                                  onPressed: () => _setNotesOpen(true),
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        SyntilaColors.textPrimary(isDark),
                                    textStyle: TextStyle(
                                      fontWeight: notes
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                  child: const Text('Notes'),
                                )),
                        ]),
                      ),
                    ),
                    if (!widget.isDraft &&
                        !notes &&
                        widget.onClearAiHistory != null)
                      IconButton(
                        key: const ValueKey('reset-ai-context'),
                        tooltip: 'Reset AI context',
                        icon: const Icon(Icons.restart_alt, size: 18),
                        onPressed: () => _confirmClear(history: true),
                      ),
                    if (!widget.isDraft &&
                        (notes ||
                            (!history && widget.onClearConversation != null)))
                      IconButton(
                        key: ValueKey(notes
                            ? 'clear-note'
                            : 'clear-conversation-history'),
                        tooltip:
                            notes ? 'Clear Note' : 'Clear Conversation History',
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        onPressed: notes
                            ? _confirmClearNote
                            : () => _confirmClear(history: false),
                      ),
                  ]),
                ),
                const Divider(height: 1, thickness: 1),
                const SizedBox(height: 16),
              ],
            );
        Widget pane(String name, Widget content,
                {bool history = false, bool notes = false}) =>
            Padding(
                key: ValueKey('thread-$name-padding'),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  key: ValueKey('thread-$name-pane'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header(name, history: history, notes: notes),
                    if (widget.isDraft) content else Expanded(child: content),
                  ],
                ));
        final conversation = pane('Conversation',
            _discuss(context, twoPane: constraints.maxWidth >= 1000));
        final Widget content = Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: widget.isDraft
              ? conversation
              : IndexedStack(
                  key: const ValueKey('thread-panes'),
                  index: notesOpen
                      ? 2
                      : historyOpen
                          ? 1
                          : 0,
                  sizing: StackFit.expand,
                  children: [
                    conversation,
                    if (_aiHistoryMounted || historyOpen)
                      pane('AI History', _work(context), history: true)
                    else
                      const SizedBox.shrink(),
                    if (_notesMounted || notesOpen)
                      pane('Notes', _notes(), notes: true)
                    else
                      const SizedBox.shrink(),
                  ],
                ),
        ));
        return IgnorePointer(
          ignoring: !_threadViewReady,
          child: ExcludeSemantics(
            excluding: !_threadViewReady,
            child: Opacity(
              key: const ValueKey('thread-view-visibility'),
              opacity: _threadViewReady ? 1 : 0,
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: _onTimelineMetricsChanged,
                child: _ReplyNavigation(
                    navigate: _navigateToReply, child: content),
              ),
            ),
          ),
        );
      }),
    );
  }

  int _replyNavigationGeneration = 0;

  Future<void> _navigateToReply(AxReplyReference reference) async {
    final generation = ++_replyNavigationGeneration;
    final threadId = widget.thread.id;
    bool current() =>
        mounted &&
        widget.thread.id == threadId &&
        generation == _replyNavigationGeneration;
    final target = reference.kind == 'message'
        ? reference.id
        : 'work-${reference.id}-${reference.kind == 'response' ? 'answer' : 'request'}';
    _followChat = false;
    _chatIncomingAnchor.reset();
    _setNotesOpen(false);
    _setAiHistoryOpen(false);
    _updateState(() => _navigatingToReply = true);
    try {
      while (current() && !_conversationIds().contains(target)) {
        final cursor = reference.kind == 'message'
            ? _chatPresentation.olderCursor
            : _workPresentation.olderCursor;
        if (cursor == null) break;
        if (reference.kind == 'message') {
          await _loadOlderDiscussion();
        } else {
          await _loadOlderWorkHistory();
        }
        if (!current()) return;
        final next = reference.kind == 'message'
            ? _chatPresentation.olderCursor
            : _workPresentation.olderCursor;
        if (next == cursor) break;
      }
      if (!current() || !mounted) return;
      final ids = _conversationIds();
      final index = ids.indexOf(target);
      if (index < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Original message unavailable')));
        return;
      }
      // Wait for tab switching and prepended history to finish layout.
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) return;
      _openChatPending = false;
      _chatIncomingAnchor.anchorAt(target,
          fraction: ids.length < 2 ? 0 : index / (ids.length - 1));
      for (var attempt = 0; attempt < 30 && current(); attempt++) {
        if (!_chatHistoryController.hasClients) return;
        if (!_chatIncomingAnchor.reveal(_chatHistoryController)) return;
        await WidgetsBinding.instance.endOfFrame;
      }
      if (current()) {
        _chatIncomingAnchor.reset();
        _replyHighlightTimer?.cancel();
        _replyHighlightId = target;
        _replyHighlightTimer = Timer(const Duration(milliseconds: 1200), () {
          if (mounted && _replyHighlightId == target) {
            _updateState(() => _replyHighlightId = null);
          }
        });
      }
    } finally {
      if (current() && _navigatingToReply) {
        _updateState(() => _navigatingToReply = false);
      }
    }
  }

  Widget _notes() {
    final source = _notesSource!;
    final threadId = widget.thread.id;
    return NoteEditor(
      key: ValueKey('thread-note-$threadId'),
      controller: _noteEditorController,
      load: () => source.loadThreadNote(threadId),
      save: ({required title, required body, revision}) =>
          source.saveThreadNote(threadId, body: body, revision: revision),
    );
  }

  Widget _discuss(BuildContext context, {bool twoPane = false}) =>
      ListenableBuilder(
        key: const ValueKey('conversation-timeline'),
        listenable: Listenable.merge(
            [_presentation.chat, _presentation.work, _workRealtime]),
        builder: (context, _) => _discussionBody(
          context,
          _presentation.chat.value ?? _chatPresentation,
          twoPane: twoPane,
        ),
      );

  // Rebuilt only when messages, Work requests or the viewer change, not on
  // every realtime activity tick or follow/reveal pass.
  (
    Object,
    Object,
    String?,
    String?,
    bool,
    List<_DiscussionItem>
  )? _conversationCache;

  List<_DiscussionItem> _conversationItems(
      ThreadChatPresentationSnapshot state) {
    final cached = _conversationCache;
    final requests = _workTimeline;
    if (cached != null &&
        identical(cached.$1, state) &&
        identical(cached.$2, requests) &&
        cached.$3 == widget.currentUserId &&
        cached.$4 == widget.currentUserName &&
        cached.$5 == widget.isDraft) {
      return cached.$6;
    }
    final items = state.messages.map((message) {
      final isMe =
          widget.currentUserId != null && widget.currentUserId!.isNotEmpty
              ? message.authorUserId == widget.currentUserId
              : message.isMe;
      final date = DateTime.tryParse(message.createdAt)?.toLocal();
      final edited = DateTime.tryParse(message.editedAt ?? '')?.toLocal();
      final rawAuthor = isMe ? 'You' : (message.authorName?.trim() ?? '');
      final displayAuthor = (rawAuthor.isEmpty ||
              rawAuthor == message.authorUserId ||
              rawAuthor.startsWith('usr_'))
          ? (isMe ? 'You' : 'Member')
          : rawAuthor;
      // An archived AI answer is the Worker speaking, not its requester.
      final worker = message.workerDisplayName?.trim();
      final answer = message.isAiAnswer;
      return _DiscussionItem(
          id: message.id,
          author: answer
              ? (worker == null || worker.isEmpty ? 'AI' : worker)
              : displayAuthor,
          authorId: answer
              ? 'ai:${message.workRequestId ?? message.id}'
              : message.authorUserId,
          date: date,
          text: message.body,
          attachments: message.attachments,
          eventType: message.eventType,
          sentAt: date == null ? null : _chatTimestamp(date),
          editedAt: edited == null ? null : _chatTimestamp(edited),
          editedDate: edited,
          isMe: isMe && !answer,
          replyTo: message.replyTo,
          aiKind: message.isAiEntry ? message.kind : null);
    }).toList();
    if (!widget.isDraft) _mergeWorkIntoConversation(items);
    _conversationCache = (
      state,
      requests,
      widget.currentUserId,
      widget.currentUserName,
      widget.isDraft,
      items
    );
    return items;
  }

  Widget _discussionBody(
      BuildContext context, ThreadChatPresentationSnapshot state,
      {bool twoPane = false}) {
    final messages = _conversationItems(state);
    final lastOwnIndex = messages.lastIndexWhere((message) =>
        message.isMe && message.workRequest == null && message.aiKind == null);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showEmpty = messages.isEmpty &&
        state.error == null &&
        (!state.isFetching || state.hasData);
    final empty = showEmpty
        ? Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 42,
                  color: SyntilaColors.neutral,
                ),
                const SizedBox(height: 12),
                Text(
                  'No chat messages yet',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: SyntilaColors.textSecondary(isDark),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Share context, decisions, or questions with your team below.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: SyntilaColors.neutral,
                  ),
                ),
              ],
            ),
          )
        : null;

    if (widget.isDraft) return _conversationComposer(twoPane: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
            child: TimelineScrollOverlay(
                key: ValueKey('chat-scroll-overlay-${widget.thread.id}'),
                controller: _chatHistoryController,
                onFollowLatest: () {
                  _chatIncomingAnchor.reset();
                  _followChat = true;
                },
                child: Opacity(
                    opacity: _navigatingToReply ? 0 : 1,
                    child: AxTimelineContainer(
                      scrollKey: const ValueKey('chat-history-scroll'),
                      controller: _chatHistoryController,
                      headerSlivers: [
                        if (state.olderCursor != null)
                          SliverToBoxAdapter(
                            child: TextButton(
                              onPressed: state.loadingOlder
                                  ? null
                                  : _loadOlderDiscussion,
                              child: Text(state.loadingOlder
                                  ? 'Loading older messages…'
                                  : 'Load older messages'),
                            ),
                          ),
                        if (state.error != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              child: Text.rich(
                                TextSpan(
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    fontSize: 13,
                                  ),
                                  children: [
                                    TextSpan(
                                        text:
                                            'Chat could not synchronize: ${state.error}  '),
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: Semantics(
                                        link: true,
                                        child: InkWell(
                                          onTap: () => _discussionCache
                                              .synchronize(widget.thread.id)
                                              .then<void>((_) {},
                                                  onError: (Object _,
                                                      StackTrace __) {}),
                                          child: Text(
                                            'Retry Chat sync',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .error,
                                              decoration:
                                                  TextDecoration.underline,
                                              decorationColor: Theme.of(context)
                                                  .colorScheme
                                                  .error,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const TextSpan(text: ' '),
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: IconButton(
                                        tooltip: 'Copy Chat error',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                            minWidth: 24, minHeight: 24),
                                        visualDensity: VisualDensity.compact,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        icon: const Icon(Icons.copy_rounded,
                                            size: 14),
                                        onPressed: () => Clipboard.setData(
                                          ClipboardData(
                                              text:
                                                  'Chat could not synchronize: ${state.error}'),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (!state.hasData && state.isFetching)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('Loading Chat…'),
                            ),
                          ),
                      ],
                      itemCount: messages.length,
                      itemId: (index) => messages[index].id,
                      empty: empty,
                      separatorBuilder: (_, index) => SizedBox(
                        height: messageAuthorSpacing(
                          messages[index + 1].authorId,
                          messages[index].trailingAuthorId,
                        ),
                      ),
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<String>) return null;
                        final index = messages
                            .indexWhere((message) => message.id == key.value);
                        return index < 0 ? null : index;
                      },
                      itemBuilder: (context, index) {
                        final message = messages[index];
                        final isHighlighted = _replyHighlightId == message.id;
                        final rowContent = MessageDayBoundary(
                          date: message.date,
                          previousDate:
                              index == 0 ? null : messages[index - 1].date,
                          child: message.workRequest != null
                              ? _conversationWorkCard(
                                  context, message.workRequest!)
                              : _DiscussionMessageBubble(
                                  item: message,
                                  editing: _editingMessageId == message.id,
                                  grouped: _continuesDiscussionGroup(
                                      messages, index,
                                      breakAt: _firstUnreadChatId),
                                  onCopy: () {
                                    Clipboard.setData(
                                        ClipboardData(text: message.text));
                                  },
                                  onReply: message.eventType == null &&
                                          !widget.isDraft &&
                                          widget.space.effectivePermissions.chat
                                      ? () => _startReply(AxReplyReference(
                                            kind: 'message',
                                            id: message.id,
                                            authorName: message.author,
                                            excerpt: replyExcerpt(
                                                message.text.trim().isEmpty
                                                    ? attachmentsLabel(
                                                        message.attachments)
                                                    : message.text),
                                          ))
                                      : null,
                                  onEdit: () => _startEditMessage(message.id),
                                  onDelete: (message.isMe ||
                                              widget.space.role == 'owner') &&
                                          message.eventType == null
                                      ? () => _deleteDiscussion(message.id)
                                      : null,
                                ),
                        );
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;
                        final highlightDecoration = BoxDecoration(
                          color: isHighlighted
                              ? SyntilaColors.primarySoftColor(isDark)
                                  .withValues(alpha: isDark ? 0.35 : 0.45)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        );
                        final seenBy = index == lastOwnIndex
                            ? _seenBy(message.date)
                            : null;
                        return KeyedSubtree(
                          key: ValueKey(message.id),
                          child: KeyedSubtree(
                            key: _chatIncomingAnchor.keyFor(message.id),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut,
                              decoration: highlightDecoration,
                              child: seenBy == null
                                  ? rowContent
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [rowContent, seenBy]),
                            ),
                          ),
                        );
                      },
                    )))),
        const SizedBox(height: 16),
        _conversationComposer(twoPane: twoPane),
      ],
    );
  }

  Widget _conversationWorkCard(BuildContext context, AxWorkRequest request) {
    final cutoff = DateTime.tryParse(
        _workHistoryCache.aiHistoryClearedAt(widget.thread.id) ?? '');
    final created = DateTime.tryParse(request.createdAt);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (cutoff != null && created != null && !created.isAfter(cutoff))
        Text('Requested before AI context reset',
            style: TextStyle(
                fontSize: 12,
                color: SyntilaColors.textSecondary(
                    Theme.of(context).brightness == Brightness.dark))),
      _workComposer().requestCard(context, request,
          responseAnchorKey:
              _chatIncomingAnchor.keyFor('work-${request.id}-answer')),
    ]);
  }

  /// One conversation: Work Requests still in Work history appear between
  /// Chat messages by request time, each followed by its answer or status.
  void _mergeWorkIntoConversation(List<_DiscussionItem> messages) {
    final requests = _workTimeline;
    if (requests.isEmpty) return;
    final groups = <(DateTime?, List<_DiscussionItem>)>[
      for (final message in messages) (message.date, [message]),
      for (final request in requests)
        (
          DateTime.tryParse(request.createdAt)?.toLocal(),
          [
            _workConversationItem(request,
                currentUserId: widget.currentUserId,
                currentUserName: widget.currentUserName)
          ],
        ),
    ];
    final indexed = groups.indexed.toList()..sort(_byConversationTime);
    messages
      ..clear()
      ..addAll(indexed.expand((entry) => entry.$2.$2));
  }

  /// Message / Ask AI switch stacked in the composer's 32px left rail.
  Widget _composerModeControls() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Indicate the active mode with icon color only in both themes.
    final selectedForeground = dark
        ? SyntilaColors.focusBorderDark
        : SyntilaColors.primaryForegroundLight;
    Widget toggle(bool askAi, String tooltip, IconData icon) {
      final selected = _askAiMode == askAi;
      return IconButton(
        key: ValueKey('composer-mode-${askAi ? 'ai' : 'message'}'),
        tooltip: tooltip,
        isSelected: selected,
        onPressed: selected
            ? null
            : () => _updateState(() => _tabController.index = askAi ? 1 : 0),
        padding: EdgeInsets.zero,
        constraints: composerButtonConstraints,
        style: composerIconButtonStyle(),
        icon: Icon(icon,
            semanticLabel: tooltip,
            size: composerIconSize,
            color: selected
                ? selectedForeground
                : Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }

    return Semantics(
      key: const ValueKey('conversation-composer-mode'),
      container: true,
      label: _askAiMode ? 'Ask AI mode' : 'Message mode',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          toggle(false, 'Message', Icons.chat_bubble_outline_rounded),
          const SizedBox(height: 4),
          toggle(true, 'Ask AI', Icons.auto_awesome_rounded),
        ],
      ),
    );
  }

  Widget _conversationComposer({bool twoPane = false}) =>
      widget.thread.archived || widget.thread.status == 'archived'
          ? Center(
              child: TextButton.icon(
              onPressed: widget.onRestore,
              icon: const Icon(Icons.unarchive_outlined),
              label: const Text('Restore thread'),
            ))
          : _askAiMode
              ? ValueListenableBuilder<ThreadComposerPresentationSnapshot>(
                  valueListenable: _presentation.composer,
                  builder: (context, _, __) =>
                      _workComposer().controls(context))
              : _discussionComposer(twoPane: twoPane);

  Widget _discussionComposer({bool twoPane = false}) => MarkdownComposer(
        attachments: _editingMessageId != null
            ? _EditComposerBanner(
                excerpt: replyExcerpt(_editingOriginalText),
                onCancel: _cancelEditMessage)
            : _composerExtras(
                reply: _replyTarget,
                onClearReply: _clearReply,
                files: _discussionAttachments,
                onRemoveFile: (index) =>
                    _updateState(() => _discussionAttachments.removeAt(index))),
        focusNode: _discussionFocus,
        onCancel: _editingMessageId != null ? _cancelEditMessage : null,
        sendIcon: _editingMessageId != null
            ? Icons.check_rounded
            : Icons.send_rounded,
        sendTooltip:
            _editingMessageId != null ? 'Save changes' : 'Send message',
        toolbarLeadingControls: widget.isDraft || _editingMessageId != null
            ? null
            : Align(
                widthFactor: 1,
                alignment: Alignment.centerLeft,
                child: Builder(
                  builder: (buttonContext) => IconButton(
                    key: const ValueKey('message-add-attachments'),
                    tooltip: 'Add attachments',
                    icon: const Icon(Icons.add, size: composerIconSize),
                    padding: EdgeInsets.zero,
                    constraints: composerButtonConstraints,
                    style: composerIconButtonStyle(),
                    onPressed: () async {
                      final value = await _showAnchoredMenu<String>(
                        buttonContext: buttonContext,
                        itemHeight: 36,
                        items: [
                          SyntilaMenuEntry<String>(
                            value: 'files',
                            child: MenuItemButton(
                              style: SyntilaMenuStyle.item(
                                  Theme.of(context).brightness ==
                                      Brightness.dark),
                              leadingIcon:
                                  const Icon(Icons.attach_file, size: 16),
                              onPressed: widget
                                          .space.effectivePermissions.chat &&
                                      !widget.draftBusy &&
                                      !_draftSubmitting
                                  ? () => Navigator.pop(buttonContext, 'files')
                                  : null,
                              child: const Text('Add files',
                                  style: SyntilaMenuStyle.textStyle),
                            ),
                          ),
                        ],
                      );
                      if (!buttonContext.mounted || value != 'files') return;
                      await _pickDiscussionFiles();
                    },
                  ),
                )),
        leadingControls: _composerModeControls(),
        inputHeight: _composerInputHeight,
        showControlTooltips: false,
        controller: _discussionController,
        hintText: _editingMessageId != null
            ? 'Edit message...'
            : 'Write a message...',
        chatStyle: true,
        enabled: !widget.draftBusy &&
            widget.space.effectivePermissions.chat &&
            (!widget.isDraft ||
                widget.space.effectivePermissions.manageOwnThreads),
        onSend: _sendDiscussion,
        sendEnabled: !_draftSubmitting && !widget.draftBusy,
        twoRowLayout: true,
        maxLines: 6,
      );

  Widget _work(BuildContext context) => widget.isDraft
      ? ValueListenableBuilder<ThreadComposerPresentationSnapshot>(
          valueListenable: _presentation.composer,
          builder: (context, _, __) => _workComposer().controls(context))
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
                child: TimelineScrollOverlay(
                    key: ValueKey('work-scroll-overlay-${widget.thread.id}'),
                    controller: _workHistoryController,
                    onFollowLatest: () {
                      _workIncomingAnchor.reset();
                      _followWork = true;
                    },
                    child: ListenableBuilder(
                        listenable: _workRealtime,
                        builder: (context, _) => ValueListenableBuilder<
                                ThreadWorkPresentationSnapshot?>(
                            valueListenable: _presentation.work,
                            builder: (context, snapshot, _) {
                              return _workComposer().history(context);
                            })))),
          ],
        );

  _WorkComposer _workComposer() => _WorkComposer(
        leadingControls: _composerModeControls(),
        inputHeight: _composerInputHeight,
        requestController: _requestController,
        historyController: _workHistoryController,
        incomingAnchor: _workIncomingAnchor,
        currentUserId: widget.currentUserId,
        currentUserName: widget.currentUserName,
        workflow: _effectiveWorkflow,
        workflowCatalog: _availableWorkflows,
        workConfig: _composerWorkConfig,
        spaceWorkers: _composerWorkers,
        eligibleWorkers: _composerEligibleWorkers,
        loadingWorkflows: _loadingWorkflows,
        workflowCatalogError: _workflowCatalogError,
        canExecute: _canExecute,
        workTimeline: _aiHistoryTimeline,
        historyResponseOverrides: _historyResponseOverrides,
        onToggleHistoryResponse: (id, open) =>
            setState(() => _historyResponseOverrides[id] = open),
        activityStore: _workActivityStore,
        realtimeStatus: _workRealtime.displayStatus,
        localWorkProgress: _localWorkProgress,
        loadingTimeline: _loadingWorkTimeline,
        timelineError: _workTimelineError,
        submitError: _workSubmitError,
        submitting: _submittingWork,
        attachments: _workAttachments,
        replyTarget: _replyTarget,
        onReply: _startReply,
        onClearReply: _clearReply,
        onAddFiles: _addWorkFiles,
        executionSelection: _workExecutionSelection,
        onExecutionSelectionChanged: (selection) {
          _updateState(() {
            _markSelectionChangedByUser();
            if (_workSelectionMissing) {
              _workSelectionMissing = false;
              _workSubmitError = null;
            }
            _workExecutionSelection = {
              ..._workExecutionSelection,
              ...selection
            };
          });
          _scheduleThreadViewStateSave();
        },
        onRemoveAttachment: (index) => _updateState(() {
          _workAttachments.removeAt(index);
        }),
        hasOlder: _workPresentation.olderCursor != null,
        loadingOlder: _workPresentation.loadingOlder,
        onLoadOlder: _loadOlderWorkHistory,
        onReportIssue: widget.dataSource == null ? null : _reportIssue,
        reportedIssues: _reportedIssues,
        reportingIssueIds: _reportingIssueIds,
        issueReportErrors: _issueReportErrors,
        onRetryStep: widget.dataSource == null ? null : _retryWorkRequestStep,
        onCancelRun: widget.dataSource == null ? null : _cancelWorkRequest,
        onHistoryNavigate: _openRequestHistory,
        historyPrompts: _requestHistoryOpen ? _requestHistoryPrompts : null,
        historyOpenDirection: _requestHistoryDirection,
        queuedMessages: widget.isDraft ? const [] : List.of(_workQueue),
        queuePause: _workQueuePause,
        onQueuePauseChanged: (paused) => _setWorkQueuePaused(paused),
        onQueuedEdit: _editQueuedWork,
        onQueuedRemove: _removeQueuedWork,
        onQueuedSendNow: (message) => unawaited(_sendQueuedWorkNow(message)),
        onHistorySelected: _selectHistoryPrompt,
        onHistoryClosed: _closeRequestHistory,
        onWorkflowChanged: (value) {
          _updateState(() {
            _markSelectionChangedByUser();
            _workflow = value;
            // Keep the last Worker, model and effort across Chat/Work so the
            // shared Thread conversation can reuse its Worker Session. Fall
            // back to the Workflow binding only when it fixes the Worker.
            final policy = _availableWorkflows
                .where((item) => item.reference == value)
                .firstOrNull
                ?.executionPolicy;
            // Own Workers answer only Chat; leaving Chat drops them.
            if (_workExecutionSelection.containsKey('workerId')) {
              _lastWorkerSelection = Map.of(_workExecutionSelection);
            }
            final source = _lastWorkerSelection;
            final keepsWorker = value.split(':').first == 'chat' ||
                !_ownChatWorkers.any((w) => w.id == source['workerId']);
            final kept = <String, dynamic>{
              if (policy?.userSelectsWorker == true && keepsWorker) ...{
                if (source.containsKey('workerId'))
                  'workerId': source['workerId'],
                if (source.containsKey('catalogRevision'))
                  'catalogRevision': source['catalogRevision'],
                if (policy!.userSelectsModel && source.containsKey('model'))
                  'model': source['model'],
                if (policy.userSelectsEffort &&
                    source.containsKey('reasoningEffort'))
                  'reasoningEffort': source['reasoningEffort'],
              },
            };
            _workExecutionSelection = kept;
          });
          _scheduleThreadViewStateSave();
        },
        onRun: _runWork,
        selectionMissing: _workSelectionMissing,
        onSelectionMissing: (message) => _updateState(() {
          _workSelectionMissing = true;
          _workSubmitError = message;
        }),
        usageController: _workerUsage,
      );
}
