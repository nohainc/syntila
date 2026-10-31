part of '../spaces_pages.dart';

extension _SpaceWorkspaceActions on _SpaceWorkspaceState {
  Future<void> _setMemberPermission(
      AxSpaceMember member, String key, bool value) async {
    _updateState(() => _savingMembers.add(member.userId));
    try {
      final permissions = member.effectivePermissions.toJson()..[key] = value;
      await widget.dataSource.updateSpaceMemberPermissions(
          spaceId: widget.space.id,
          userId: member.userId,
          permissions: AxSpacePermissions.fromJson(permissions));
      await _queries.refreshMembers(widget.space.id, includeInvitations: false);
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) _updateState(() => _savingMembers.remove(member.userId));
    }
  }

  void _startEditing() => _updateState(() {
        _nameController.text = widget.space.name;
        _descriptionController.text = widget.space.description;
        _editColor = widget.space.settings['color'] is String
            ? widget.space.settings['color'] as String
            : null;
        _editError = null;
        _editing = true;
      });

  void _cancelEditing() => _updateState(() {
        _editing = false;
        _editError = null;
      });

  Future<void> _saveEdits() async {
    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    if (name.isEmpty) {
      _updateState(() => _editError = 'Space name cannot be empty.');
      return;
    }
    _updateState(() {
      _savingEdits = true;
      _editError = null;
    });
    String? error;
    try {
      if (widget.onSaveEdits != null) {
        error = await widget.onSaveEdits!(name, description, _editColor);
      } else {
        final updated = await _collaboration.editSpace(
          widget.space,
          name: name,
          description: description,
          instructions: widget.space.instructions,
          settings: {'color': _editColor},
        );
        widget.onSpaceUpdated?.call(updated);
      }
    } catch (failure) {
      error = failure.toString();
    }
    if (!mounted) return;
    _updateState(() {
      _savingEdits = false;
      _editError = error;
      if (error == null) _editing = false;
    });
  }

  /// Inline replacement for the old Edit Space dialog.
  Widget _spaceEditForm() => Padding(
        key: const ValueKey('space-edit-form'),
        padding: const EdgeInsets.only(right: 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Edit Space', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              autofocus: true,
              enabled: !_savingEdits,
              decoration: InputDecoration(
                labelText: 'Space Name',
                errorText: _editError,
              ),
              onChanged: (_) {
                if (_editError != null) _updateState(() => _editError = null);
              },
              onSubmitted: (_) => _saveEdits(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              enabled: !_savingEdits,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            SpaceColorSelector(
              value: _editColor,
              onChanged: _savingEdits
                  ? null
                  : (value) => _updateState(() => _editColor = value),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _savingEdits ? null : _cancelEditing,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _savingEdits ? null : _saveEdits,
                  child: Text(_savingEdits ? 'Saving…' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      );

  bool _threadNameTaken(String name, {String? exceptId}) {
    final lower = name.trim().toLowerCase();
    return threads.any((thread) =>
        thread.id != exceptId && thread.name.trim().toLowerCase() == lower);
  }

  Future<void> _createThread() async {
    final created = await showCreateThreadDialog(
      context,
      isNameTaken: (name) => _threadNameTaken(name),
    );
    if (created == null || created.isEmpty) return;
    try {
      final thread = await _collaboration.createThread(
        spaceId: widget.space.id,
        name: created,
      );
      if (!mounted) return;

      widget.onSpaceUpdated?.call(widget.space);
      widget.onOpenThread(thread.id);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _editThread(AxThread thread) async {
    final updatedName = await showRenameThreadDialog(
      context,
      currentName: thread.name,
      isNameTaken: (name) => _threadNameTaken(name, exceptId: thread.id),
    );
    if (updatedName == null) return;
    try {
      await _collaboration.editThread(
        thread,
        name: updatedName,
      );
      if (!mounted) return;

      _message('Thread renamed.');
      widget.onSpaceUpdated?.call(widget.space);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _deleteThread(AxThread thread) async {
    if (!await confirmDeleteThread(context)) return;
    try {
      await _collaboration.deleteThread(thread);
      if (!mounted) return;

      _message('Thread deleted.');
      widget.onSpaceUpdated?.call(widget.space);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _setThreadArchived(
    AxThread thread,
    bool archived,
  ) async {
    try {
      await _collaboration.editThread(
        thread,
        status: archived ? 'archived' : 'active',
      );
      if (!mounted) return;

      _message(archived ? 'Thread archived.' : 'Thread restored.');
      widget.onSpaceUpdated?.call(widget.space);
    } catch (error) {
      _message(error.toString());
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showNotice(
        SnackBar(
          duration: const Duration(seconds: 4),
          showCloseIcon: true,
          closeIconColor: Theme.of(context).colorScheme.onSurfaceVariant,
          content: Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? SyntilaColors.navigationBackgroundDark
              : SyntilaColors.navigationBackgroundLight,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          action: SnackBarAction(
            label: 'Copy',
            textColor: SyntilaColors.primaryForeground(
                Theme.of(context).brightness == Brightness.dark),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message));
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ),
      );

    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
      }
    });
  }

  Future<void> _share() async {
    final sent = await showDialog<bool>(
        context: context,
        builder: (_) => SpaceInvitationDialog(
            people: _people,
            tabs: _queries,
            space: AxPeopleSpace(
                id: widget.space.id,
                name: widget.space.name,
                permissions: widget.space.effectivePermissions,
                canInvite: widget.space.role == 'owner')));
    if (sent == true && mounted) _message('Space invitation sent.');
  }

  Future<void> _removeMember(AxSpaceMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        constraints: SyntilaDialogStyle.small,
        title: Text('Remove "${member.displayName}"?'),
        content: const Text(
            'Are you sure you want to remove this member from the Space?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: SyntilaDialogStyle.destructiveButton(),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.dataSource
        .removeSpaceMember(spaceId: widget.space.id, userId: member.userId);
    _message('${member.displayName} was removed from the Space.');
    await _queries.refreshMembers(widget.space.id, includeInvitations: false);
  }

  Future<void> _revokeInvitation(AxSpaceInvitation invite) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        constraints: SyntilaDialogStyle.small,
        title: const Text('Revoke invitation?'),
        content: Text('Cancel pending invitation for ${invite.email}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: SyntilaDialogStyle.destructiveButton(),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.dataSource.expireSpaceInvitation(
        spaceId: widget.space.id,
        invitationId: invite.id,
      );
      _message('Invitation revoked.');
      await _queries.refreshMembers(widget.space.id, includeMembers: false);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _resendInvitation(AxSpaceInvitation invite) async {
    try {
      await widget.dataSource.expireSpaceInvitation(
          spaceId: widget.space.id, invitationId: invite.id);
      final allowed = widget.space.effectivePermissions.toJson();
      final selected = (invite.permissions ??
              AxSpacePermissions.forRole(invite.role))
          .toJson()
        ..updateAll((key, value) => value && allowed[key] == true);
      await AxSpaceInvitations(_people).send(
          space: AxPeopleSpace(
              id: widget.space.id,
              name: widget.space.name,
              permissions: widget.space.effectivePermissions,
              canInvite: widget.space.role == 'owner'),
          permissions: AxSpacePermissions.fromJson(selected),
          userId: invite.inviteeUserId,
          email: invite.inviteeUserId == null ? invite.email : null);
      if (mounted) _message('Invitation resent.');
    } catch (error) {
      if (mounted) _message(error.toString());
    }
  }
}
