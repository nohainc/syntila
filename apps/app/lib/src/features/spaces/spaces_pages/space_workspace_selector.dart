part of '../spaces_pages.dart';

const double _settingLabelWidth = 128;
const double _settingRowSpacing = 8;

TextStyle? _settingLabelStyle(ThemeData theme) => theme.textTheme.bodySmall
    ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

TextStyle? _settingValueStyle(ThemeData theme) =>
    theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600);

/// Which Workspace a Space runs on. Threads use that Workspace's Workers and
/// workflows. Owners can pick one of their Workspaces or follow the default;
/// other members only see the current choice.
class _SpaceWorkspaceSelector extends StatefulWidget {
  const _SpaceWorkspaceSelector(
      {required this.configurations, required this.isOwner});
  final AxWorkflowConfigurations configurations;
  final bool isOwner;

  @override
  State<_SpaceWorkspaceSelector> createState() =>
      _SpaceWorkspaceSelectorState();
}

class _SpaceWorkspaceSelectorState extends State<_SpaceWorkspaceSelector> {
  static const _followDefault = '';
  bool _busy = false;
  int _folderRevision = 0;

  AxSpaceAdditionalFolderDataSource? get _folderSource {
    final Object source = widget.configurations.source;
    if (!widget.isOwner || widget.configurations.spaceId == null) return null;
    return source is AxSpaceAdditionalFolderDataSource ? source : null;
  }

  /// Number of folders that a Workspace change would detach. Best effort: a
  /// failed read only drops the extra sentence from the warning.
  Future<int> _attachedFolderCount() async {
    final source = _folderSource;
    if (source == null) return 0;
    try {
      final folders = await source
          .loadSpaceAdditionalFolders(widget.configurations.spaceId!);
      return folders.eligible ? folders.attached.length : 0;
    } on Object {
      return 0;
    }
  }

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(_SpaceWorkspaceSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configurations != widget.configurations) _ensure();
  }

  void _ensure() => unawaited(widget.configurations
      .ensureWorkspace()
      .then<void>((_) {}, onError: (Object _, StackTrace __) {}));

  @override
  Widget build(BuildContext context) => AxQueryBuilder(
        engine: widget.configurations.engine,
        query: widget.configurations.workspaceQuery,
        ensure: false,
        builder: (context, state) {
          final settings = state.data;
          if (settings == null) {
            if (state.error == null) return const SizedBox.shrink();
            // A failed read never hides the setting: say so and let the
            // person try again.
            final theme = Theme.of(context);
            return Row(
                key: const ValueKey('space-workspace-error'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Workspace could not be loaded',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error)),
                  const SizedBox(width: 8),
                  TextButton(
                      onPressed: () => unawaited(widget.configurations.engine
                          .refresh(widget.configurations.workspaceQuery)
                          .then<void>((_) {},
                              onError: (Object _, StackTrace __) {})),
                      child: const Text('Retry')),
                ]);
          }
          final name = settings.workspaces
              .where((workspace) => workspace.id == settings.workspaceId)
              .firstOrNull
              ?.name;
          final theme = Theme.of(context);
          if (!widget.isOwner) return const SizedBox.shrink();
          final known = settings.workspaces
              .any((workspace) => workspace.id == settings.workspaceId);
          final current = settings.inherited
              ? _followDefault
              : (settings.workspaceId ?? _followDefault);
          final choices = <String, String>{
            _followDefault: 'Default Workspace',
            for (final workspace in settings.workspaces)
              workspace.id: workspace.name,
            if (!settings.inherited && settings.workspaceId != null && !known)
              settings.workspaceId!: 'Unavailable Workspace',
          };
          final isDark = theme.brightness == Brightness.dark;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  SizedBox(
                      width: _settingLabelWidth,
                      child:
                          Text('Workspace', style: _settingLabelStyle(theme))),
                  // Same compact list selector as the Work composer and
                  // workflow model pickers.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: PopupMenuButton<String>(
                        key: const ValueKey('space-workspace'),
                        enabled: !_busy,
                        tooltip: 'Choose Workspace',
                        color: SyntilaColors.composerBackground(isDark),
                        surfaceTintColor: Colors.transparent,
                        elevation: 12,
                        shadowColor: SyntilaMenuStyle.shadow(isDark),
                        shape: SyntilaMenuStyle.shape(isDark),
                        menuPadding: SyntilaMenuStyle.padding,
                        itemBuilder: (menuContext) => [
                          for (final choice in choices.entries)
                            SyntilaMenuEntry<String>(
                              value: choice.key,
                              child: MenuItemButton(
                                style: SyntilaMenuStyle.item(isDark),
                                leadingIcon: Icon(
                                  choice.key == current
                                      ? Icons.check_circle_rounded
                                      : Icons.circle_outlined,
                                  size: 15,
                                ),
                                onPressed: () =>
                                    Navigator.pop(menuContext, choice.key),
                                child: Text(choice.value,
                                    style: SyntilaMenuStyle.textStyle),
                              ),
                            ),
                        ],
                        onSelected: (id) => _select(id, current, settings),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 5),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Flexible(
                                child: Text(
                                    choices[current] ?? 'Default Workspace',
                                    overflow: TextOverflow.ellipsis,
                                    style: _settingValueStyle(theme))),
                            const SizedBox(width: 2),
                            const Icon(Icons.keyboard_arrow_down, size: 14),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ]),
                if (settings.inherited) ...[
                  Padding(
                    padding: const EdgeInsets.only(
                        left: _settingLabelWidth + 8, bottom: 4),
                    child: Text(
                        'Following the default Workspace${name == null ? '' : ': $name'}',
                        style: _settingLabelStyle(theme)),
                  ),
                ],
                if (_folderSource != null && settings.workspaceId != null)
                  _SpaceAdditionalFolders(
                    // A different Workspace has a different folder list.
                    key: ValueKey(
                        'space-folders-${settings.workspaceId}-$_folderRevision'),
                    source: _folderSource!,
                    spaceId: widget.configurations.spaceId!,
                  ),
              ]);
        },
      );

  Future<void> _select(
      String id, String current, AxWorkflowWorkspaceSettings settings) async {
    if (id == current) return;
    final inherit = id == _followDefault;
    setState(() => _busy = true);
    try {
      final targetWorkspace = inherit
          ? (await widget.configurations.engine.refresh(
                  AxWorkflowConfigurations(widget.configurations.source,
                          engine: widget.configurations.engine)
                      .workspaceQuery))
              .workspaceId
          : id;
      final sameWorkspace = targetWorkspace == settings.workspaceId;
      final attachedFolders = sameWorkspace ? 0 : await _attachedFolderCount();
      if (!mounted) return;
      final folderNotice = attachedFolders == 0
          ? ''
          : ' ${attachedFolders == 1 ? 'Its additional folder is' : 'Its $attachedFolders additional folders are'} detached; files on your computer are not changed.';
      final confirmed = sameWorkspace ||
          (await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                          constraints: SyntilaDialogStyle.small,
                          title: const Text('Change Workspace?'),
                          content: Text((inherit
                                  ? 'This Space will follow your default Workspace. Its own workflow overrides are reset, and existing runs keep their recorded settings.'
                                  : 'Threads in this Space will use the Workers and workflows of the selected Workspace. This Space’s workflow overrides are reset, the Workspace is authorized to run Work here, and existing runs keep their recorded settings.') +
                              folderNotice),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel')),
                            FilledButton(
                                key: const ValueKey('confirm-space-workspace'),
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Change Workspace')),
                          ]))) ==
              true;
      if (confirmed != true || !mounted) return;
      await widget.configurations
          .selectWorkspace(inherit ? null : id, inherit: inherit);
      if (mounted) setState(() => _folderRevision++);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }
}

/// Owner-only list of folders from the Space's Workspace that this Space may
/// use. Folders are added in the Workspace app; this only attaches them.
class _SpaceAdditionalFolders extends StatefulWidget {
  const _SpaceAdditionalFolders(
      {required this.source, required this.spaceId, super.key});
  final AxSpaceAdditionalFolderDataSource source;
  final String spaceId;

  @override
  State<_SpaceAdditionalFolders> createState() =>
      _SpaceAdditionalFoldersState();
}

class _SpaceAdditionalFoldersState extends State<_SpaceAdditionalFolders> {
  AxSpaceAdditionalFolders? _folders;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final folders =
          await widget.source.loadSpaceAdditionalFolders(widget.spaceId);
      if (mounted) setState(() => _folders = folders);
    } on Object {
      // The folder link is optional; Space settings stay usable without it.
    }
  }

  static String _status(String status) => switch (status) {
        'available' => 'Read & write',
        'read_only' => 'Read only',
        'denied' => 'No access on the Workspace',
        _ => 'Missing on the Workspace',
      };

  Future<void> _edit(AxSpaceAdditionalFolders current) async {
    final selected = {for (final folder in current.attached) folder.id};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          constraints: SyntilaDialogStyle.small,
          title: const Text('Additional folders'),
          content: SizedBox(
            width: 420,
            child: current.folders.isEmpty
                ? const Text(
                    'No folders are allowed on this Workspace yet. Add them '
                    'in the Syntila Workspace app under Allowed folders.')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child:
                            Text('Workers in this Space may use the selected '
                                'folders in addition to the Space folder.'),
                      ),
                      for (final folder in current.folders)
                        CheckboxListTile(
                          key: ValueKey('space-folder-${folder.id}'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: selected.contains(folder.id),
                          // An inaccessible folder can be removed but not
                          // newly attached.
                          onChanged: folder.accessible ||
                                  selected.contains(folder.id)
                              ? (value) => setDialogState(() => value == true
                                  ? selected.add(folder.id)
                                  : selected.remove(folder.id))
                              : null,
                          title: Text(folder.displayName),
                          subtitle: Text(_status(folder.status)),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            if (current.folders.isNotEmpty)
              FilledButton(
                  key: const ValueKey('save-space-folders'),
                  onPressed: () => Navigator.pop(context, selected),
                  child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      final saved =
          await widget.source.saveSpaceAdditionalFolders(widget.spaceId, [
        for (final folder in current.folders)
          if (result.contains(folder.id)) folder.id
      ]);
      if (mounted) setState(() => _folders = saved);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    if (folders == null || !folders.eligible) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final attached = folders.attached.toList();
    final unavailable = attached.where((folder) => !folder.accessible).length;
    return Padding(
      padding: const EdgeInsets.only(top: _settingRowSpacing),
      child: Row(children: [
        SizedBox(
            width: _settingLabelWidth,
            child:
                Text('Additional folders', style: _settingLabelStyle(theme))),
        Expanded(
            child: Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('space-additional-folders'),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact),
            onPressed: () => _edit(folders),
            icon: Icon(Icons.folder_outlined,
                size: 14,
                color: unavailable > 0 ? theme.colorScheme.error : null),
            label: Text(
              attached.isEmpty
                  ? 'None'
                  : attached.map((f) => f.displayName).join(', '),
              overflow: TextOverflow.ellipsis,
              style: _settingValueStyle(theme),
            ),
          ),
        )),
      ]),
    );
  }
}
