import 'dart:async';
import 'package:flutter/material.dart';
import '../../ax/ax_people.dart';
import '../../ax/ax_models.dart';
import '../../ax/sync/ax_people.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_space_tab_queries.dart';
import '../../ax/sync/ax_space_invitations.dart';
import '../../ax/sync/ax_sync_engine.dart';

/// One searchable invitation/permission flow from either Space or People.
class SpaceInvitationDialog extends StatefulWidget {
  const SpaceInvitationDialog(
      {super.key, required this.people, this.space, this.personId, this.tabs})
      : assert(space != null || personId != null);
  final AxPeople people;
  final AxPeopleSpace? space;
  final String? personId;
  final AxSpaceTabQueries? tabs;
  @override
  State<SpaceInvitationDialog> createState() => _SpaceInvitationDialogState();
}

class _SpaceInvitationDialogState extends State<SpaceInvitationDialog> {
  final _selected = <String>{};
  String? _spaceId;
  String _search = '';
  String _email = '';
  String? _error;
  Map<String, bool> _permissions = {};
  bool _sending = false;
  int _sent = 0;
  @override
  void initState() {
    super.initState();
    if (widget.personId != null) _selected.add(widget.personId!);
    if (widget.space != null) _setSpace(widget.space!);
  }

  void _setSpace(AxPeopleSpace space) {
    _spaceId = space.id;
    final allowed = space.permissions.toJson();
    _permissions = AxSpacePermissions.forRole('collaborator').toJson()
      ..updateAll((key, value) => value && allowed[key] == true);
    _permissions['chat'] = false;
    _permissions['work'] = false;
    _error = null;
  }

  AxPerson? _person(List<AxPerson> people, String id) =>
      people.where((person) => person.userId == id).firstOrNull;
  AxPeopleSpace? _space(List<AxPerson> people) =>
      widget.space ??
      _person(people, widget.personId!)
          ?.invitableSpaces
          .where((space) => space.id == _spaceId)
          .firstOrNull;

  /// A background refresh (for example after a previous invitation) must not
  /// lock the list; only a failed or still-empty load does.
  bool _peopleUnavailable(AxQueryState<List<AxPerson>> state) =>
      state.error != null || (state.isFetching && state.data == null);
  bool _pending(AxSpaceInvitation invitation) =>
      invitation.status == 'pending' &&
      (DateTime.tryParse(invitation.expiresAt)?.isAfter(DateTime.now()) ??
          true);
  String _status(AxPerson person, AxPeopleSpace space,
      List<AxSpaceMember> members, List<AxSpaceInvitation> invitations) {
    if (members.any((member) => member.userId == person.userId) ||
        person.sharedSpaces.any((shared) => shared.id == space.id)) {
      return 'Already a member';
    }
    if (person.pendingInvitationSpaceIds.contains(space.id) ||
        invitations.any((invite) =>
            _pending(invite) &&
            (invite.inviteeUserId == person.userId ||
                (invite.inviteeUserId == null &&
                    invite.email.trim().toLowerCase() ==
                        person.email.trim().toLowerCase())))) {
      return 'Pending invitation';
    }
    return person.invitableSpaces.any((candidate) => candidate.id == space.id)
        ? 'Available to invite'
        : 'Unavailable to invite';
  }

  Future<void> _send(AxQueryState<List<AxPerson>> state,
      List<AxSpaceMember> members, List<AxSpaceInvitation> invitations) async {
    final people = state.data ?? const <AxPerson>[];
    final space = _space(people);
    if (space == null || _sending) return;
    if (_selected.isNotEmpty && _peopleUnavailable(state)) return;
    final email = _email.trim().toLowerCase();
    if (_selected.isEmpty) {
      if (!email.contains('@') || email.contains(' ')) {
        setState(() => _error = 'Enter a valid email address.');
        return;
      }
      if (members.any((member) => member.email.trim().toLowerCase() == email)) {
        setState(() => _error = 'This user is already a member of the Space.');
        return;
      }
      if (invitations.any((invite) =>
          _pending(invite) && invite.email.trim().toLowerCase() == email)) {
        setState(() => _error =
            'Pending invitation: an invitation was already sent to this email.');
        return;
      }
    } else {
      if (_selected.any((id) {
        final person = _person(people, id);
        return person == null ||
            _status(person, space, members, invitations) !=
                'Available to invite';
      })) {
        setState(() => _error =
            'A selected person is already a member, has a pending invitation, or is unavailable.');
        return;
      }
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final writer = AxSpaceInvitations(widget.people);
    final selected = _selected.toList();
    final failures = <String>[];
    var failedEmail = false;
    final permissions = AxSpacePermissions.fromJson(_permissions);
    for (final id
        in selected.isEmpty ? <String?>[null] : selected.cast<String?>()) {
      try {
        await writer.send(
            space: space,
            permissions: permissions,
            userId: id,
            email: id == null ? email : null);
        _sent++;
        if (id != null) _selected.remove(id);
      } catch (error) {
        if (error is AxMutationSuperseded) {
          if (mounted) Navigator.pop(context);
          return;
        }
        if (id == null) {
          failedEmail = true;
        } else {
          failures.add(id);
        }
      }
    }
    if (!mounted) return;
    if (failures.isEmpty && !failedEmail) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _sending = false;
      _error =
          'Invitation could not be sent. Check permissions and membership before trying again.';
    });
    unawaited(widget.people
        .refresh()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  @override
  Widget build(BuildContext context) => AxQueryBuilder(
      engine: widget.people.engine,
      query: widget.people.query,
      ensure: false,
      builder: (context, state) {
        if (widget.space != null && widget.tabs != null) {
          return AxQueryBuilder(
              engine: widget.tabs!.engine,
              query: widget.tabs!.members(widget.space!.id),
              ensure: false,
              builder: (context, members) => AxQueryBuilder(
                    engine: widget.tabs!.engine,
                    query: widget.tabs!.invitations(widget.space!.id),
                    ensure: false,
                    builder: (context, invitations) => _dialog(context, state,
                        members.data ?? [], invitations.data ?? []),
                  ));
        }
        return _dialog(context, state, [], []);
      });
  Widget _dialog(BuildContext context, AxQueryState<List<AxPerson>> state,
      List<AxSpaceMember> members, List<AxSpaceInvitation> invitations) {
    final people = state.data ?? const <AxPerson>[];
    final person =
        widget.personId == null ? null : _person(people, widget.personId!);
    final space = _space(people);
    final allowed = space?.permissions.toJson() ?? const <String, bool>{};
    final recent = people
        .where((person) =>
            person.displayName.toLowerCase().contains(_search) ||
            person.email.toLowerCase().contains(_search))
        .toList()
      ..sort((a, b) => b.establishedAt.compareTo(a.establishedAt));
    final visible = _search.isEmpty ? recent.take(6) : recent;
    return AlertDialog(
      title: Text(widget.personId == null
          ? 'Invite people'
          : 'Invite ${person?.displayName ?? 'person'}${space == null ? '' : ' to ${space.name}'}'),
      content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                if (state.isFetching) const LinearProgressIndicator(),
                if (state.error != null)
                  const Text(
                      'People could not be updated. You can invite someone new by email.'),
                if (widget.personId != null) ...[
                  if (person == null) const Text('This person is unavailable.'),
                  if (person != null)
                    DropdownButtonFormField<String>(
                        key: ValueKey(('invitation-space', space?.id)),
                        initialValue: space?.id,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Space'),
                        items: [
                          for (final candidate in person.invitableSpaces)
                            DropdownMenuItem(
                                value: candidate.id,
                                child: Text(candidate.name,
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: _sending
                            ? null
                            : (id) => setState(() => _setSpace(person
                                .invitableSpaces
                                .firstWhere((space) => space.id == id)))),
                  if (person?.invitableSpaces.isEmpty ?? true)
                    const Text(
                        'No eligible Spaces. Existing members and pending invitations are excluded.'),
                ] else ...[
                  TextField(
                      key: const ValueKey('invite-people-search'),
                      enabled: !_sending,
                      decoration: const InputDecoration(
                          hintText: 'Search your People...',
                          prefixIcon: Icon(Icons.search)),
                      onChanged: (value) =>
                          setState(() => _search = value.trim().toLowerCase())),
                  const SizedBox(height: 12),
                  Text(_search.isEmpty ? 'Recent' : 'People',
                      style: Theme.of(context).textTheme.titleSmall),
                  if (!state.isFetching && visible.isEmpty)
                    Text(_search.isEmpty
                        ? 'Your known collaborators will appear here after accepting an invitation.'
                        : 'No people match your search.'),
                  for (final person in visible)
                    CheckboxListTile(
                        key: ValueKey('invite-person-${person.userId}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(person.displayName),
                        subtitle: Text(space == null
                            ? 'Unavailable to invite'
                            : _status(person, space, members, invitations)),
                        value: _selected.contains(person.userId),
                        onChanged: !_sending &&
                                _email.trim().isEmpty &&
                                !_peopleUnavailable(state) &&
                                space != null &&
                                _status(person, space, members, invitations) ==
                                    'Available to invite'
                            ? (value) => setState(() {
                                  if (value == true) {
                                    _selected.add(person.userId);
                                  } else {
                                    _selected.remove(person.userId);
                                  }
                                  _error = null;
                                })
                            : null),
                  const Divider(),
                  const Text('Invite someone new'),
                  const SizedBox(height: 8),
                  TextField(
                      key: const ValueKey('invite-new-email'),
                      enabled: !_sending && _selected.isEmpty,
                      keyboardType: TextInputType.emailAddress,
                      decoration:
                          const InputDecoration(labelText: 'Email address'),
                      onChanged: (value) => setState(() {
                            _email = value;
                            _error = null;
                          })),
                ],
                const SizedBox(height: 16),
                if (space != null) ...[
                  Text('Permissions',
                      style: Theme.of(context).textTheme.titleMedium),
                  for (final entry in const {
                    'chat': 'Use Space AI for chat',
                    'work': 'Use Space AI for work',
                    'manageOwnThreads': 'Create threads'
                  }.entries)
                    CheckboxListTile(
                        key: ValueKey('invite-permission-${entry.key}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(entry.value),
                        value: (_permissions[entry.key] ?? false) &&
                            allowed[entry.key] == true,
                        onChanged: !_sending && allowed[entry.key] == true
                            ? (value) => setState(() {
                                  _permissions[entry.key] = value == true;
                                })
                            : null),
                ],
                if (_sent > 0)
                  Text(
                      '$_sent invitation${_sent == 1 ? '' : 's'} sent. Remaining selections were not sent.'),
                if (_error != null) Text(_error!),
              ]))),
      actions: [
        TextButton(
            onPressed:
                _sending ? null : () => Navigator.pop(context, _sent > 0),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: space != null &&
                    !_sending &&
                    (widget.personId == null || person != null) &&
                    (_selected.isEmpty ||
                        (state.error == null &&
                            !state.isFetching &&
                            _selected.every((id) {
                              final person = _person(people, id);
                              return person != null &&
                                  _status(person, space, members,
                                          invitations) ==
                                      'Available to invite';
                            })))
                ? () => _send(state, members, invitations)
                : null,
            child: Text(_sending ? 'Sending...' : 'Send invitation'))
      ],
    );
  }
}
