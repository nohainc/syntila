import 'package:flutter/material.dart';

import '../../ax/ax_data.dart' show AxApiException;

/// What the user chose in the Create Space dialog.
typedef CreateSpaceRequest = ({
  String name,
  String? description,
});

/// Asks for a Space name and optional description.
///
/// With [create], the dialog stays open while the Space is created and shows
/// the server's validation problems next to the fields they concern; it
/// closes only once [create] succeeds.
Future<CreateSpaceRequest?> showCreateSpaceDialog(
  BuildContext context, {
  Future<void> Function(CreateSpaceRequest request)? create,
}) =>
    showDialog<CreateSpaceRequest>(
      context: context,
      builder: (_) => _CreateSpaceDialog(create: create),
    );

class _CreateSpaceDialog extends StatefulWidget {
  const _CreateSpaceDialog({this.create});
  final Future<void> Function(CreateSpaceRequest request)? create;

  @override
  State<_CreateSpaceDialog> createState() => _CreateSpaceDialogState();
}

class _CreateSpaceDialogState extends State<_CreateSpaceDialog> {
  var _name = '';
  var _description = '';
  var _busy = false;

  /// Server problems by request field (`name`, `description`).
  var _fieldErrors = const <String, String>{};
  String? _error;
  static const _fields = {'name', 'description'};

  Future<void> _submit() async {
    if (_busy) return;
    final CreateSpaceRequest request = (
      name: _name.trim().isEmpty ? 'My first space' : _name.trim(),
      description: _description.trim().isEmpty ? null : _description.trim(),
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
