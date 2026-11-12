import 'package:flutter/material.dart';

import '../../ax/ax_workflow_configuration.dart';

/// What the user chose in the Create Space dialog.
typedef CreateSpaceRequest = ({
  String name,
  String? description,
  String? workspaceId,
});

/// Asks for a Space name, description and the Workspace it may run Work on.
///
/// The Workspace is always an explicit choice: it starts at "No Workspace" and
/// is never preselected, because attaching a Workspace lets the Space's Work
/// run on that machine. With exactly one Workspace a one-click "Use …" action
/// is offered.
Future<CreateSpaceRequest?> showCreateSpaceDialog(
  BuildContext context, {
  required Future<List<AxWorkflowWorkspace>> Function() loadWorkspaces,
}) =>
    showDialog<CreateSpaceRequest>(
      context: context,
      builder: (_) => _CreateSpaceDialog(loadWorkspaces: loadWorkspaces),
    );

class _CreateSpaceDialog extends StatefulWidget {
  const _CreateSpaceDialog({required this.loadWorkspaces});
  final Future<List<AxWorkflowWorkspace>> Function() loadWorkspaces;

  @override
  State<_CreateSpaceDialog> createState() => _CreateSpaceDialogState();
}

class _CreateSpaceDialogState extends State<_CreateSpaceDialog> {
  late final Future<List<AxWorkflowWorkspace>> _workspaces =
      widget.loadWorkspaces();
  var _name = '';
  var _description = '';
  String? _workspaceId;

  void _submit() => Navigator.pop<CreateSpaceRequest>(context, (
        name: _name.trim().isEmpty ? 'My first space' : _name.trim(),
        description: _description.trim().isEmpty ? null : _description.trim(),
        workspaceId: _workspaceId,
      ));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Create Space'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              autofocus: true,
              onChanged: (value) => _name = value,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Space name'),
            ),
            const SizedBox(height: 12),
            TextField(
              onChanged: (value) => _description = value,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<AxWorkflowWorkspace>>(
              future: _workspaces,
              builder: (context, snapshot) {
                final workspaces = snapshot.data ?? const [];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String?>(
                      key: const ValueKey('create-space-workspace'),
                      initialValue: _workspaceId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Workspace'),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('No Workspace'),
                        ),
                        for (final workspace in workspaces)
                          DropdownMenuItem<String?>(
                            value: workspace.id,
                            child: Text(workspace.name,
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: snapshot.hasData
                          ? (value) => setState(() => _workspaceId = value)
                          : null,
                    ),
                    if (workspaces.length == 1 && _workspaceId == null)
                      TextButton(
                        key: const ValueKey('create-space-use-only-workspace'),
                        onPressed: () =>
                            setState(() => _workspaceId = workspaces.single.id),
                        child: Text('Use ${workspaces.single.name}'),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        snapshot.hasError
                            ? 'Workspaces could not be loaded. You can choose one later in Space settings.'
                            : _workspaceId == null
                                ? 'Work cannot run in this Space until you choose a Workspace.'
                                : 'Work in this Space will run on this Workspace.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
