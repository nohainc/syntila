import 'dart:async';
import 'package:flutter/material.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_worker_visibility.dart';
import '../../ax/sync/ax_worker_visibility_preferences.dart';
import '../../ax/workflow_configuration_options.dart';

/// Owner-only editor; inventory is deliberately not filtered by preferences.
class WorkspaceWorkerVisibilitySection extends StatefulWidget {
  const WorkspaceWorkerVisibilitySection(
      {super.key,
      required this.workspaceId,
      required this.workers,
      required this.preferences});
  final String workspaceId;
  final List<AxWorker> workers;
  final AxWorkerVisibilityPreferences preferences;
  @override
  State<WorkspaceWorkerVisibilitySection> createState() =>
      _WorkspaceWorkerVisibilitySectionState();
}

class _WorkspaceWorkerVisibilitySectionState
    extends State<WorkspaceWorkerVisibilitySection> {
  bool _loading = false, _saving = false, _loaded = false;
  Object? _error;
  AxWorkerVisibility _saved = AxWorkerVisibility();
  Set<String> _workers = {};
  Map<String, Set<String>> _models = {};
  Map<String, Map<String, Set<String>>> _efforts = {};
  void _adopt(AxWorkerVisibility value) {
    _saved = value;
    _workers = value.hiddenWorkers.toSet();
    _models = value.hiddenModels.map((k, v) => MapEntry(k, v.toSet()));
    _efforts = value.hiddenEfforts
        .map((k, v) => MapEntry(k, v.map((m, e) => MapEntry(m, e.toSet()))));
  }

  AxWorkerVisibility get _draft => AxWorkerVisibility(
      hiddenWorkers: _workers,
      hiddenModels: _models.map((k, v) => MapEntry(k, v.toList())),
      hiddenEfforts: _efforts.map(
          (k, v) => MapEntry(k, v.map((m, e) => MapEntry(m, e.toList())))));
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await widget.preferences.ensure();
      if (mounted) {
        setState(() {
          _adopt(value);
          _loaded = true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _write({bool reset = false}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (reset) {
        await widget.preferences.reset();
      } else {
        await widget.preferences.save(_draft);
      }
      final value =
          widget.preferences.engine.peek(widget.preferences.query).data!;
      if (mounted) setState(() => _adopt(value));
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toggle(Set<String> set, String id, bool visible) {
    setState(() {
      if (visible) {
        set.remove(id);
      } else {
        set.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final workers = widget.workers
        .where(
            (w) => w.workspaceId == widget.workspaceId && w.status != 'removed')
        .toList();
    return ExpansionTile(
      key: ValueKey('worker-visibility-${widget.workspaceId}'),
      title: const Text('Workers for me'),
      onExpansionChanged: (expanded) {
        if (expanded && !_loaded && !_loading) unawaited(_load());
      },
      children: [
        Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                  'Choose what appears in your selectors. This does not change sharing or member access.'),
              if (_loading)
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator()),
              if (_error != null) ...[
                Text('Could not update Worker visibility: $_error',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                if (!_loaded)
                  TextButton(
                      onPressed: _loading ? null : _load,
                      child: const Text('Retry'))
              ],
              if (_loaded) ...[
                if (workers.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('No Workers available in this Workspace.')),
                for (final worker in workers) _worker(worker),
                Wrap(spacing: 8, children: [
                  FilledButton(
                      onPressed: _saving ? null : () => _write(),
                      child: const Text('Save')),
                  TextButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                                _adopt(_saved);
                                _error = null;
                              }),
                      child: const Text('Cancel')),
                  OutlinedButton(
                      onPressed: _saving ? null : () => _write(reset: true),
                      child: const Text('Reset')),
                ]),
                if (_saving) const LinearProgressIndicator(),
              ]
            ]))
      ],
    );
  }

  Widget _worker(AxWorker worker) {
    final capability = capabilityForWorker(worker);
    final modelIds = <String>{
      ...capability.models.map((m) => m.id),
      ...?capability.allowedModelIds
    }.where(capability.supportsModel).toList();
    return ExpansionTile(
        title: Text(
            '${worker.displayName}${worker.isReady ? '' : ' · Offline or unavailable'}'),
        children: [
          SwitchListTile(
              title: Text('Show ${worker.displayName}'),
              value: !_workers.contains(worker.id),
              onChanged:
                  _saving ? null : (v) => _toggle(_workers, worker.id, v)),
          if (modelIds.isEmpty)
            const ListTile(title: Text('No model options available.')),
          for (final id in modelIds)
            ExpansionTile(
                title: Text(capability.model(id)?.name ?? id),
                children: [
                  SwitchListTile(
                      title: Text(
                          'Show model ${capability.model(id)?.name ?? id}'),
                      value: !(_models[worker.id]?.contains(id) ?? false),
                      onChanged: _saving
                          ? null
                          : (v) => _toggle(
                              _models.putIfAbsent(worker.id, () => {}), id, v)),
                  for (final effort in capability.effortsForModel(id))
                    SwitchListTile(
                        title: Text(
                            'Show ${capability.model(id)?.name ?? id} effort $effort'),
                        value: !(_efforts[worker.id]?[id]?.contains(effort) ??
                            false),
                        onChanged: _saving
                            ? null
                            : (v) => _toggle(
                                _efforts
                                    .putIfAbsent(worker.id, () => {})
                                    .putIfAbsent(id, () => {}),
                                effort,
                                v)),
                ]),
        ]);
  }
}
