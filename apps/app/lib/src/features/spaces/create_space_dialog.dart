import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';

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
                    Builder(builder: (context) {
                      final dark = theme.brightness == Brightness.dark;
                      final selected = workspaces
                          .where((w) => w.id == _workspaceId)
                          .firstOrNull;
                      return PopupMenuButton<String>(
                        key: const ValueKey('create-space-workspace'),
                        enabled: snapshot.hasData,
                        tooltip: 'Choose Workspace',
                        color: SyntilaColors.composerBackground(dark),
                        surfaceTintColor: Colors.transparent,
                        elevation: 12,
                        shadowColor: SyntilaMenuStyle.shadow(dark),
                        shape: SyntilaMenuStyle.shape(dark),
                        menuPadding: SyntilaMenuStyle.padding,
                        itemBuilder: (context) => [
                          for (final choice in <String, String>{
                            '': 'No Workspace',
                            for (final w in workspaces) w.id: w.name,
                          }.entries)
                            SyntilaMenuEntry<String>(
                              value: choice.key,
                              child: MenuItemButton(
                                style: SyntilaMenuStyle.item(dark),
                                leadingIcon: Icon(
                                  choice.key == (_workspaceId ?? '')
                                      ? Icons.check_circle_rounded
                                      : Icons.circle_outlined,
                                  size: 15,
                                ),
                                onPressed: () =>
                                    Navigator.pop(context, choice.key),
                                child: Text(choice.value,
                                    style: SyntilaMenuStyle.textStyle),
                              ),
                            ),
                        ],
                        onSelected: (value) => setState(
                            () => _workspaceId = value.isEmpty ? null : value),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                              labelText: 'Workspace',
                              suffixIcon: Icon(Icons.expand_more)),
                          child: Text(selected?.name ?? 'No Workspace',
                              overflow: TextOverflow.ellipsis),
                        ),
                      );
                    }),
                    if (snapshot.hasError)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Workspaces could not be loaded. You can choose one later in Space settings.',
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
