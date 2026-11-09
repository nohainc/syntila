import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../ax/ax_data.dart';
import '../../ax/sync/ax_people.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_sync_engine.dart';
import '../common/quiet_notices.dart';

class PeoplePage extends StatefulWidget {
  const PeoplePage({
    super.key,
    required this.people,
    this.onOpenThread,
    this.onOpenSpace,
  });

  final AxPeople people;
  final void Function(String spaceId, String threadId)? onOpenThread;
  final ValueChanged<String>? onOpenSpace;

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  String _searchQuery = '';
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(PeoplePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.people != widget.people) {
      _ensure();
    }
  }

  void _ensure() => unawaited(widget.people
      .ensure()
      .then<void>((_) {}, onError: (Object _, StackTrace __) {}));

  @override
  Widget build(BuildContext context) => AxQueryBuilder(
        engine: widget.people.engine,
        query: widget.people.query,
        ensure: false,
        builder: (context, state) {
          final allPeople = state.data ?? const <AxPerson>[];
          final query = _searchQuery.trim().toLowerCase();
          final filtered = query.isEmpty
              ? allPeople
              : allPeople
                  .where((p) =>
                      p.displayName.toLowerCase().contains(query) ||
                      p.email.toLowerCase().contains(query))
                  .toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('People',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: allPeople.isNotEmpty
                        ? SizedBox(
                            height: 36,
                            child: TextField(
                            expands: true,
                            maxLines: null,
                            minLines: null,
                            textAlignVertical: TextAlignVertical.center,
                            key: const ValueKey('people-search-field'),
                            decoration: InputDecoration(
                              hintText: 'Search people',
                              prefixIcon: const Icon(Icons.search, size: 20),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                            onChanged: (val) =>
                                setState(() => _searchQuery = val),
                          ))
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        fixedSize: const Size.fromHeight(36)),
                    key: const ValueKey('add-person-button'),
                    onPressed: _showAddPersonDialog,
                    icon: const Icon(Icons.person_add_outlined, size: 18),
                    label: const Text('Add Person'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _PeopleReadStatus(people: widget.people, state: state),
              if (allPeople.isEmpty && !state.isFetching)
                _emptyState()
              else if (filtered.isEmpty && allPeople.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('No people match "$_searchQuery".',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < filtered.length; i++) ...[
                      if (i > 0) const SizedBox(height: 12),
                      _personCard(filtered[i]),
                    ],
                  ],
                ),
            ],
          );
        },
      );

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.people_outline,
                  size: 56,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                'No people yet. Invite someone to start a private conversation.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('empty-add-person-button'),
                onPressed: _showAddPersonDialog,
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: const Text('Add Person'),
              ),
            ],
          ),
        ),
      );

  Widget _personCard(AxPerson person) {
    final displayName =
        person.displayName.trim().isEmpty ? person.email : person.displayName;
    final sharedCount =
        '${person.sharedSpaceCount} shared ${person.sharedSpaceCount == 1 ? 'Space' : 'Spaces'}';

    final expanded = _expanded.contains(person.userId);
    return Card(
      key: ValueKey('person-${person.userId}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PersonAvatar(
                    source: widget.people.source, url: person.avatarUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(displayName,
                                style: Theme.of(context).textTheme.titleMedium),
                          ),
                          _connectionBadge(person.connectionStatus),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(person.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: _actionButtons(person)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: ValueKey('expand-spaces-${person.userId}'),
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  tooltip: expanded ? 'Hide shared Spaces' : sharedCount,
                  onPressed: () => setState(() {
                    if (!_expanded.add(person.userId)) {
                      _expanded.remove(person.userId);
                    }
                  }),
                  icon: Icon(
                      expanded ? Icons.keyboard_double_arrow_down : Icons.keyboard_double_arrow_right),
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 4),
              Text(sharedCount),
              for (final space in person.sharedSpaces)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(space.name,
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _connectionBadge(String status) {
    Color bg;
    Color fg;
    String label;

    switch (status) {
      case 'connected':
        bg = Colors.green.withValues(alpha: 0.15);
        fg = Colors.green.shade800;
        label = 'Connected';
        break;
      case 'invitation_sent':
        bg = Colors.orange.withValues(alpha: 0.15);
        fg = Colors.orange.shade800;
        label = 'Invitation sent';
        break;
      case 'invitation_received':
        bg = Colors.blue.withValues(alpha: 0.15);
        fg = Colors.blue.shade800;
        label = 'Invitation received';
        break;
      case 'disconnected':
        bg = Colors.grey.withValues(alpha: 0.2);
        fg = Colors.grey.shade700;
        label = 'Disconnected';
        break;
      case 'blocked':
        bg = Colors.red.withValues(alpha: 0.15);
        fg = Colors.red.shade800;
        label = 'Blocked';
        break;
      case 'collaborator':
      default:
        bg = Colors.blueGrey.withValues(alpha: 0.12);
        fg = Colors.blueGrey.shade700;
        label = 'Collaborator';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  Widget _actionButtons(AxPerson person) {
    switch (person.connectionStatus) {
      case 'connected':
        return Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: ValueKey('message-${person.userId}'),
              onPressed: () => _openMessage(person),
              icon: const Icon(Icons.chat_bubble_outline, size: 16),
              label: const Text('Open Space'),
            ),
            OutlinedButton(
              key: ValueKey('disconnect-${person.userId}'),
              onPressed: () => _disconnect(person.userId),
              child: const Text('Disconnect'),
            ),
            OutlinedButton(
              key: ValueKey('block-${person.userId}'),
              onPressed: () => _block(person.userId),
              child: const Text('Block'),
            ),
          ],
        );

      case 'invitation_sent':
        return Wrap(
          spacing: 8,
          children: [
            if (person.invitationId != null)
              OutlinedButton(
                key: ValueKey('cancel-invitation-${person.userId}'),
                onPressed: () => _cancelInvitation(person.invitationId!),
                child: const Text('Cancel'),
              ),
          ],
        );

      case 'invitation_received':
        return Wrap(
          spacing: 8,
          children: [
            if (person.invitationId != null) ...[
              FilledButton(
                key: ValueKey('accept-invitation-${person.userId}'),
                onPressed: () => _acceptInvitation(person.invitationId!),
                child: const Text('Accept'),
              ),
              OutlinedButton(
                key: ValueKey('decline-invitation-${person.userId}'),
                onPressed: () => _declineInvitation(person.invitationId!),
                child: const Text('Decline'),
              ),
            ],
          ],
        );

      case 'blocked':
        return OutlinedButton(
          key: ValueKey('unblock-${person.userId}'),
          onPressed: () => _unblock(person.userId),
          child: const Text('Unblock'),
        );

      case 'disconnected':
        return FilledButton(
          key: ValueKey('reconnect-${person.userId}'),
          onPressed: () => _connect(person.userId),
          child: const Text('Connect'),
        );

      case 'collaborator':
      default:
        return FilledButton(
          key: ValueKey('connect-${person.userId}'),
          onPressed: () => _connect(person.userId),
          child: const Text('Connect'),
        );
    }
  }

  Future<void> _openMessage(AxPerson person) async {
    try {
      final source = widget.people.source;
      final spaceId = source is AxPersonalSpaceDataSource
          ? await (source as AxPersonalSpaceDataSource)
              .openPersonalSpace(person.userId)
          : person.directSpaceId;
      if (!mounted) return;
      if (spaceId == null || widget.onOpenSpace == null) {
        throw StateError('Personal Space is unavailable');
      }
      widget.onOpenSpace!(spaceId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(
              content: Text('Could not open the Space. Please try again.')),
        );
      }
    }
  }

  Future<void> _connect(String userId) async {
    try {
      await widget.people.sendInvitation(userId: userId);
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('Connection invitation sent.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Could not send connection invitation: $e')),
        );
      }
    }
  }

  Future<void> _acceptInvitation(String invitationId) async {
    try {
      await widget.people.acceptInvitation(invitationId);
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('Connection accepted.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Could not accept invitation: $e')),
        );
      }
    }
  }

  Future<void> _declineInvitation(String invitationId) async {
    try {
      await widget.people.declineInvitation(invitationId);
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('Invitation declined.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Could not decline invitation: $e')),
        );
      }
    }
  }

  Future<void> _cancelInvitation(String invitationId) async {
    try {
      await widget.people.cancelInvitation(invitationId);
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('Invitation cancelled.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Could not cancel invitation: $e')),
        );
      }
    }
  }

  Future<void> _disconnect(String userId) async {
    try {
      await widget.people.disconnect(userId);
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('Connection removed.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Could not remove connection: $e')),
        );
      }
    }
  }

  Future<void> _block(String userId) async {
    try {
      await widget.people.block(userId);
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('User blocked.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Could not block user: $e')),
        );
      }
    }
  }

  Future<void> _unblock(String userId) async {
    try {
      await widget.people.unblock(userId);
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('User unblocked.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Could not unblock user: $e')),
        );
      }
    }
  }

  Future<void> _showAddPersonDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _AddPersonDialog(people: widget.people),
    );
  }
}

class _AddPersonDialog extends StatefulWidget {
  const _AddPersonDialog({required this.people});

  final AxPeople people;

  @override
  State<_AddPersonDialog> createState() => _AddPersonDialogState();
}

class _AddPersonDialogState extends State<_AddPersonDialog> {
  final _emailController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await widget.people.sendInvitation(email: email);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Invitation sent to $email.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Failed to send invitation: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add Person'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter an email address to send a personal connection invitation.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('add-person-email-field'),
                controller: _emailController,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email',
                  hintText: 'colleague@example.com',
                  errorText: _error,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _send(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('send-invitation-button'),
            onPressed: _submitting ? null : _send,
            child: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send Invitation'),
          ),
        ],
      );
}

class _PersonAvatar extends StatefulWidget {
  const _PersonAvatar({required this.source, required this.url});

  final AxDataSource source;
  final String? url;

  @override
  State<_PersonAvatar> createState() => _PersonAvatarState();
}

class _PersonAvatarState extends State<_PersonAvatar> {
  List<int>? bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PersonAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    if (url == null || !_isPrivateAvatarUrl(url)) return;
    try {
      final loaded = await widget.source.loadAvatar(url: url);
      if (mounted && widget.url == url) setState(() => bytes = loaded);
    } catch (_) {
      // Keep the person icon visible when the private avatar is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    final ImageProvider<Object>? image = bytes != null && bytes!.isNotEmpty
        ? MemoryImage(Uint8List.fromList(bytes!))
        : url != null && !_isPrivateAvatarUrl(url)
            ? NetworkImage(url)
            : null;
    return CircleAvatar(
      backgroundImage: image,
      child: image == null ? const Icon(Icons.person_outline, size: 20) : null,
    );
  }

  bool _isPrivateAvatarUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri?.path.startsWith('/api/users/') == true &&
        uri?.path.endsWith('/avatar') == true;
  }
}

class _PeopleReadStatus extends StatelessWidget {
  const _PeopleReadStatus({required this.people, required this.state});
  final AxPeople people;
  final AxQueryState<List<AxPerson>> state;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (state.isFetching)
          const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator()),
        if (state.error != null)
          Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                Expanded(
                    child: Text(state.hasData
                        ? 'People could not be updated. Check your connection. Cached details remain available.'
                        : 'People could not be loaded. Check your connection.')),
                TextButton(
                    onPressed: () => unawaited(people.refresh().then<void>(
                        (_) {},
                        onError: (Object _, StackTrace __) {})),
                    child: const Text('Retry')),
              ])),
      ]);
}
