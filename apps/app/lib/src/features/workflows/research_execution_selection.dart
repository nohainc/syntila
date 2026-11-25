import 'package:flutter/material.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_workflow_configuration.dart';
import '../../ax/model_presentation.dart';
import '../../ax/worker_presentation.dart';

/// Shows the configured roles instead of a single override for Research.
class ResearchExecutionSelection extends StatelessWidget {
  const ResearchExecutionSelection({
    super.key,
    required this.configuration,
    required this.workers,
    this.selections = const {},
    this.selectorBuilder,
    this.onChanged,
    this.researcherCount,
    this.onResearcherCountChanged,
  }) : implement = false;

  /// Implement's plan, implement and verify roles.
  const ResearchExecutionSelection.implement({
    super.key,
    required this.configuration,
    required this.workers,
    this.selections = const {},
    this.selectorBuilder,
    this.onChanged,
  })  : implement = true,
        researcherCount = null,
        onResearcherCountChanged = null;

  final bool implement;

  /// Research only: researchers to run (2 to 4) when the user chose a count
  /// for this request; null uses the configuration's count.
  final int? researcherCount;
  final ValueChanged<int>? onResearcherCountChanged;

  static const minResearchers = 2;
  static const maxResearchers = 4;

  int get _researchers =>
      (researcherCount ?? configuration?.researcherCount ?? minResearchers)
          .clamp(minResearchers, maxResearchers);

  final AxUserWorkflowConfiguration? configuration;
  final List<AxWorker> workers;

  /// Implement only: the user's choice per step. When [selectorBuilder] is
  /// set each step hosts that selector instead of a read-only summary.
  /// Research uses the same fields, keyed `research-N` and `synthesis`.
  final Map<String, Map<String, dynamic>> selections;
  final Widget Function(String step, Map<String, dynamic> current,
      ValueChanged<Map<String, dynamic>> onChanged)? selectorBuilder;
  final void Function(String step, Map<String, dynamic> selection)? onChanged;

  static const _implementSteps = [
    ('Plan', 'plan'),
    ('Implement', 'implement'),
    ('Verify', 'verify'),
  ];

  String? _workerIdForStep(String step) {
    final stepSelection = selections[step];
    if (stepSelection != null && stepSelection.containsKey('workerId')) {
      final chosen = stepSelection['workerId']?.toString().trim();
      return (chosen != null && chosen.isNotEmpty) ? chosen : null;
    }
    final configured = configuration?.selectionFor(step).worker?.trim();
    return (configured != null && configured.isNotEmpty) ? configured : null;
  }

  String? _modelForStep(String step) {
    final stepSelection = selections[step];
    final chosen = stepSelection?['model']?.toString().trim();
    if (chosen != null && chosen.isNotEmpty) {
      return chosen;
    }
    final configured = configuration?.selectionFor(step).model?.trim();
    return (configured != null && configured.isNotEmpty) ? configured : null;
  }

  AxWorker? _findWorker(String? workerId) {
    if (workerId == null) return null;
    return workers.where((w) => w.id == workerId).firstOrNull;
  }

  String _modelNameForStep(String stepId) {
    final modelId = _modelForStep(stepId);
    final worker = _findWorker(_workerIdForStep(stepId));
    final catalogModel = worker?.executionOptions?.models
        .where((m) => m.id == modelId)
        .firstOrNull;
    final modelDisplayName = catalogModel?.name;
    final presentation = ModelPresentation.resolve(
      modelId: modelId,
      modelDisplayName: modelDisplayName,
      fallbackWorkerTypeId: worker?.workerTypeId,
      fallbackWorkerDisplayName: worker?.displayName,
    );
    String rawName;
    if (modelDisplayName != null && modelDisplayName.isNotEmpty) {
      rawName = modelDisplayName;
    } else if (modelId != null && modelId.isNotEmpty) {
      rawName = presentation.name;
    } else {
      final defaultModel = worker?.executionOptions?.models.firstOrNull;
      if (defaultModel != null) {
        rawName =
            defaultModel.name.isNotEmpty ? defaultModel.name : defaultModel.id;
      } else {
        rawName = presentation.name;
      }
    }
    if (rawName.isEmpty) return '';
    var stripped = ModelPresentation.stripIdentity(rawName);
    final workerName = worker?.displayName.trim();
    if (workerName != null && workerName.isNotEmpty) {
      final workerPrefix = RegExp(
        '^${RegExp.escape(workerName)}[\\s\\-_:]*',
        caseSensitive: false,
      );
      final withoutWorkerFromRaw =
          rawName.replaceFirst(workerPrefix, '').trim();
      if (withoutWorkerFromRaw.isNotEmpty) {
        final strippedWithoutWorker =
            ModelPresentation.stripIdentity(withoutWorkerFromRaw);
        if (strippedWithoutWorker.isNotEmpty) {
          stripped = strippedWithoutWorker;
        }
      }
      final withoutWorker = stripped.replaceFirst(workerPrefix, '').trim();
      if (withoutWorker.isNotEmpty) {
        stripped = withoutWorker;
      }
    }
    return stripped;
  }

  /// The roles shown on the closed button: Implement's three steps, or each
  /// researcher and the synthesis.
  List<(String, String)> get _buttonSteps => implement
      ? _implementSteps
      : [
          for (var i = 1; i <= _researchers; i++)
            ('Researcher $i', 'research-$i'),
          ('Synthesis', 'synthesis'),
        ];

  bool get _allImplementStepsSelected {
    for (final (_, stepId) in _buttonSteps) {
      if (_workerIdForStep(stepId) == null) {
        return false;
      }
    }
    return true;
  }

  Widget _stepIcon(BuildContext context, String title, String stepId) {
    final workerId = _workerIdForStep(stepId);
    final worker = _findWorker(workerId);
    final presentation = WorkerPresentation.resolve(
      worker?.workerTypeId,
      worker?.displayName ?? workerId,
      profileDefinitionId: worker?.profileDefinitionId,
      providerToolName: worker?.providerToolName,
    );
    final asset =
        presentation.iconAssetForBrightness(Theme.of(context).brightness);
    final Widget iconWidget = asset == null
        ? const Icon(Icons.smart_toy_outlined, size: 16)
        : Image.asset(asset, width: 16, height: 16);
    final label = '$title: ${presentation.name}';
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: iconWidget,
      ),
    );
  }

  Widget _stepItem(BuildContext context, String title, String stepId) {
    final icon = _stepIcon(context, title, stepId);
    final modelName = _modelNameForStep(stepId);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        if (modelName.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(modelName),
        ],
      ],
    );
  }

  Widget _buildImplementButtonContent(BuildContext context) {
    if (!_allImplementStepsSelected) {
      return const Text('Select Workers');
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, (title, id)) in _buttonSteps.indexed) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text('·'),
            ),
          _stepItem(context, title, id),
        ],
      ],
    );
  }

  void _openDialog(BuildContext context) {
    final local = <String, Map<String, dynamic>>{};
    int? localCount;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(implement
              ? 'Implement execution selections'
              : 'Research execution selections'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (implement)
                    const Text(
                        'Implement plans in phases, then executes each phase and verifies it. Each role uses a fresh session with recent Thread history; older history may be omitted.')
                  else
                    const Text(
                        'Every message sent with Research starts a new investigation and a new synthesis after all researchers finish. Steps run in parallel as slots become available, or wait their turn. Each role uses a fresh session with recent Thread history; older history may be omitted.'),
                  const SizedBox(height: 12),
                  if (implement) ...[
                    for (final (title, id) in _implementSteps)
                      if (selectorBuilder != null)
                        _stepSelector(title, id, local, setDialogState)
                      else
                        _role(title, id),
                  ] else ...[
                    if (onResearcherCountChanged != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          const SizedBox(
                              width: 100, child: Text('Researchers')),
                          DropdownButton<int>(
                            isDense: true,
                            borderRadius: BorderRadius.circular(8),
                            underline: const SizedBox.shrink(),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                            key: const ValueKey('research-researcher-count'),
                            value: localCount ?? _researchers,
                            items: [
                              for (var n = minResearchers;
                                  n <= maxResearchers;
                                  n++)
                                DropdownMenuItem(value: n, child: Text('$n')),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(() => localCount = value);
                              onResearcherCountChanged!(value);
                            },
                          ),
                        ]),
                      ),
                    for (var i = 1; i <= (localCount ?? _researchers); i++)
                      if (selectorBuilder != null)
                        _stepSelector('Researcher $i', 'research-$i', local,
                            setDialogState)
                      else
                        _role('Researcher $i', 'research-$i'),
                    if (selectorBuilder != null)
                      _stepSelector(
                          'Synthesis', 'synthesis', local, setDialogState)
                    else
                      _role('Synthesis', 'synthesis'),
                  ],
                  if (selectorBuilder == null) ...[
                    const SizedBox(height: 12),
                    Text(
                        'To change these selections, use the Worker picker in the composer to change the Worker for ${implement ? 'Implement' : 'Research'}.'),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      foregroundColor: Theme.of(context).textTheme.bodySmall?.color ??
          Theme.of(context).colorScheme.onSurface,
      textStyle: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
    );
    if (implement) {
      return TextButton(
        key: const ValueKey('implement-execution-selection'),
        style: style,
        onPressed: () => _openDialog(context),
        child: _buildImplementButtonContent(context),
      );
    }
    return TextButton(
      key: const ValueKey('research-execution-selection'),
      style: style,
      onPressed: () => _openDialog(context),
      child: _buildImplementButtonContent(context),
    );
  }

  /// One step's choice, using the same selector as the composer.
  Widget _stepSelector(
      String title,
      String id,
      Map<String, Map<String, dynamic>> local,
      void Function(VoidCallback) setDialogState) {
    // Local copy so the dialog reflects a choice at once; the parent keeps
    // the authoritative value.
    final current = local[id] ?? selections[id] ?? const <String, dynamic>{};
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 120, child: Text(title, maxLines: 1, softWrap: false)),
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: KeyedSubtree(
              key: ValueKey('${implement ? 'implement' : 'research'}-step-$id'),
              child: selectorBuilder!(id, current, (value) {
                setDialogState(() => local[id] = value);
                onChanged?.call(id, value);
              }),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _role(String title, String id) {
    final selection = configuration?.selectionFor(id);
    final worker =
        workers.where((worker) => worker.id == selection?.worker).firstOrNull;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text([
        worker?.displayName ?? selection?.worker ?? 'Worker not configured',
        selection?.model ?? 'Model not configured',
        selection?.effort ?? 'Default effort',
      ].join(' · ')),
    );
  }
}
