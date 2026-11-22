import 'package:flutter/material.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import '../../ax/ax_models.dart';

/// The models a Worker reported, in the order the selector lists them.
List<AxWorkerModelOption> workerModelOptions(WorkerInstance worker) {
  final json = worker.executionOptions;
  if (json == null) return const [];
  try {
    return AxWorkerExecutionOptions.fromJson(Map<String, dynamic>.from(json))
        .models
        .where((m) => m.status != 'unavailable')
        .toList(growable: false);
  } on Object {
    return const [];
  }
}

/// Model and effort checkbox table shared by the Worker's own selector
/// visibility and the per-Space member limits. [keyPrefix] namespaces the
/// checkbox keys so both can be on screen at once.
class WorkerModelVisibilityTable extends StatelessWidget {
  const WorkerModelVisibilityTable({
    super.key,
    required this.models,
    required this.hiddenModels,
    required this.hiddenEfforts,
    required this.keyPrefix,
    required this.editable,
    required this.onModelChanged,
    required this.onEffortChanged,
    this.modelColumnTitle = 'Model',
    this.visibleColumnTitle = 'Visible',
  });

  final List<AxWorkerModelOption> models;
  final Set<String> hiddenModels;
  final Map<String, Set<String>> hiddenEfforts;
  final String keyPrefix;
  final bool editable;
  final void Function(String modelId, bool visible) onModelChanged;
  final void Function(String modelId, String effort, bool visible)
      onEffortChanged;
  final String modelColumnTitle;
  final String visibleColumnTitle;

  static String _effortTitle(String eff) =>
      eff.isEmpty ? eff : eff[0].toUpperCase() + eff.substring(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allEfforts = <String>[];
    for (final model in models) {
      for (final eff in model.effort.values) {
        if (!allEfforts.contains(eff)) allEfforts.add(eff);
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 40,
            dataRowMaxHeight: 44,
            columnSpacing: 20,
            columns: [
              DataColumn(label: Text(modelColumnTitle)),
              DataColumn(label: Center(child: Text(visibleColumnTitle))),
              for (final eff in allEfforts)
                DataColumn(label: Center(child: Text(_effortTitle(eff)))),
            ],
            rows: [
              for (final model in models) _row(theme, model, allEfforts),
            ],
          ),
        ),
      ),
    );
  }

  DataRow _row(
    ThemeData theme,
    AxWorkerModelOption model,
    List<String> allEfforts,
  ) {
    final isModelVisible = !hiddenModels.contains(model.id);
    final supportsEffort =
        model.effort.supported && model.effort.values.isNotEmpty;
    return DataRow(
      cells: [
        DataCell(Text(model.name)),
        DataCell(Center(
          child: Checkbox(
            key: ValueKey('$keyPrefix-model-${model.id}'),
            value: isModelVisible,
            onChanged:
                editable ? (v) => onModelChanged(model.id, v ?? false) : null,
          ),
        )),
        for (final eff in allEfforts)
          DataCell(Center(
            child: isModelVisible &&
                    supportsEffort &&
                    model.effort.values.contains(eff)
                ? Checkbox(
                    key: ValueKey('$keyPrefix-effort-${model.id}-$eff'),
                    value: !(hiddenEfforts[model.id]?.contains(eff) ?? false),
                    onChanged: editable
                        ? (v) => onEffortChanged(model.id, eff, v ?? false)
                        : null,
                  )
                : Text('—', style: TextStyle(color: theme.disabledColor)),
          )),
      ],
    );
  }
}
