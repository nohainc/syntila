import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../ax/ax_data.dart';
import '../../ax/sync/ax_people.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_sync_engine.dart';
import '../common/quiet_notices.dart';
import '../invitations/space_invitation_dialog.dart';

class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key, required this.people});
  final AxPeople people;
  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
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
        final people = state.data ?? const <AxPerson>[];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('People', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          const Text(
              'People you collaborate with will appear here after they accept a Space invitation.'),
          const SizedBox(height: 20),
          _PeopleReadStatus(people: widget.people, state: state),
          if (people.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < people.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _personCard(people[i]),
                ],
              ],
            ),
        ]);
      });

  Widget _personCard(AxPerson person) {
    final displayName =
        person.displayName.trim().isEmpty ? person.email : person.displayName;
    final sharedCount =
        '${person.sharedSpaceCount} shared ${person.sharedSpaceCount == 1 ? 'Space' : 'Spaces'}';
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
                    Text(displayName,
                        style: Theme.of(context).textTheme.titleMedium),
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
                )),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sharedCount),
                    if (person.sharedSpaces.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(person.sharedSpaces.map((s) => s.name).join(', '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ],
                  ],
                )),
                const SizedBox(width: 8),
                TextButton(
                  key: ValueKey('add-to-space-${person.userId}'),
                  onPressed: () => _addToSpace(person.userId),
                  child: const Text('Add to Space'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addToSpace(String userId) async {
    final sent = await showDialog<bool>(
        context: context,
        builder: (_) =>
            SpaceInvitationDialog(people: widget.people, personId: userId));
    if (sent == true && mounted) {
      ScaffoldMessenger.of(context)
          .showNotice(const SnackBar(content: Text('Space invitation sent.')));
    }
  }
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
