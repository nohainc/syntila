part of '../spaces_pages.dart';

/// Space landing surface with explicit, Space-unique Thread creation.
class NewThreadPage extends StatefulWidget {
  const NewThreadPage({
    super.key,
    required this.space,
    required this.dataSource,
    required this.createThread,
    required this.onOpenThread,
    required this.discussionCache,
    required this.workHistoryCache,
    required this.threadViewStateStore,
    this.catalogs,
    this.workflowConfigurations,
    this.currentUserId,
    this.currentUserName,
    this.viewerEmail,
    this.onOpenThreadId,
    this.spaceThreads,
    this.tabQueries,
    this.mutations,
  });

  final AxSpace space;
  final AxDataSource dataSource;
  final Future<AxThread> Function(String name) createThread;
  final ValueChanged<AxThread> onOpenThread;
  final AxDiscussionCache discussionCache;
  final AxWorkHistoryCache workHistoryCache;
  final AxThreadViewStateStore threadViewStateStore;
  final AxSessionCatalogs? catalogs;
  final AxWorkflowConfigurations? workflowConfigurations;
  final String? currentUserId;
  final String? currentUserName;
  final String? viewerEmail;

  /// Opens an existing Thread from the Space's Thread list.
  final ValueChanged<String>? onOpenThreadId;
  final AxSpaceThreads? spaceThreads;
  final AxSpaceTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;

  @override
  State<NewThreadPage> createState() => _NewThreadPageState();
}

class _NewThreadPageState extends State<NewThreadPage> {
  final _nameController = TextEditingController();
  late final _threads =
      AxSpaceThreads(widget.dataSource, engine: widget.workHistoryCache.engine);
  late final AxWorkflowConfigurations? _workflows =
      widget.workflowConfigurations ??
          (widget.dataSource is AxWorkflowWorkspaceDataSource
              ? AxWorkflowConfigurations(widget.dataSource,
                  engine: widget.workHistoryCache.engine,
                  spaceId: widget.space.id)
              : null);
  bool _busy = false;
  bool _savingAiHistoryVisibility = false;
  String? _aiHistoryVisibilityError;
  String? _creationError;

  Future<void> _setAiHistoryVisibility(bool visible) async {
    if (_savingAiHistoryVisibility || widget.space.role != 'owner') return;
    setState(() {
      _savingAiHistoryVisibility = true;
      _aiHistoryVisibilityError = null;
    });
    try {
      final mutations = widget.mutations ??
          AxCollaborationMutations(widget.dataSource,
              engine: widget.workHistoryCache.engine);
      await mutations
          .editSpace(widget.space, settings: {'showAiHistory': visible});
    } catch (error) {
      if (mounted) setState(() => _aiHistoryVisibilityError = error.toString());
    } finally {
      if (mounted) setState(() => _savingAiHistoryVisibility = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool _duplicate(List<AxThread> threads) {
    final name = _nameController.text.trim().toLowerCase();
    return name.isNotEmpty &&
        threads.any((thread) => thread.name.trim().toLowerCase() == name);
  }

  Future<void> _createNamedThread() async {
    if (_busy ||
        _nameController.text.trim().isEmpty ||
        !widget.space.effectivePermissions.manageOwnThreads) {
      return;
    }
    setState(() {
      _busy = true;
      _creationError = null;
    });
    try {
      final threads = await _threads.ensure(widget.space.id);
      if (!mounted) return;
      if (_duplicate(threads)) {
        setState(() => _creationError =
            'A Thread with this name already exists in this Space.');
        return;
      }
      final thread = await widget.createThread(_nameController.text.trim());
      if (thread.id.isEmpty ||
          thread.id.startsWith('local-') ||
          thread.spaceId != widget.space.id) {
        throw StateError('Thread creation returned an invalid identity.');
      }
      if (mounted) widget.onOpenThread(thread);
    } catch (error) {
      if (mounted) setState(() => _creationError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                  child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: PageWidth.of(context).pageWidth),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 20, 0, 12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.space.isDirect) ...[
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: SyntilaColors.primarySoftColor(
                                    Theme.of(context).brightness ==
                                        Brightness.dark),
                                backgroundImage:
                                    widget.space.avatarUrl != null &&
                                            widget.space.avatarUrl!.isNotEmpty
                                        ? NetworkImage(widget.space.avatarUrl!)
                                        : null,
                                child: widget.space.avatarUrl == null ||
                                        widget.space.avatarUrl!.isEmpty
                                    ? Text(
                                        widget.space.name.isNotEmpty
                                            ? widget.space.name[0].toUpperCase()
                                            : 'P',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color:
                                              SyntilaColors.primaryForeground(
                                                  Theme.of(context)
                                                          .brightness ==
                                                      Brightness.dark),
                                        ),
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.space.name.isNotEmpty
                                          ? widget.space.name
                                          : 'Personal connection',
                                      key: const ValueKey('space-landing-name'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Personal connection',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ] else ...[
                          if (widget.space.name.trim().isNotEmpty) ...[
                            Text(widget.space.name.trim(),
                                key: const ValueKey('space-landing-name'),
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 12),
                          ],
                          if (widget.space.description.trim().isNotEmpty) ...[
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 140),
                              child: SingleChildScrollView(
                                  child: Text(widget.space.description)),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                              width: double.infinity,
                              child: _threadNameField()),
                        ),
                      ]),
                ),
              ))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Center(
                child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: PageWidth.of(context).pageWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!widget.space.isSupport &&
                      (_workflows != null || widget.space.role == 'owner'))
                    _SpaceLandingSection(
                      title: 'Settings',
                      arrowKey: const ValueKey('space-settings-arrow'),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: double.infinity,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_workflows != null &&
                                    !widget.space.isDirect)
                                  Padding(
                                    padding: EdgeInsets.only(
                                        bottom: widget.space.role == 'owner'
                                            ? _settingRowSpacing
                                            : 0),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: _SpaceWorkspaceSelector(
                                          configurations: _workflows!,
                                          isOwner:
                                              widget.space.role == 'owner'),
                                    ),
                                  ),
                                // Same label column and type scale as the
                                // Workspace and Additional folders rows.
                                Row(
                                  key: const ValueKey(
                                      'space-show-ai-history-setting'),
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    SizedBox(
                                        width: _settingLabelWidth,
                                        child: Text('AI History tab',
                                            style: _settingLabelStyle(
                                                Theme.of(context)))),
                                    const Spacer(),
                                    SizedBox(
                                      height: 28,
                                      child: FittedBox(
                                        fit: BoxFit.contain,
                                        child: Switch(
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          value: widget.space.showAiHistory,
                                          onChanged: widget.space.role ==
                                                      'owner' &&
                                                  !_savingAiHistoryVisibility
                                              ? _setAiHistoryVisibility
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (_aiHistoryVisibilityError != null)
                                  Text(_aiHistoryVisibilityError!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!widget.space.isDirect)
                    _SpaceLandingSection(
                      title: 'Members',
                      arrowKey: const ValueKey('space-members-arrow'),
                      child: SpacePage(
                        embedded: true,
                        workflowConfigurations: widget.workflowConfigurations,
                        section: SpacePageSection.members,
                        space: widget.space,
                        dataSource: widget.dataSource,
                        viewerEmail: widget.viewerEmail,
                        onOpenThread: (_) {},
                        onArchive: () {},
                        onDelete: () {},
                      ),
                    ),
                  _SpaceLandingSection(
                    title: 'Archived Threads',
                    arrowKey: const ValueKey('space-archived-arrow'),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: double.infinity,
                        child: SpacePage(
                          key: const ValueKey('space-landing-threads'),
                          embedded: true,
                          section: SpacePageSection.threads,
                          space: widget.space,
                          dataSource: widget.dataSource,
                          spaceThreads: widget.spaceThreads,
                          tabQueries: widget.tabQueries,
                          mutations: widget.mutations,
                          viewerEmail: widget.viewerEmail,
                          onOpenThread: (id) => widget.onOpenThreadId?.call(id),
                          onArchive: () {},
                          onDelete: () {},
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )),
          ),
        ],
      ));

  Widget _threadNameField() => AxQueryBuilder<List<AxThread>>(
        engine: _threads.engine,
        query: _threads.query(widget.space.id),
        builder: (context, state) {
          final duplicate = _duplicate(state.data ?? const []);
          return TextField(
            key: const ValueKey('new-thread-name'),
            autofocus: true,
            controller: _nameController,
            enabled:
                !_busy && widget.space.effectivePermissions.manageOwnThreads,
            onChanged: (_) => setState(() => _creationError = null),
            decoration: InputDecoration(
              labelText: 'Create a new thread',
              hintText: 'Enter a unique name',
              counterText: '',
              errorText: duplicate
                  ? 'A Thread with this name already exists in this Space.'
                  : _creationError,
              suffixIcon: TextButton(
                style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.onSurface),
                onPressed: !_busy &&
                        !duplicate &&
                        _nameController.text.trim().isNotEmpty &&
                        widget.space.effectivePermissions.manageOwnThreads
                    ? _createNamedThread
                    : null,
                child: const Text('Create Thread'),
              ),
            ),
            onSubmitted: (_) => _createNamedThread(),
          );
        },
      );
}

/// Collapsed-by-default area on the Space landing. State changes are immediate
/// and do not add hover or expansion animation to these utility controls.
class _SpaceLandingSection extends StatefulWidget {
  const _SpaceLandingSection(
      {required this.title, required this.arrowKey, required this.child});
  final String title;
  final Key arrowKey;
  final Widget child;

  @override
  State<_SpaceLandingSection> createState() => _SpaceLandingSectionState();
}

class _SpaceLandingSectionState extends State<_SpaceLandingSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Theme(
        data: Theme.of(context).copyWith(
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
        ),
        child: ExpansionTile(
          expansionAnimationStyle: AnimationStyle.noAnimation,
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          expandedAlignment: Alignment.topLeft,
          shape: const Border(),
          collapsedShape: const Border(),
          showTrailingIcon: false,
          onExpansionChanged: (expanded) =>
              setState(() => _expanded = expanded),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 4),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                key: widget.arrowKey,
                size: 20,
              ),
            ],
          ),
          children: [widget.child],
        ),
      );
}
