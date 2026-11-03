import 'dart:async';
import '../common/quiet_notices.dart';

import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../ax/sync/ax_archived_spaces.dart';
import '../../ax/sync/ax_collaboration_mutations.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_sync_engine.dart';

class ArchivedSpacesPage extends StatefulWidget {
  const ArchivedSpacesPage({
    super.key,
    required this.archivedSpaces,
    required this.mutations,
  });

  final AxArchivedSpaces archivedSpaces;
  final AxCollaborationMutations mutations;

  @override
  State<ArchivedSpacesPage> createState() => _ArchivedSpacesPageState();
}

class _ArchivedSpacesPageState extends State<ArchivedSpacesPage> {
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(ArchivedSpacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.archivedSpaces != widget.archivedSpaces) _ensure();
  }

  void _ensure() => unawaited(widget.archivedSpaces
      .ensure()
      .then<void>((_) {}, onError: (Object _, StackTrace __) {}));

  @override
  Widget build(BuildContext context) => AxQueryBuilder<List<AxSpace>>(
        engine: widget.archivedSpaces.engine,
        query: widget.archivedSpaces.query,
        ensure: false,
        builder: (context, state) {
          final spaces = state.data ?? const <AxSpace>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Archived Spaces',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('Spaces you archived are kept here until restored.'),
              const SizedBox(height: 20),
              _ReadStatus(spaces: widget.archivedSpaces, state: state),
              if (state.hasData && spaces.isEmpty)
                const Text(
                    'Archived Spaces will appear here when you archive a Space.'),
              if (spaces.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < spaces.length; i++) ...[
                      if (i > 0) const SizedBox(height: 12),
                      _card(spaces[i]),
                    ],
                  ],
                ),
            ],
          );
        },
      );

  Widget _card(AxSpace space) => Card(
        key: ValueKey('archived-space-${space.id}'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(space.name,
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                  ),
                  _actionsMenu(space),
                ],
              ),
              if (space.description.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  space.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _actionsMenu(AxSpace space) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<String>(
      key: ValueKey('archived-space-actions-${space.id}'),
      tooltip: 'Archived Space actions',
      enabled: !_busy.contains(space.id),
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(24),
      color: SyntilaMenuStyle.background(isDark),
      surfaceTintColor: Colors.transparent,
      shape: SyntilaMenuStyle.shape(isDark),
      menuPadding: SyntilaMenuStyle.padding,
      onSelected: (action) {
        if (action == 'restore') unawaited(_restore(space));
        if (action == 'delete') unawaited(_confirmDelete(space));
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          value: 'restore',
          height: 48,
          child: Row(children: [
            Icon(Icons.unarchive_outlined, size: 16),
            SizedBox(width: 8),
            Text('Restore', style: SyntilaMenuStyle.textStyle),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          height: 48,
          child: Row(children: [
            Icon(Icons.delete_outline_rounded,
                size: 16, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 8),
            Text('Delete',
                style: SyntilaMenuStyle.textStyle
                    .copyWith(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ],
      child: Ink(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: _busy.contains(space.id)
            ? const Center(
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)))
            : const Icon(Icons.more_vert, size: 16),
      ),
    );
  }

  Future<void> _restore(AxSpace space) async {
    setState(() => _busy.add(space.id));
    try {
      await widget.mutations.editSpace(
        space,
        settings: const {'archived': false},
      );
      await widget.archivedSpaces.refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(space.id));
    }
  }

  Future<void> _confirmDelete(AxSpace space) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        constraints: SyntilaDialogStyle.small,
        title: Text('Delete ${space.name}?'),
        content: const Text(
            'This permanently deletes the Space and its archived record.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy.add(space.id));
    try {
      await widget.mutations.deleteSpace(space);
      await widget.archivedSpaces.refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(space.id));
    }
  }
}

class _ReadStatus extends StatelessWidget {
  const _ReadStatus({required this.spaces, required this.state});

  final AxArchivedSpaces spaces;
  final AxQueryState<List<AxSpace>> state;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.isFetching)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(),
            ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      state.hasData
                          ? 'Archived Spaces could not be updated. Cached details remain available.'
                          : 'Archived Spaces could not be loaded. Check your connection.',
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(spaces.refresh().then<void>(
                        (_) {},
                        onError: (Object _, StackTrace __) {})),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
        ],
      );
}
