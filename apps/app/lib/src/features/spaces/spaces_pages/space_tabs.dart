part of '../spaces_pages.dart';

extension _SpaceWorkspaceTabs on _SpaceWorkspaceState {
  Widget _threadsTab() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.embedded) ...[
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 8,
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Threads',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<bool>(
                        key: const ValueKey('space-thread-filter'),
                        value: _showArchivedThreads,
                        isDense: true,
                        borderRadius: BorderRadius.circular(8),
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        items: const [
                          DropdownMenuItem(value: false, child: Text('Active')),
                          DropdownMenuItem(
                              value: true, child: Text('Archived')),
                        ],
                        onChanged: (value) => _updateState(
                            () => _showArchivedThreads = value ?? false),
                      ),
                    ),
                  ]),
                  if (canManage)
                    Tooltip(
                      message: 'Create Thread',
                      child: FilledButton.icon(
                        key: const ValueKey('space-new-thread'),
                        style: FilledButton.styleFrom(
                          backgroundColor: SyntilaColors.primary,
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('New Thread'),
                        onPressed: _createThread,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
            ],
            const SizedBox(height: 8),
            if (threadsError != null)
              TextButton(
                  onPressed: () {
                    unawaited(_streams.refresh(widget.space.id).then<void>(
                        (_) {},
                        onError: (Object _, StackTrace __) {}));
                  },
                  child: const Text('Retry Threads')),
            if (threadsLoading)
              const LinearProgressIndicator()
            else if (_filteredThreads.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                    _archivedOnly ? 'No archived threads.' : 'No threads yet.'),
              )
            else
              ..._filteredThreads.map(_threadListTile),
          ],
        ),
      );

  Iterable<AxThread> get _filteredThreads =>
      sortAxThreadsByLastUpdate(threads).where((thread) =>
          (thread.archived || thread.status.toLowerCase() == 'archived') ==
          _archivedOnly);

  // Embedded on the Space landing, active Threads live in the sidebar.
  bool get _archivedOnly => widget.embedded || _showArchivedThreads;

  Widget _threadListTile(AxThread thread) {
    final archived =
        thread.archived || thread.status.toLowerCase() == 'archived';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pending = thread.id.startsWith('local-thread-');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        thread.name,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: !thread.creatorIsOwner && thread.creatorEmail.isNotEmpty
          ? Text('Created by ${thread.creatorEmail}',
              style: const TextStyle(fontSize: 12))
          : null,
      onTap: archived || pending ? null : () => widget.onOpenThread(thread.id),
      trailing: !pending
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PopupMenuButton<String>(
                  color: SyntilaMenuStyle.background(isDark),
                  surfaceTintColor: Colors.transparent,
                  elevation: 12,
                  shadowColor: SyntilaMenuStyle.shadow(isDark),
                  shape: SyntilaMenuStyle.shape(isDark),
                  menuPadding: SyntilaMenuStyle.padding,
                  tooltip: 'Thread actions',
                  onSelected: (action) {
                    if (action == 'edit') {
                      _editThread(thread);
                    } else if (action == 'archive') {
                      _setThreadArchived(thread, true);
                    } else if (action == 'restore') {
                      _setThreadArchived(thread, false);
                    } else if (action == 'delete') {
                      _deleteThread(thread);
                    }
                  },
                  itemBuilder: (menuContext) => [
                    for (final (action, label, icon) in [
                      if (!archived && (isOwner || thread.canConfigureWork))
                        ('edit', 'Rename', Icons.edit_outlined),
                      archived
                          ? ('restore', 'Restore', Icons.unarchive_outlined)
                          : ('archive', 'Archive', Icons.archive_outlined),
                      if (isOwner || thread.canDestroy)
                        ('delete', 'Delete', Icons.delete_outline),
                    ])
                      SyntilaMenuEntry<String>(
                        value: action,
                        child: MenuItemButton(
                          style: SyntilaMenuStyle.item(isDark),
                          leadingIcon: Icon(icon, size: 16),
                          onPressed: () => Navigator.pop(menuContext, action),
                          child: Text(label, style: SyntilaMenuStyle.textStyle),
                        ),
                      ),
                  ],
                ),
              ],
            )
          : null,
    );
  }

  String _formatInvitationTime(String raw) {
    if (raw.isEmpty) return '';
    try {
      final parsed = DateTime.parse(raw).toLocal();
      final diff = DateTime.now().difference(parsed);
      if (diff.inSeconds < 60) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return raw;
    }
  }

  DataColumn _permissionColumn(IconData icon, String label) => DataColumn(
        numeric: true,
        label: Tooltip(
          message: label,
          child: SizedBox(
            width: 20,
            child: Align(
              alignment: Alignment.centerRight,
              child: Icon(icon, size: 18),
            ),
          ),
        ),
      );

  Widget _permissionLegendItem(IconData icon, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      );

  Widget _membersTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.embedded) ...[
            Text('Members', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
          ],
          Text(
            'Choose what each member can do in this Space.',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _permissionLegendItem(Icons.chat_bubble_outline, 'Chat workflow'),
              _permissionLegendItem(
                  Icons.smart_toy_outlined, 'Own Workers in Chat'),
              _permissionLegendItem(Icons.work_outline, 'Work workflow'),
              _permissionLegendItem(Icons.forum_outlined, 'Own threads'),
            ],
          ),
          const SizedBox(height: 8),
          if (widget.dataSource is AxSpaceMemberUsageDataSource &&
              !membersLoading)
            SpaceMemberUsageNote(
              source: widget.dataSource as AxSpaceMemberUsageDataSource,
              spaceId: widget.space.id,
              isOwner: canInvite,
              members: members.length,
              pendingInvitations:
                  invitations.where((i) => i.status == 'pending').length,
            ),
          if (membersError != null)
            const Text(
                'Members could not be loaded. Reopen this Space to try again.'),
          if (membersLoading)
            const LinearProgressIndicator()
          else ...[
            if (members.isNotEmpty || canInvite) ...[
              LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  key: const ValueKey('space-members-scroll'),
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: DataTable(
                      horizontalMargin: 0,
                      columnSpacing: 20,
                      dataRowMinHeight: 56,
                      dataRowMaxHeight: 64,
                      columns: [
                        DataColumn(
                            label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (canInvite)
                              IconButton(
                                icon: const Icon(Icons.add),
                                tooltip: 'Share Space',
                                splashRadius: 20,
                                onPressed: _share,
                              ),
                          ],
                        )),
                        _permissionColumn(Icons.chat_bubble_outline, 'Chat'),
                        _permissionColumn(
                            Icons.smart_toy_outlined, 'Own Workers in Chat'),
                        _permissionColumn(Icons.work_outline, 'Work'),
                        _permissionColumn(Icons.forum_outlined, 'Own threads'),
                        const DataColumn(
                          numeric: true,
                          label: Tooltip(
                            message: 'Remove member',
                            child: SizedBox(
                              width: 20,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Icon(Icons.person_remove_outlined,
                                    size: 18),
                              ),
                            ),
                          ),
                        ),
                      ],
                      rows: members
                          .map((member) => DataRow(cells: [
                                DataCell(Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(member.displayName.isNotEmpty
                                                ? member.displayName
                                                : member.email),
                                            if (member.role == 'owner') ...[
                                              const SizedBox(width: 8),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: SyntilaColors
                                                      .primarySoftColor(isDark),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  'Owner',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    color: SyntilaColors
                                                        .primaryForeground(
                                                            isDark),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ]),
                                      if (member.displayName != member.email)
                                        Text(member.email,
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant)),
                                    ])),
                                for (final entry in member.effectivePermissions
                                    .toJson()
                                    .entries)
                                  DataCell(Align(
                                    alignment: Alignment.centerRight,
                                    child: SizedBox(
                                      width: 20,
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: Checkbox(
                                          key: ValueKey(
                                              'permission-${member.userId}-${entry.key}'),
                                          value: entry.value,
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          // Own Workers refine Chat; they
                                          // stay off while Chat is denied.
                                          onChanged: isOwner &&
                                                  member.role != 'owner' &&
                                                  !_savingMembers.contains(
                                                      member.userId) &&
                                                  (entry.key !=
                                                          'useOwnWorkers' ||
                                                      member
                                                          .effectivePermissions
                                                          .chat)
                                              ? (value) => _setMemberPermission(
                                                  member,
                                                  entry.key,
                                                  value == true)
                                              : null,
                                        ),
                                      ),
                                    ),
                                  )),
                                DataCell(Align(
                                  alignment: Alignment.centerRight,
                                  child: SizedBox(
                                    width: 20,
                                    child: isOwner && member.role != 'owner'
                                        ? IconButton(
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                            splashRadius: 16,
                                            icon: const Icon(
                                                Icons.person_remove_outlined,
                                                size: 18),
                                            tooltip: 'Remove from Space',
                                            onPressed: () =>
                                                _removeMember(member))
                                        : const SizedBox.shrink(),
                                  ),
                                )),
                              ]))
                          .toList(),
                    ),
                  ),
                ),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No members found.'),
              ),
            if (invitations.isNotEmpty) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Pending invitations (${invitations.length})',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ...invitations.map((invite) {
                final timeText = _formatInvitationTime(invite.createdAt);
                final roleText = invite.role.toUpperCase();
                final subtitle = timeText.isNotEmpty
                    ? '$roleText · Invited $timeText'
                    : roleText;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: SyntilaColors.warningSoft(isDark),
                    child: Icon(
                      Icons.mail_outline,
                      size: 16,
                      color: SyntilaColors.warningText(isDark),
                    ),
                  ),
                  title: Text(
                    invite.email,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ActionStatusChip(
                        status: axInvitationStatus(invite.status),
                        kind: AxActionKind.invitation,
                      ),
                      if (canInvite) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 18),
                          tooltip: 'Resend invitation',
                          onPressed: () => _resendInvitation(invite),
                        ),
                        IconButton(
                          icon: const Icon(Icons.cancel_outlined, size: 18),
                          tooltip: 'Revoke invitation',
                          onPressed: () => _revokeInvitation(invite),
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],
          ],
        ],
      ),
    );
  }
}
