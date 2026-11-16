import 'dart:async';
import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_worker_visibility.dart';
import '../../ax/sync/ax_worker_visibility_preferences.dart';
import '../../ax/worker_presentation.dart';

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
    final theme = Theme.of(context);
    final workers = widget.workers
        .where(
            (w) => w.workspaceId == widget.workspaceId && w.status != 'removed')
        .toList();
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
        ),
        child: ExpansionTile(
          key: ValueKey('worker-visibility-${widget.workspaceId}'),
          expansionAnimationStyle: AnimationStyle.noAnimation,
          leading: const Icon(Icons.visibility_outlined),
          title: Text('My Workers',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          expandedAlignment: Alignment.centerLeft,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          onExpansionChanged: (expanded) {
            if (expanded && !_loaded && !_loading) unawaited(_load());
          },
          children: [
            const Text(
                'Choose what appears in your selectors. This does not change sharing or member access.'),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator()),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text('Could not update Worker visibility: $_error',
                  style: TextStyle(color: theme.colorScheme.error)),
              if (!_loaded)
                TextButton(
                    onPressed: _loading ? null : _load,
                    child: const Text('Retry'))
            ],
            if (_loaded) ...[
              const SizedBox(height: 12),
              if (workers.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('No Workers available in this Workspace.'))
              else
                _buildVisibilityGrid(context, workers),
              const SizedBox(height: 12),
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
              if (_saving) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
            ]
          ],
        ),
      ),
    );
  }

  Widget _workerIconWidget(BuildContext context, AxWorker worker) {
    final presentation = WorkerPresentation.resolve(
      worker.workerTypeId,
      worker.displayName,
      profileDefinitionId: worker.profileDefinitionId,
      providerToolName: worker.providerToolName,
    );
    final workerIcon =
        presentation.iconAssetForBrightness(Theme.of(context).brightness);
    if (workerIcon != null) {
      return Image.asset(
        workerIcon,
        width: 20,
        height: 20,
        fit: BoxFit.contain,
        semanticLabel: '${worker.displayName} icon',
      );
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Icon(
      worker.isReady ? Icons.smart_toy_outlined : Icons.warning_amber,
      size: 20,
      color: worker.isReady
          ? theme.colorScheme.primary
          : SyntilaColors.warningText(isDark),
    );
  }

  Widget _buildVisibilityGrid(BuildContext context, List<AxWorker> workers) {
    final theme = Theme.of(context);
    final allEfforts = <String>[];
    for (final worker in workers) {
      final models =
          (worker.executionOptions?.models ?? const <AxWorkerModelOption>[])
              .where((m) => m.status != 'unavailable');
      for (final model in models) {
        for (final eff in model.effort.values) {
          if (!allEfforts.contains(eff)) allEfforts.add(eff);
        }
      }
    }

    String effortTitle(String eff) {
      if (eff.isEmpty) return eff;
      return eff[0].toUpperCase() + eff.substring(1);
    }

    final rows = <DataRow>[];
    for (final worker in workers) {
      final isWorkerVisible = !_workers.contains(worker.id);
      final models =
          (worker.executionOptions?.models ?? const <AxWorkerModelOption>[])
              .where((m) => m.status != 'unavailable')
              .toList(growable: false);

      rows.add(
        DataRow(
          color: WidgetStateProperty.resolveWith(
            (states) => theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.35),
          ),
          cells: [
            DataCell(Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _workerIconWidget(context, worker),
                const SizedBox(width: 8),
                Text(
                  worker.displayName.trim().isNotEmpty
                      ? worker.displayName
                      : WorkerPresentation.resolve(
                          worker.workerTypeId,
                          worker.displayName,
                          profileDefinitionId: worker.profileDefinitionId,
                          providerToolName: worker.providerToolName,
                        ).name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            )),
            DataCell(Center(
              child: Checkbox(
                key: ValueKey('visibility-worker-${worker.id}'),
                value: isWorkerVisible,
                onChanged: _saving
                    ? null
                    : (v) => _toggle(_workers, worker.id, v ?? false),
              ),
            )),
            for (final _ in allEfforts)
              DataCell(Center(
                child: Text('—', style: TextStyle(color: theme.disabledColor)),
              )),
          ],
        ),
      );

      for (final model in models) {
        final isModelVisible = isWorkerVisible &&
            !(_models[worker.id]?.contains(model.id) ?? false);
        final supportsEffort =
            model.effort.supported && model.effort.values.isNotEmpty;

        rows.add(
          DataRow(
            cells: [
              DataCell(Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.subdirectory_arrow_right,
                        size: 16, color: theme.colorScheme.outline),
                    const SizedBox(width: 8),
                    Text(
                      model.name,
                      style: TextStyle(
                        color: isWorkerVisible ? null : theme.disabledColor,
                      ),
                    ),
                  ],
                ),
              )),
              DataCell(Center(
                child: Checkbox(
                  key: ValueKey('visibility-model-${model.id}-${worker.id}'),
                  value: isModelVisible,
                  onChanged: !isWorkerVisible || _saving
                      ? null
                      : (v) => _toggle(
                          _models.putIfAbsent(worker.id, () => {}),
                          model.id,
                          v ?? false),
                ),
              )),
              for (final eff in allEfforts)
                DataCell(Center(
                  child: isModelVisible &&
                          supportsEffort &&
                          model.effort.values.contains(eff)
                      ? Checkbox(
                          key: ValueKey(
                              'visibility-effort-${model.id}-$eff-${worker.id}'),
                          value: !(_efforts[worker.id]?[model.id]
                                  ?.contains(eff) ??
                              false),
                          onChanged: _saving
                              ? null
                              : (v) => _toggle(
                                  _efforts
                                      .putIfAbsent(worker.id, () => {})
                                      .putIfAbsent(model.id, () => {}),
                                  eff,
                                  v ?? false),
                        )
                      : Text('—', style: TextStyle(color: theme.disabledColor)),
                )),
            ],
          ),
        );
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: DataTable(
            columnSpacing: 16,
            horizontalMargin: 12,
            headingRowColor: WidgetStateProperty.all(
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
            columns: [
              const DataColumn(
                label: Text('Worker / Model',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const DataColumn(
                label: Center(
                  child: Text('Show',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              for (final eff in allEfforts)
                DataColumn(
                  label: Center(
                    child: Text(effortTitle(eff),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
            rows: rows,
          ),
        ),
      ),
    );
  }
}
