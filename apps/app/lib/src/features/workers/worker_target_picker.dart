import 'package:flutter/material.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_session_catalogs.dart';

/// Why a Worker cannot take the request, or null when it can be chosen.
enum WorkerPickerState { available, offline, disabled, revoked, notEligible }

WorkerPickerState workerPickerState(
  WorkerInstance worker,
  Set<String> eligibleIds,
) {
  if (worker.isRevoked) return WorkerPickerState.revoked;
  if (!worker.enabled) return WorkerPickerState.disabled;
  if (eligibleIds.contains(worker.id)) return WorkerPickerState.available;
  return worker.online
      ? WorkerPickerState.notEligible
      : WorkerPickerState.offline;
}

String workerPickerStateLabel(WorkerPickerState state) => switch (state) {
      WorkerPickerState.available => 'Online',
      WorkerPickerState.offline => 'Offline',
      WorkerPickerState.disabled => 'Disabled',
      WorkerPickerState.revoked => 'Revoked',
      WorkerPickerState.notEligible => 'Cannot run this request',
    };

/// Short, stable suffix that tells two Workers with the same name apart.
String workerShortId(String id) =>
    id.length <= 4 ? id : id.substring(id.length - 4);

/// One line per Worker. A name shared by several Workers is extended with the
/// Type, the alias and a short ID suffix until every line is distinct; the
/// selection itself is always by ID.
Map<String, String> workerPickerLabels(List<WorkerInstance> workers) {
  final byName = <String, List<WorkerInstance>>{};
  for (final worker in workers) {
    byName.putIfAbsent(worker.name.trim().toLowerCase(), () => []).add(worker);
  }
  final labels = <String, String>{};
  for (final group in byName.values) {
    if (group.length == 1) {
      labels[group.single.id] = group.single.name;
      continue;
    }
    final seen = <String, int>{};
    final base = <String, String>{
      for (final worker in group)
        worker.id: [
          worker.name,
          worker.workerTypeName,
          if (worker.description.trim().isNotEmpty) worker.description.trim(),
        ].join(' · '),
    };
    for (final label in base.values) {
      seen[label] = (seen[label] ?? 0) + 1;
    }
    for (final worker in group) {
      final label = base[worker.id]!;
      labels[worker.id] =
          seen[label]! > 1 ? '$label · #${workerShortId(worker.id)}' : label;
    }
  }
  return labels;
}

/// The Thread composer's Worker control: the Workers the server says can run
/// this Workflow, plus the owner's other Workers shown disabled with the
/// reason. No Workspace appears anywhere.
class WorkerTargetPicker extends StatefulWidget {
  const WorkerTargetPicker({
    super.key,
    required this.catalogs,
    required this.threadId,
    required this.workflowId,
    required this.loadEligibleIds,
    required this.selectedId,
    required this.onChanged,
    this.sharedWorkers = const [],
    this.enabled = true,
  });

  final AxSessionCatalogs catalogs;
  final String threadId;
  final String workflowId;
  final Future<List<String>> Function(String threadId, String workflowId)
      loadEligibleIds;
  final String? selectedId;
  final ValueChanged<String?> onChanged;
  final List<WorkerInstance> sharedWorkers;
  final bool enabled;

  @override
  State<WorkerTargetPicker> createState() => _WorkerTargetPickerState();
}

class _WorkerTargetPickerState extends State<WorkerTargetPicker> {
  Set<String> _eligible = const {};
  Object? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WorkerTargetPicker old) {
    super.didUpdateWidget(old);
    if (old.threadId != widget.threadId ||
        old.workflowId != widget.workflowId) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ids =
          await widget.loadEligibleIds(widget.threadId, widget.workflowId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _eligible = ids.toSet();
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _eligible = const {};
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    widget.catalogs.engine.refresh(widget.catalogs.workerInstances).ignore();
    await _load();
  }

  @override
  Widget build(BuildContext context) => AxQueryBuilder<List<WorkerInstance>>(
        engine: widget.catalogs.engine,
        query: widget.catalogs.workerInstances,
        builder: (context, state) {
          final seenIds = <String>{};
          final workers = <WorkerInstance>[
            for (final worker in [
              ...(state.data ?? const <WorkerInstance>[]),
              ...widget.sharedWorkers,
            ])
              if ((!worker.isRevoked || worker.id == widget.selectedId) &&
                  seenIds.add(worker.id))
                worker,
          ];
          if (state.data == null) {
            return const Text('Loading Workers…',
                style: TextStyle(fontSize: 12.5));
          }
          if (workers.isEmpty) {
            return const Text('Add a Worker to ask from this Thread',
                key: ValueKey('worker-picker-empty'),
                style: TextStyle(fontSize: 12.5));
          }
          final labels = workerPickerLabels(workers);
          final selected =
              workers.where((w) => w.id == widget.selectedId).firstOrNull;
          final selectedState =
              selected == null ? null : workerPickerState(selected, _eligible);
          final title =
              selected == null ? 'Choose a Worker' : labels[selected.id]!;
          return PopupMenuButton<String>(
            key: const ValueKey('worker-picker'),
            enabled: widget.enabled,
            tooltip: 'Worker',
            onOpened: _refresh,
            onSelected: widget.onChanged,
            itemBuilder: (context) => [
              if (_loading)
                const PopupMenuItem<String>(
                    enabled: false, child: Text('Checking Workers…')),
              if (_error != null)
                const PopupMenuItem<String>(
                    enabled: false,
                    child: Text('Could not check which Workers can run this')),
              for (final worker in workers) _item(worker, labels[worker.id]!),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                ),
                if (selectedState != null &&
                    selectedState != WorkerPickerState.available) ...[
                  const SizedBox(width: 6),
                  Text(workerPickerStateLabel(selectedState),
                      key: const ValueKey('worker-picker-selected-status'),
                      style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).colorScheme.error)),
                ],
                const Icon(Icons.arrow_drop_down, size: 18),
              ]),
            ),
          );
        },
      );

  PopupMenuItem<String> _item(WorkerInstance worker, String label) {
    final state = workerPickerState(worker, _eligible);
    return PopupMenuItem<String>(
      value: worker.id,
      enabled: state == WorkerPickerState.available ||
          worker.id == widget.selectedId,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5)),
          Text('${worker.workerTypeName} · ${workerPickerStateLabel(state)}',
              style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
