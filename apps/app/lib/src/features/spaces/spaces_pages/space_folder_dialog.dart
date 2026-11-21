part of '../spaces_pages.dart';

/// A failed request asked for a Space folder. The Thread page listens for this
/// and opens the folder dialog, so the request card needs no callback of its own.
class _SelectSpaceFolderNotification extends Notification {
  const _SelectSpaceFolderNotification();
}

/// Whether a failure text says the Space needs a folder (or one on another
/// computer), so the card offers the Select folder button.
bool _needsSpaceFolder(String message) =>
    message.contains(spaceFolderRequiredMessage) ||
    message.contains('The folder for this Space is on ');

/// Opens the dialog that picks the folder a Space works in. Returns whether the
/// choice changed.
Future<bool> showSpaceFolderDialog(
  BuildContext context, {
  required AxSpaceFolderDataSource source,
  required String spaceId,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) =>
          _SpaceFolderDialog(source: source, spaceId: spaceId),
    ) ==
    true;

class _SpaceFolderDialog extends StatefulWidget {
  const _SpaceFolderDialog({required this.source, required this.spaceId});

  final AxSpaceFolderDataSource source;
  final String spaceId;

  @override
  State<_SpaceFolderDialog> createState() => _SpaceFolderDialogState();
}

class _SpaceFolderDialogState extends State<_SpaceFolderDialog> {
  List<AxDeviceFolder>? _folders;
  AxSpaceFolder? _current;
  String? _selected;
  String? _error;
  bool _saving = false;
  bool _changed = false;

  static String _key(AxDeviceFolder folder) =>
      '${folder.deviceId}|${folder.folderId}';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        widget.source.loadDeviceFolders(),
        widget.source.loadSpaceFolder(widget.spaceId),
      ]);
      if (!mounted) return;
      setState(() {
        _folders = results[0] as List<AxDeviceFolder>;
        _current = results[1] as AxSpaceFolder;
        final folder = _current!.folder;
        _selected = folder == null ? null : _key(folder);
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _save() async {
    final folders = _folders;
    final selected = _selected;
    if (folders == null || selected == null) return;
    final chosen = folders.firstWhere((folder) => _key(folder) == selected);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.source.setSpaceFolder(widget.spaceId,
          deviceId: chosen.deviceId, folderId: chosen.folderId);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _clear() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.source.clearSpaceFolder(widget.spaceId);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  /// Forgets a computer that is not connected, or one of its folders, after
  /// saying how many Spaces will lose their folder. Nothing on the computer
  /// changes: only this list.
  Future<void> _remove(String deviceId,
      {String? folderId, required String label}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final spaces = await widget.source
          .removeDeviceFolders(deviceId, folderId: folderId, dryRun: true);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
              folderId == null ? 'Remove this computer?' : 'Remove folder?'),
          content: Text(
            '$label will be removed from your list. Files on the computer are '
            'not changed.'
            '${spaces == 0 ? '' : '\n\nUsed by $spaces ${spaces == 1 ? 'Space' : 'Spaces'}. '
                '${spaces == 1 ? 'It' : 'They'} will have no folder until you select another.'}'
            '\n\nIf it connects again, it appears here again.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                key: const ValueKey('space-folder-remove-confirm'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove')),
          ],
        ),
      );
      if (confirmed != true) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      await widget.source.removeDeviceFolders(deviceId, folderId: folderId);
      _changed = true;
      if (!mounted) return;
      await _load();
      if (mounted) setState(() => _saving = false);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  List<Widget> _listing(ThemeData theme, List<AxDeviceFolder> folders) {
    final widgets = <Widget>[];
    String? device;
    for (final folder in folders) {
      if (folder.deviceId != device) {
        device = folder.deviceId;
        widgets.add(Padding(
          padding: EdgeInsets.only(top: widgets.isEmpty ? 0 : 12, bottom: 4),
          child: Row(children: [
            Icon(Icons.computer_outlined,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                folder.online
                    ? folder.deviceName
                    : '${folder.deviceName} · not connected',
                style: theme.textTheme.labelLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!folder.online)
              TextButton(
                key: ValueKey('space-folder-remove-device-${folder.deviceId}'),
                onPressed: _saving
                    ? null
                    : () => _remove(folder.deviceId, label: folder.deviceName),
                child: const Text('Remove computer'),
              ),
          ]),
        ));
      }
      final selected = _selected == _key(folder);
      widgets.add(ListTile(
        key: ValueKey(
            'space-folder-choice-${folder.deviceId}-${folder.folderId}'),
        dense: true,
        enabled: folder.writable && !_saving,
        selected: selected,
        contentPadding: const EdgeInsets.only(left: 8, right: 4),
        leading: const Icon(Icons.folder_outlined, size: 20),
        title: Text(folder.displayName, overflow: TextOverflow.ellipsis),
        subtitle: folder.writable
            ? null
            : const Text('Read only. Allow writing in Syntila Connect.'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (selected) const Icon(Icons.check, size: 18),
          if (!folder.online)
            IconButton(
              key: ValueKey(
                  'space-folder-remove-${folder.deviceId}-${folder.folderId}'),
              tooltip: 'Remove folder',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: _saving
                  ? null
                  : () => _remove(folder.deviceId,
                      folderId: folder.folderId, label: folder.displayName),
            ),
        ]),
        onTap: () => setState(() => _selected = _key(folder)),
      ));
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folders = _folders;
    final current = _current;
    final currentKey = current?.folder == null ? null : _key(current!.folder!);
    final Widget content;
    if (_error != null && folders == null) {
      content = Text(_error!, style: TextStyle(color: theme.colorScheme.error));
    } else if (folders == null) {
      content = const LinearProgressIndicator();
    } else if (current != null && !current.eligible) {
      content =
          const Text('Only the owner of this Space can choose its folder.');
    } else if (folders.isEmpty) {
      content = const Text(
          'No folders are available yet. In Syntila Connect on the computer '
          'where Workers should work, add a folder with write access '
          '(syntila-connect folders add PATH --write) and keep its service '
          'running. It then appears here.');
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Workers use this folder for the Space’s files. Folders are set '
              'up in Syntila Connect on each computer.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Flexible(
            child:
                ListView(shrinkWrap: true, children: _listing(theme, folders)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      );
    }
    return AlertDialog(
      constraints: SyntilaDialogStyle.medium,
      title: const Text('Select a folder'),
      content: SizedBox(width: 440, child: content),
      actions: [
        if (currentKey != null)
          TextButton(
            key: const ValueKey('space-folder-clear'),
            onPressed: _saving ? null : _clear,
            child: const Text('Clear'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, _changed),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('space-folder-save'),
          onPressed: _saving || _selected == null || _selected == currentKey
              ? null
              : _save,
          child: const Text('Select'),
        ),
      ],
    );
  }
}

/// The Space page row for the Space's folder. Shown to the owner when Workers
/// run Work (Workers UX).
class _SpaceFolderRow extends StatefulWidget {
  const _SpaceFolderRow({required this.configurations, required this.isOwner});

  final AxWorkflowConfigurations configurations;
  final bool isOwner;

  @override
  State<_SpaceFolderRow> createState() => _SpaceFolderRowState();
}

class _SpaceFolderRowState extends State<_SpaceFolderRow> {
  AxSpaceFolder? _state;
  bool _workersUx = false;
  String? _loadError;

  AxSpaceFolderDataSource? get _source {
    final Object source = widget.configurations.source;
    return source is AxSpaceFolderDataSource ? source : null;
  }

  String? get _spaceId => widget.configurations.spaceId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final source = _source;
    final spaceId = _spaceId;
    final Object configured = widget.configurations.source;
    if (!widget.isOwner || source == null || spaceId == null) return;
    try {
      if (configured is! AxWorkersUxFeatureSource ||
          !await (configured as AxWorkersUxFeatureSource).workersUxEnabled()) {
        return;
      }
      final state = await source.loadSpaceFolder(spaceId);
      if (mounted) {
        setState(() {
          _workersUx = true;
          _state = state;
        });
      }
    } on Object catch (error) {
      // Say so instead of hiding the row: a hidden row looks like a missing feature.
      if (mounted) setState(() => _loadError = '$error');
    }
  }

  Future<void> _edit() async {
    final source = _source;
    final spaceId = _spaceId;
    if (source == null || spaceId == null) return;
    final changed =
        await showSpaceFolderDialog(context, source: source, spaceId: spaceId);
    if (changed) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: _settingRowSpacing),
        child: Text('Folder could not be loaded: $_loadError',
            key: const ValueKey('space-folder-error'),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error)),
      );
    }
    if (!_workersUx || state == null || !state.eligible) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final folder = state.folder;
    return Padding(
      padding: const EdgeInsets.only(top: _settingRowSpacing),
      child: Row(children: [
        SizedBox(
            width: _settingLabelWidth,
            child: Text('Folder', style: _settingLabelStyle(theme))),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('space-folder'),
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact),
              onPressed: _edit,
              icon: const Icon(Icons.folder_outlined, size: 14),
              label: Text(
                folder == null
                    ? 'Select folder'
                    : '${folder.displayName} · ${folder.deviceName}',
                overflow: TextOverflow.ellipsis,
                style: _settingValueStyle(theme),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
