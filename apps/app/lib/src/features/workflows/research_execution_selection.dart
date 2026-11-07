import 'package:flutter/material.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_workflow_configuration.dart';

/// Shows the configured roles instead of a single override for Research.
class ResearchExecutionSelection extends StatelessWidget {
  const ResearchExecutionSelection({
    super.key,
    required this.configuration,
    required this.workers,
  }) : implement = false;

  /// Implement's plan, implement and verify roles.
  const ResearchExecutionSelection.implement({
    super.key,
    required this.configuration,
    required this.workers,
  }) : implement = true;

  final bool implement;

  final AxUserWorkflowConfiguration? configuration;
  final List<AxWorker> workers;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        key: ValueKey(implement
            ? 'implement-execution-selection'
            : 'research-execution-selection'),
        icon: const Icon(Icons.tune, size: 16),
        label: Text(implement ? 'Implement executions' : 'Research executions'),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
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
                          'Implement plans in phases, then executes each phase and verifies it. Each role uses a fresh session with recent Thread history; older history may be omitted. Selections follow this Space’s Workspace workflows.')
                    else
                      const Text(
                          'Every message sent with Research starts a new investigation and a new synthesis after all researchers finish. Steps run in parallel as slots become available, or wait their turn. Each role uses a fresh session with recent Thread history; older history may be omitted. Each researcher uses a different model. Selections follow this Space’s Workspace workflows.'),
                    const SizedBox(height: 12),
                    if (implement) ...[
                      _role('Plan', 'plan'),
                      _role('Implement', 'implement'),
                      _role('Verify', 'verify'),
                    ] else ...[
                      for (var i = 1;
                          i <= (configuration?.researcherCount ?? 2);
                          i++)
                        _role('Researcher $i', 'research-$i'),
                      _role('Synthesis', 'synthesis'),
                    ],
                    const SizedBox(height: 12),
                    Text(
                        'To change these selections, open the Workspace’s Workflows tab and edit ${implement ? 'Implement' : 'Research'}.'),
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
