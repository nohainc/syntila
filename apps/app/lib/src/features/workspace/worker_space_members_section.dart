import 'dart:async';

import 'package:flutter/material.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import '../../ax/ax_data.dart' show AxWorkerManagementSource;
import '../../ax/ax_models.dart';

/// Owner control on the Worker detail view (ADR-042): which members of one
/// of the owner's Spaces may send requests to this Worker, and how far they
/// may go (Chat only, Work, or Work with shell). Members also need models
/// ticked in "Models for members".
class WorkerSpaceMembersSection extends StatefulWidget {
  const WorkerSpaceMembersSection({
    super.key,
    required this.worker,
    required this.management,
    required this.spaces,
    this.currentUserId,
  });

  final WorkerInstance worker;
  final AxWorkerManagementSource? management;

  /// The Spaces the Worker can be shared in (shared Spaces the user manages).
  final List<AxSpace> spaces;

  /// The signed-in owner, left out of the list: owners never need access.
  final String? currentUserId;

  @override
  State<WorkerSpaceMembersSection> createState() =>
      _WorkerSpaceMembersSectionState();
}

const _modeLabels = {
  'chat': 'Chat',
  'work': 'Work',
  'work+shell': 'Work + shell',
};

class _WorkerSpaceMembersSectionState extends State<WorkerSpaceMembersSection> {
  String? _spaceId;
  bool _loading = false;
  bool _saving = false;
  Object? _loadError;
  Object? _saveError;
  List<AxWorkerSpaceMemberAccess> _saved = const [];
  List<AxWorkerSpaceMemberAccess> _draft = const [];

  @override
  void initState() {
    super.initState();
    _spaceId = widget.spaces.firstOrNull?.id;
    if (_spaceId != null) unawaited(_load());
  }

  @override
  void didUpdateWidget(WorkerSpaceMembersSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final stillThere = widget.spaces.any((s) => s.id == _spaceId);
    if (oldWidget.worker.id != widget.worker.id || !stillThere) {
      _spaceId = stillThere ? _spaceId : widget.spaces.firstOrNull?.id;
      if (_spaceId != null) unawaited(_load());
    }
  }

  /// Everyone except the signed-in owner, who never needs access.
  List<AxWorkerSpaceMemberAccess> _others(
          List<AxWorkerSpaceMemberAccess> members) =>
      [
        for (final m in members)
          if (m.userId != widget.currentUserId) m
      ];

  Future<void> _load() async {
    final management = widget.management;
    final spaceId = _spaceId;
    if (management == null || spaceId == null) return;
    final workerId = widget.worker.id;
    setState(() {
      _loading = true;
      _loadError = null;
      _saveError = null;
    });
    try {
      final access = await management.loadWorkerSpaceAccess(workerId, spaceId);
      if (!mounted || spaceId != _spaceId || workerId != widget.worker.id) {
        return;
      }
      setState(() {
        _saved = _others(access.members);
        _draft = _saved;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || spaceId != _spaceId) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  bool get _dirty {
    for (var i = 0; i < _draft.length; i++) {
      final a = _draft[i];
      final b = _saved[i];
      if (a.enabled != b.enabled || (a.enabled && a.mode != b.mode)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _save() async {
    final management = widget.management;
    final spaceId = _spaceId;
    if (management == null || spaceId == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved =
          await management.saveWorkerSpaceAccess(widget.worker.id, spaceId, [
        for (final m in _draft)
          if (m.enabled) m
      ]);
      if (!mounted) return;
      setState(() {
        _saved = _others(saved.members);
        _draft = _saved;
        _saving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saveError = error;
        _saving = false;
      });
    }
  }

  void _update(int index, AxWorkerSpaceMemberAccess member) => setState(() {
        _saveError = null;
        _draft = [
          for (var i = 0; i < _draft.length; i++)
            if (i == index) member else _draft[i]
        ];
      });

  @override
  Widget build(BuildContext context) {
    if (widget.management == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Card(
      key: const ValueKey('worker-space-members'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Members', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Choose who in a Space may send requests to this Worker. '
              'They can use only the models ticked in Models for members.',
              style: muted,
            ),
            const SizedBox(height: 12),
            if (widget.spaces.isEmpty)
              Text('Invite people to a Space to share this Worker with them.',
                  style: muted)
            else ...[
              DropdownButton<String>(
                key: const ValueKey('worker-space-members-space'),
                value: _spaceId,
                isDense: true,
                items: [
                  for (final space in widget.spaces)
                    DropdownMenuItem(value: space.id, child: Text(space.name)),
                ],
                onChanged: _saving
                    ? null
                    : (id) {
                        if (id == null || id == _spaceId) return;
                        setState(() => _spaceId = id);
                        unawaited(_load());
                      },
              ),
              const SizedBox(height: 8),
              if (_loading)
                const LinearProgressIndicator()
              else if (_loadError != null)
                Row(children: [
                  Expanded(
                    child: Text('Could not load members: $_loadError',
                        style: muted?.copyWith(color: theme.colorScheme.error)),
                  ),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ])
              else if (_draft.isEmpty)
                Text('No other members in this Space yet.', style: muted)
              else ...[
                for (var i = 0; i < _draft.length; i++)
                  _memberRow(context, i, _draft[i]),
                if (_saveError != null) ...[
                  const SizedBox(height: 8),
                  Text('Could not save members: $_saveError',
                      style: muted?.copyWith(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 12),
                Wrap(spacing: 8, children: [
                  FilledButton(
                    key: const ValueKey('worker-space-members-save'),
                    onPressed: _dirty && !_saving ? _save : null,
                    child: Text(_saveError != null ? 'Retry' : 'Save'),
                  ),
                  TextButton(
                    onPressed: _dirty && !_saving
                        ? () => setState(() {
                              _draft = _saved;
                              _saveError = null;
                            })
                        : null,
                    child: const Text('Cancel'),
                  ),
                ]),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _memberRow(
      BuildContext context, int index, AxWorkerSpaceMemberAccess member) {
    final name =
        member.displayName.isNotEmpty ? member.displayName : member.email;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Switch(
          key: ValueKey('worker-space-member-${member.userId}'),
          value: member.enabled,
          onChanged: _saving
              ? null
              : (on) => _update(index, member.copyWith(enabled: on)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (member.displayName.isNotEmpty && member.email.isNotEmpty)
                Text(member.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        DropdownButton<String>(
          key: ValueKey('worker-space-member-mode-${member.userId}'),
          value: member.mode,
          isDense: true,
          items: [
            for (final entry in _modeLabels.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: _saving || !member.enabled
              ? null
              : (mode) {
                  if (mode != null) {
                    _update(index, member.copyWith(mode: mode));
                  }
                },
        ),
      ]),
    );
  }
}
