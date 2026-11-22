import 'package:flutter/material.dart';

import '../../ax/ax_data.dart' show AxApiException;
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
///
/// With [create], the dialog stays open while the Space is created and shows
/// the server's validation problems next to the fields they concern; it
/// closes only once [create] succeeds.
Future<CreateSpaceRequest?> showCreateSpaceDialog(
  BuildContext context, {
  required Future<List<AxWorkflowWorkspace>> Function() loadWorkspaces,
  Future<void> Function(CreateSpaceRequest request)? create,
  bool showWorkspace = true,
}) =>
    showDialog<CreateSpaceRequest>(
      context: context,
      builder: (_) => _CreateSpaceDialog(
          loadWorkspaces: loadWorkspaces,
          create: create,
          showWorkspace: showWorkspace),
    );

class _CreateSpaceDialog extends StatefulWidget {
  const _CreateSpaceDialog(
      {required this.loadWorkspaces, this.create, this.showWorkspace = true});
  final bool showWorkspace;
  final Future<List<AxWorkflowWorkspace>> Function() loadWorkspaces;
  final Future<void> Function(CreateSpaceRequest request)? create;

  @override
  State<_CreateSpaceDialog> createState() => _CreateSpaceDialogState();
}

class _CreateSpaceDialogState extends State<_CreateSpaceDialog> {
  late final Future<List<AxWorkflowWorkspace>> _workspaces =
      widget.loadWorkspaces();
  var _name = '';
  var _description = '';
  String? _workspaceId;
  var _busy = false;

  /// Server problems by request field (`name`, `description`, `workspaceId`).
  var _fieldErrors = const <String, String>{};
  String? _error;
  static const _fields = {'name', 'description', 'workspaceId'};

  Future<void> _submit() async {
    if (_busy) return;
    final CreateSpaceRequest request = (
      name: _name.trim().isEmpty ? 'My first space' : _name.trim(),
      description: _description.trim().isEmpty ? null : _description.trim(),
      workspaceId: _workspaceId,
    );
    final create = widget.create;
    if (create == null) {
      Navigator.pop<CreateSpaceRequest>(context, request);
      return;
    }
    setState(() {
      _busy = true;
      _fieldErrors = const {};
      _error = null;
    });
    try {
      await create(request);
      if (mounted) Navigator.pop<CreateSpaceRequest>(context, request);
    } on AxApiException catch (error) {
      if (!mounted) return;
      final fields = <String, String>{};
      final other = <String>[];
      for (final detail in error.details) {
        final field = detail.path.split('.').first;
        if (_fields.contains(field)) {
          fields[field] ??= detail.message;
        } else {
          other.add(detail.toString());
        }
      }
      setState(() {
        _busy = false;
        _fieldErrors = fields;
        _error = other.isNotEmpty
            ? other.join('; ')
            : fields.isEmpty
                ? error.message
                : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

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
              decoration: InputDecoration(
                labelText: 'Space name',
                errorText: _fieldErrors['name'],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              onChanged: (value) => _description = value,
              decoration: InputDecoration(
                labelText: 'Description (optional)',
                errorText: _fieldErrors['description'],
              ),
              maxLines: 2,
            ),
            if (widget.showWorkspace) const SizedBox(height: 12),
            if (widget.showWorkspace)
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
                        decoration: InputDecoration(
                          labelText: 'Workspace',
                          errorText: _fieldErrors['workspaceId'],
                        ),
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
                          key:
                              const ValueKey('create-space-use-only-workspace'),
                          onPressed: () => setState(
                              () => _workspaceId = workspaces.single.id),
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  key: const ValueKey('create-space-error'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Creating…' : 'Create'),
        ),
      ],
    );
  }
}
