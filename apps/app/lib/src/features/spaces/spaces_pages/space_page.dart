part of '../spaces_pages.dart';

enum SpacePageSection { threads, members }

class SpacePage extends StatelessWidget {
  const SpacePage({
    super.key,
    required this.space,
    required this.dataSource,
    required this.onOpenThread,
    this.onSaveEdits,
    required this.onArchive,
    required this.onDelete,
    this.onSpaceUpdated,
    this.section = SpacePageSection.threads,
    this.embedded = false,
    this.spaceThreads,
    this.tabQueries,
    this.mutations,
    this.viewerEmail,
    this.workflowConfigurations,
  });

  /// Space-scoped workflow preferences; used for the Workspace selector. When
  /// omitted one is created from [dataSource] if it supports Workspace choice.
  final AxWorkflowConfigurations? workflowConfigurations;
  final AxSpace space;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenThread;

  /// Saves an inline edit of name and description. Returns an error to show
  /// under the form, or null on success. Without it the page saves directly.
  final Future<String?> Function(
      String name, String description, String? color)? onSaveEdits;

  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxSpace>? onSpaceUpdated;
  final SpacePageSection section;
  final bool embedded;
  final AxSpaceThreads? spaceThreads;
  final AxSpaceTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;
  final String? viewerEmail;

  @override
  Widget build(BuildContext context) => _SpaceWorkspace(
        key: ValueKey(space.id),
        space: space,
        dataSource: dataSource,
        onOpenThread: onOpenThread,
        onSaveEdits: onSaveEdits,
        onArchive: onArchive,
        onDelete: onDelete,
        onSpaceUpdated: onSpaceUpdated,
        section: section,
        embedded: embedded,
        spaceThreads: spaceThreads,
        tabQueries: tabQueries,
        mutations: mutations,
        viewerEmail: viewerEmail,
        workflowConfigurations: workflowConfigurations,
      );
}

class _SpaceWorkspace extends StatefulWidget {
  const _SpaceWorkspace({
    super.key,
    required this.space,
    required this.dataSource,
    required this.onOpenThread,
    this.onSaveEdits,
    required this.onArchive,
    required this.onDelete,
    this.onSpaceUpdated,
    this.section = SpacePageSection.threads,
    this.embedded = false,
    this.spaceThreads,
    this.tabQueries,
    this.mutations,
    this.viewerEmail,
    this.workflowConfigurations,
  });

  final AxWorkflowConfigurations? workflowConfigurations;
  final AxSpace space;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenThread;

  /// Saves an inline edit of name and description. Returns an error to show
  /// under the form, or null on success. Without it the page saves directly.
  final Future<String?> Function(
      String name, String description, String? color)? onSaveEdits;

  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxSpace>? onSpaceUpdated;
  final SpacePageSection section;
  final bool embedded;
  final AxSpaceThreads? spaceThreads;
  final AxSpaceTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;
  final String? viewerEmail;

  @override
  State<_SpaceWorkspace> createState() => _SpaceWorkspaceState();
}

class _SpaceWorkspaceState extends State<_SpaceWorkspace> {
  late List<AxThread> threads;
  List<AxSpaceMember> members = const [];
  List<AxSpaceInvitation> invitations = const [];
  bool threadsLoading = true;
  bool membersLoading = true;
  Object? threadsError;
  Object? membersError;
  late AxSpaceTabQueries _queries;
  late AxPeople _people;
  late AxSpaceThreads _streams;
  late AxCollaborationMutations _collaboration;
  AxWorkflowConfigurations? _workflows;
  final _tabCancels = <void Function()>[];
  bool get canManage => widget.space.effectivePermissions.manageOwnThreads;
  bool get canInvite => widget.space.role == 'owner';
  final _savingMembers = <String>{};
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  String? _editColor;
  bool _editing = false;
  bool _showArchivedThreads = false;
  bool _savingEdits = false;
  String? _editError;
  bool get isOwner => widget.space.role == 'owner';

  @override
  void initState() {
    super.initState();
    _configureQueries();
    _bindActiveSection();
  }

  void _configureQueries() {
    _queries =
        widget.tabQueries ?? AxSpaceTabQueries.forSource(widget.dataSource);
    _streams = widget.spaceThreads ?? _queries.threads;
    _collaboration = widget.mutations ??
        AxCollaborationMutations(widget.dataSource, engine: _streams.engine);
    _people = AxPeople(widget.dataSource, engine: _streams.engine);
    if (widget.dataSource is AxPeopleDataSource) {
      unawaited(_people
          .ensure()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    }
    threads = _streams.peek(widget.space.id);
    _workflows = widget.workflowConfigurations ??
        (widget.dataSource is AxWorkflowWorkspaceDataSource
            ? AxWorkflowConfigurations(widget.dataSource,
                engine: _streams.engine, spaceId: widget.space.id)
            : null);
  }

  void _cancelTab() {
    for (final cancel in _tabCancels) {
      cancel();
    }
    _tabCancels.clear();
  }

  void _ensure<T>(AxSyncEngine engine, AxQuery<T> query) {
    unawaited(engine
        .ensure(query)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  void _bindActiveSection() {
    _cancelTab();
    final id = widget.space.id;
    if (widget.section == SpacePageSection.threads) {
      final query = _streams.query(id);
      void apply(AxQueryState<List<AxThread>> state) {
        threads = state.data ?? const [];
        threadsLoading = !state.hasData && state.isFetching;
        threadsError = state.error;
      }

      apply(_streams.engine.peek(query));
      _tabCancels.add(_streams.engine.watch(query, (state) {
        if (mounted) _updateState(() => apply(state));
      }, fireImmediately: false));
      _ensure(_streams.engine, query);
    } else if (widget.section == SpacePageSection.members) {
      final membersQuery = _queries.members(id);
      final invitationsQuery = _queries.invitations(id);
      void apply() {
        final memberState = _queries.engine.peek(membersQuery);
        final invitationState = _queries.engine.peek(invitationsQuery);
        members = memberState.data ?? const [];
        invitations = invitationState.data ?? const [];
        membersLoading = !memberState.hasData && memberState.isFetching;
        membersError = memberState.error ?? invitationState.error;
      }

      apply();
      _tabCancels.add(_queries.engine.watch(membersQuery, (_) {
        if (mounted) _updateState(apply);
      }, fireImmediately: false));
      _tabCancels.add(_queries.engine.watch(invitationsQuery, (_) {
        if (mounted) _updateState(apply);
      }, fireImmediately: false));
      _ensure(_queries.engine, membersQuery);
      _ensure(_queries.engine, invitationsQuery);
    }
  }

  @override
  void didUpdateWidget(_SpaceWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.space.id != widget.space.id) _editing = false;
    if (oldWidget.space.id != widget.space.id ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.spaceThreads != widget.spaceThreads ||
        oldWidget.tabQueries != widget.tabQueries ||
        oldWidget.mutations != widget.mutations ||
        oldWidget.section != widget.section) {
      _cancelTab();
      _configureQueries();
      _bindActiveSection();
    }
  }

  @override
  void dispose() {
    _cancelTab();
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _updateState(VoidCallback callback) => setState(callback);

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return widget.section == SpacePageSection.members
          ? _membersTab()
          : _threadsTab();
    }
    return _page();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  Widget _page() => LayoutBuilder(
        builder: (context, constraints) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_editing)
                              Expanded(child: _spaceEditForm())
                            else
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      widget.space.name.isNotEmpty
                                          ? widget.space.name
                                          : 'Untitled Space',
                                      textAlign: TextAlign.start,
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -0.3,
                                      ),
                                    ),
                                    if (widget.space.description
                                        .trim()
                                        .isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        widget.space.description.trim(),
                                        textAlign: TextAlign.start,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            SizedBox(
                              key: const ValueKey('space-header-actions'),
                              child: isOwner && !_editing
                                  ? PopupMenuButton<String>(
                                      color:
                                          SyntilaMenuStyle.background(_isDark),
                                      surfaceTintColor: Colors.transparent,
                                      elevation: 12,
                                      shadowColor:
                                          SyntilaMenuStyle.shadow(_isDark),
                                      shape: SyntilaMenuStyle.shape(_isDark),
                                      menuPadding: SyntilaMenuStyle.padding,
                                      icon: const Icon(Icons.more_vert),
                                      tooltip: 'Space actions',
                                      splashRadius: 18,
                                      onSelected: (action) {
                                        if (action == 'edit') {
                                          _startEditing();
                                        } else if (action == 'archive') {
                                          widget.onArchive();
                                        } else if (action == 'delete') {
                                          widget.onDelete();
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        PopupMenuItem(
                                          height: 36,
                                          textStyle:
                                              SyntilaMenuStyle.popupTextStyle(
                                                  _isDark),
                                          value: 'edit',
                                          child: Row(
                                            children: [
                                              Icon(Icons.edit_outlined,
                                                  color: SyntilaColors
                                                      .textSecondary(_isDark),
                                                  size: 18),
                                              const SizedBox(width: 8),
                                              const Text('Edit'),
                                            ],
                                          ),
                                        ),
                                        PopupMenuItem(
                                          height: 36,
                                          textStyle:
                                              SyntilaMenuStyle.popupTextStyle(
                                                  _isDark),
                                          value: 'archive',
                                          child: Row(
                                            children: [
                                              Icon(Icons.archive_outlined,
                                                  color: SyntilaColors
                                                      .textSecondary(_isDark),
                                                  size: 18),
                                              const SizedBox(width: 8),
                                              const Text('Archive'),
                                            ],
                                          ),
                                        ),
                                        PopupMenuItem(
                                          height: 36,
                                          textStyle:
                                              SyntilaMenuStyle.popupTextStyle(
                                                  _isDark),
                                          value: 'delete',
                                          child: const Row(
                                            children: [
                                              Icon(Icons.delete_outline,
                                                  size: 18,
                                                  color: SyntilaColors.error),
                                              SizedBox(width: 8),
                                              Text('Delete',
                                                  style: TextStyle(
                                                      color:
                                                          SyntilaColors.error)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                        if (_workflows != null && !_editing)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _SpaceWorkspaceSelector(
                                configurations: _workflows!, isOwner: isOwner),
                          ),
                      ],
                    ),
                  ),
                  if (widget.section == SpacePageSection.members)
                    _membersTab()
                  else
                    _threadsTab(),
                ],
              ),
            ),
          ),
        ),
      );
}
