import 'dart:async';

import 'package:flutter/material.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import '../../ax/ax_data.dart' show AxWorkerManagementSource;
import '../../ax/ax_models.dart';
import 'worker_model_visibility_table.dart';

/// Owner control on the Worker detail view: the models and efforts every
/// member may use on this Worker, in every Space it is shared with. The same
/// table as the Worker's own selector visibility.
class WorkerMemberModelsSection extends StatefulWidget {
  const WorkerMemberModelsSection({
    super.key,
    required this.worker,
    required this.management,
  });

  final WorkerInstance worker;
  final AxWorkerManagementSource? management;

  @override
  State<WorkerMemberModelsSection> createState() =>
      _WorkerMemberModelsSectionState();
}

class _WorkerMemberModelsSectionState extends State<WorkerMemberModelsSection> {
  bool _loading = true;
  bool _saving = false;
  Object? _loadError;
  Object? _saveError;
  AxWorkerMemberModelAccess _saved = const AxWorkerMemberModelAccess();
  Set<String> _allowedModels = {};
  Map<String, Set<String>> _allowedEfforts = {};

  @override
  void initState() {
    super.initState();
    if (widget.management != null) unawaited(_load());
  }

  @override
  void didUpdateWidget(WorkerMemberModelsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.management != null && oldWidget.worker.id != widget.worker.id) {
      unawaited(_load());
    }
  }

  void _adopt(AxWorkerMemberModelAccess access) {
    _saved = access;
    _allowedModels = access.allowedModels.toSet();
    _allowedEfforts = {
      for (final e in access.allowedEfforts.entries) e.key: e.value.toSet(),
    };
  }

  AxWorkerMemberModelAccess get _draft => AxWorkerMemberModelAccess(
        allowedModels: _allowedModels.toList()..sort(),
        allowedEfforts: {
          for (final e in _allowedEfforts.entries)
            if (e.value.isNotEmpty) e.key: (e.value.toList()..sort()),
        },
      );

  static bool _sameSet(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  bool get _dirty {
    final a = _draft;
    if (!_sameSet(a.allowedModels, _saved.allowedModels)) return true;
    final keys = {...a.allowedEfforts.keys, ..._saved.allowedEfforts.keys};
    return keys.any((k) => !_sameSet(
        a.allowedEfforts[k] ?? const [], _saved.allowedEfforts[k] ?? const []));
  }

  Future<void> _load() async {
    final management = widget.management;
    if (management == null) return;
    final workerId = widget.worker.id;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final access = await management.loadWorkerMemberModelAccess(workerId);
      if (!mounted || workerId != widget.worker.id) return;
      setState(() {
        _adopt(access);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || workerId != widget.worker.id) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final management = widget.management;
    if (management == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved = await management.saveWorkerMemberModelAccess(
          widget.worker.id, _draft);
      if (!mounted) return;
      setState(() {
        _adopt(saved);
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

  void _toggleModel(String modelId, bool allowed) => setState(() {
        _saveError = null;
        if (allowed) {
          _allowedModels.add(modelId);
        } else {
          _allowedModels.remove(modelId);
          _allowedEfforts.remove(modelId);
        }
      });

  void _toggleEffort(String modelId, String effort, bool allowed) =>
      setState(() {
        _saveError = null;
        final set = _allowedEfforts.putIfAbsent(modelId, () => {});
        if (allowed) {
          set.add(effort);
        } else {
          set.remove(effort);
        }
      });

  @override
  Widget build(BuildContext context) {
    if (widget.management == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final models = workerModelOptions(widget.worker);
    // The table shows what is hidden; members see only what is ticked.
    final hiddenModels = {
      for (final m in models)
        if (!_allowedModels.contains(m.id)) m.id,
    };
    final hiddenEfforts = {
      for (final m in models)
        m.id: {
          for (final v in m.effort.values)
            if (!(_allowedEfforts[m.id]?.contains(v) ?? false)) v,
        },
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Models for members', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Tick the models and effort levels every member may use on this '
              'Worker, in all Spaces. Nothing is available until you tick it.',
              style: muted,
            ),
            const SizedBox(height: 12),
            if (_loading)
              const LinearProgressIndicator()
            else if (_loadError != null)
              Row(children: [
                Expanded(
                  child: Text('Could not load member models: $_loadError',
                      style: muted?.copyWith(color: theme.colorScheme.error)),
                ),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ])
            else if (models.isEmpty)
              Text(
                'No models available yet. Refresh models while the Worker is online.',
                style: muted,
              )
            else ...[
              WorkerModelVisibilityTable(
                models: models,
                hiddenModels: hiddenModels,
                hiddenEfforts: hiddenEfforts,
                keyPrefix: 'worker-member-models',
                editable: !_saving,
                visibleColumnTitle: 'Available',
                onModelChanged: _toggleModel,
                onEffortChanged: _toggleEffort,
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 8),
                Text('Could not save member models: $_saveError',
                    style: muted?.copyWith(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                FilledButton(
                  key: const ValueKey('worker-member-models-save'),
                  onPressed: _dirty && !_saving ? _save : null,
                  child: Text(_saveError != null ? 'Retry' : 'Save'),
                ),
                TextButton(
                  onPressed: _dirty && !_saving
                      ? () => setState(() {
                            _adopt(_saved);
                            _saveError = null;
                          })
                      : null,
                  child: const Text('Cancel'),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
