import 'dart:async';

import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';

import '../../ax/ax_models.dart';
import '../../ax/ax_workspace_member_access.dart';
import '../../ax/worker_presentation.dart';
import '../common/quiet_notices.dart';

/// Owner control for what invited Space members can use on a Workspace. When
/// unrestricted, members use whatever the owner's workflows select. When
/// restricted, only the listed Workers, models and efforts can run for them;
/// Cloud enforces this when a request is created.
class WorkspaceMemberAccessSection extends StatefulWidget {
  const WorkspaceMemberAccessSection({
    super.key,
    required this.workspaceId,
    required this.workers,
    required this.source,
    this.personSource,
    this.userId,
    this.personName,
    this.expandable = false,
  }) : assert((personSource == null) == (userId == null));

  final String workspaceId;
  final List<AxWorker> workers;
  final AxWorkspaceMemberAccessDataSource source;

  /// When set, edits one person's access instead of the Workspace default:
  /// the policy always applies (no "limit" switch) and can be reset to the
  /// default.
  final AxWorkspacePersonAccessDataSource? personSource;
  final String? userId;
  final String? personName;

  /// Collapse the section behind an expandable header (the Workspace page).
  final bool expandable;

  @override
  State<WorkspaceMemberAccessSection> createState() =>
      _WorkspaceMemberAccessSectionState();
}

class _WorkspaceMemberAccessSectionState
    extends State<WorkspaceMemberAccessSection> {
  bool _loading = true;
  bool _saving = false;
  Object? _error;
  AxWorkspaceMemberAccess _saved = const AxWorkspaceMemberAccess();
  String? _mode;
  Map<String, AxSharedWorker> _workers = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(WorkspaceMemberAccessSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceId != widget.workspaceId) unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final workspaceId = widget.workspaceId;
    try {
      final person = widget.personSource;
      final access = person == null
          ? await widget.source.loadWorkspaceMemberAccess(workspaceId)
          : _personAccess(
              await person.loadPersonAccess(workspaceId, widget.userId!));
      if (!mounted || workspaceId != widget.workspaceId) return;
      setState(() => _adopt(access));
    } catch (error) {
      if (mounted && workspaceId == widget.workspaceId) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && workspaceId == widget.workspaceId) {
        setState(() => _loading = false);
      }
    }
  }

  /// A person's policy always applies, so it is edited as a restricted one that
  /// starts at the safest mode.
  AxWorkspaceMemberAccess _personAccess(AxPersonAccess person) {
    _custom = person.custom;
    return AxWorkspaceMemberAccess(
        restricted: true,
        mode: person.access.mode ?? 'chat',
        workers: person.access.workers);
  }

  bool _custom = false;
  bool get _isPerson => widget.personSource != null;

  Future<void> _reset() async {
    setState(() => _saving = true);
    try {
      final next = await widget.personSource!
          .resetPersonAccess(widget.workspaceId, widget.userId!);
      if (mounted) setState(() => _adopt(_personAccess(next)));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _adopt(AxWorkspaceMemberAccess access) {
    _saved = access;
    // Limits always apply. The mode is not edited here; it keeps its saved
    // value, starting at the safest one (ADR-020).
    _mode = access.mode ?? 'chat';
    _workers = Map.of(access.workers);
  }

  bool get _dirty =>
      !_saved.restricted || !_sameWorkers(_workers, _saved.workers);

  static bool _sameWorkers(
      Map<String, AxSharedWorker> a, Map<String, AxSharedWorker> b) {
    if (a.length != b.length) return false;
    bool same(List<String>? x, List<String>? y) => x == null || y == null
        ? x == y
        : x.length == y.length && x.toSet().containsAll(y);
    bool sameMap(
        Map<String, List<String>?>? m1, Map<String, List<String>?>? m2) {
      final clean1 = m1 == null || m1.isEmpty
          ? null
          : Map.fromEntries(m1.entries.where((e) => e.value != null));
      final clean2 = m2 == null || m2.isEmpty
          ? null
          : Map.fromEntries(m2.entries.where((e) => e.value != null));
      if (clean1 == null || clean1.isEmpty) {
        return clean2 == null || clean2.isEmpty;
      }
      if (clean2 == null || clean1.length != clean2.length) return false;
      for (final entry in clean1.entries) {
        if (!clean2.containsKey(entry.key) ||
            !same(entry.value, clean2[entry.key])) {
          return false;
        }
      }
      return true;
    }

    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null ||
          !same(entry.value.models, other.models) ||
          !same(entry.value.efforts, other.efforts) ||
          !sameMap(entry.value.modelEfforts, other.modelEfforts)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final next = AxWorkspaceMemberAccess(
          restricted: true, mode: _mode, workers: _workers);
      final person = widget.personSource;
      final access = person == null
          ? await widget.source
              .saveWorkspaceMemberAccess(widget.workspaceId, next)
          : _personAccess(await person.savePersonAccess(
              widget.workspaceId, widget.userId!, next));
      if (mounted) setState(() => _adopt(access));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Toggle [value] in a null-means-all list limited to [all].
  List<String>? _toggle(List<String>? current, String value, List<String> all) {
    final selected = Set<String>.of(current ?? all);
    if (!selected.remove(value)) selected.add(value);
    // Everything selected is the same as sharing all of them.
    return selected.length == all.length ? null : selected.toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workers = widget.workers
        .where((worker) =>
            worker.workspaceId == widget.workspaceId &&
            worker.status != 'removed')
        .toList(growable: false);
    final title = _isPerson
        ? 'Access for ${widget.personName ?? 'this person'}'
        : 'Member access';
    final body = <Widget>[
      Text(
          _isPerson
              ? (_custom
                  ? 'Custom access replaces the Workspace default for this person.'
                  : 'This person follows the Workspace default until you save custom access.')
              : 'Choose which Workers, models and efforts invited Space members can use on this Workspace. You are never limited. What they may do (chat, work, commands) is set per Space.',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 8),
      if (_loading)
        const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()))
      else if (_error != null)
        Row(children: [
          const Expanded(child: Text('Member access could not be loaded.')),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ])
      else ...[
        if (workers.isEmpty)
          Text('This Workspace has no Workers to share yet.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant))
        else
          _buildAccessGrid(context, workers),
        const SizedBox(height: 8),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                key: const ValueKey('member-access-save'),
                onPressed: _dirty && !_saving ? _save : null,
                child: const Text('Save access'))),
        if (_isPerson && _custom)
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  key: const ValueKey('person-access-reset'),
                  onPressed: _saving ? null : _reset,
                  child: const Text('Reset to default'))),
      ],
    ];
    if (widget.expandable) {
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
            key: const ValueKey('member-access-expansion'),
            expansionAnimationStyle: AnimationStyle.noAnimation,
            leading: const Icon(Icons.tune),
            title: Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            expandedAlignment: Alignment.centerLeft,
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: body,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        ...body,
      ],
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

  Widget _buildAccessGrid(BuildContext context, List<AxWorker> workers) {
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
      if (models.isEmpty &&
          (worker.executionOptions?.effort.supported ?? false)) {
        for (final eff in worker.executionOptions!.effort.values) {
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
      final shared = _workers[worker.id];
      final models =
          (worker.executionOptions?.models ?? const <AxWorkerModelOption>[])
              .where((m) => m.status != 'unavailable')
              .toList(growable: false);
      final modelIds = [for (final m in models) m.id];
      final isWorkerShared = shared != null;

      // Worker header row
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
                key: ValueKey('share-worker-${worker.id}'),
                value: isWorkerShared,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          if (value == true) {
                            _workers[worker.id] = const AxSharedWorker();
                          } else {
                            _workers.remove(worker.id);
                          }
                        }),
              ),
            )),
            for (final eff in allEfforts)
              DataCell(Center(
                child: models.isEmpty &&
                        (worker.executionOptions?.effort.values.contains(eff) ??
                            false)
                    ? Checkbox(
                        key: ValueKey('member-effort-$eff-${worker.id}'),
                        value: isWorkerShared &&
                            (shared.efforts == null ||
                                shared.efforts!.contains(eff)),
                        onChanged: !isWorkerShared || _saving
                            ? null
                            : (value) {
                                final next = _toggle(shared.efforts, eff,
                                    worker.executionOptions!.effort.values);
                                setState(
                                    () => _workers[worker.id] = AxSharedWorker(
                                          models: shared.models,
                                          efforts: next,
                                          modelEfforts: shared.modelEfforts,
                                        ));
                              },
                      )
                    : Text('—', style: TextStyle(color: theme.disabledColor)),
              )),
          ],
        ),
      );

      // Model rows
      for (final model in models) {
        final isModelShared = isWorkerShared &&
            (shared.models == null || shared.models!.contains(model.id));
        final supportsEffort =
            model.effort.supported && model.effort.values.isNotEmpty;

        List<String>? currentEfforts;
        if (shared != null &&
            shared.modelEfforts != null &&
            shared.modelEfforts!.containsKey(model.id)) {
          currentEfforts = shared.modelEfforts![model.id];
        } else if (shared != null && shared.efforts != null) {
          final filtered =
              shared.efforts!.where(model.effort.values.contains).toList();
          currentEfforts =
              filtered.length == model.effort.values.length ? null : filtered;
        }

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
                        color: isWorkerShared ? null : theme.disabledColor,
                      ),
                    ),
                  ],
                ),
              )),
              DataCell(Center(
                child: Checkbox(
                  key: ValueKey('member-model-${model.id}-${worker.id}'),
                  value: isModelShared,
                  onChanged: !isWorkerShared || _saving
                      ? null
                      : (value) {
                          final nextModels =
                              _toggle(shared.models, model.id, modelIds);
                          Map<String, List<String>?>? nextModelEfforts;
                          if (shared.modelEfforts != null) {
                            final activeSet = nextModels == null
                                ? null
                                : Set<String>.of(nextModels);
                            nextModelEfforts = Map.fromEntries(
                              shared.modelEfforts!.entries.where(
                                (e) =>
                                    activeSet == null ||
                                    activeSet.contains(e.key),
                              ),
                            );
                            if (nextModelEfforts.isEmpty) {
                              nextModelEfforts = null;
                            }
                          }
                          setState(() => _workers[worker.id] = AxSharedWorker(
                                models: nextModels,
                                efforts: shared.efforts,
                                modelEfforts: nextModelEfforts,
                              ));
                        },
                ),
              )),
              for (final eff in allEfforts)
                DataCell(Center(
                  child: isModelShared &&
                          supportsEffort &&
                          model.effort.values.contains(eff)
                      ? Checkbox(
                          key: ValueKey(
                              'member-effort-${model.id}-$eff-${worker.id}'),
                          value: currentEfforts == null ||
                              currentEfforts.contains(eff),
                          onChanged: _saving
                              ? null
                              : (value) {
                                  final nextEfforts = _toggle(
                                      currentEfforts, eff, model.effort.values);
                                  final next = Map<String, List<String>?>.of(
                                      shared.modelEfforts ?? {});
                                  if (nextEfforts == null) {
                                    if (shared.efforts != null) {
                                      next[model.id] = null;
                                    } else {
                                      next.remove(model.id);
                                    }
                                  } else {
                                    next[model.id] = nextEfforts;
                                  }
                                  setState(() =>
                                      _workers[worker.id] = AxSharedWorker(
                                        models: shared.models,
                                        efforts: shared.efforts,
                                        modelEfforts:
                                            next.isEmpty ? null : next,
                                      ));
                                },
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
                  child: Text('Share',
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
