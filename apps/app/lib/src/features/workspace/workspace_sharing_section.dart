import 'dart:async';

import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';

import '../../ax/ax_data.dart'
    show AxAccountPlanDataSource, AxApiException, paidPlanRequiredCode;
import '../../ax/ax_models.dart';
import '../profile/account_plan.dart';
import '../../ax/ax_people.dart';
import '../../ax/ax_workspace_member_access.dart';
import 'workspace_member_access_section.dart';
import '../common/quiet_notices.dart';
import '../common/action_status_chip.dart';
import '../../ax/ax_action_status.dart';

/// Monthly run-time limits offered to the owner, in hours (null = no limit).
const _runTimeHours = <int?>[null, 1, 5, 10, 25, 50, 100];

const _modeLabels = {
  'chat': 'Chat only',
  'work': 'Chat and work',
  'work+shell': 'Work and commands',
};

String _duration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
}

/// Owner control for lending a Workspace to people (ADR-020): pick someone from
/// People (met by sharing a Space and chatting),
/// see who has access with usage only (never their content), set how many
/// requests they may run at once, and revoke.
class WorkspaceSharingSection extends StatefulWidget {
  const WorkspaceSharingSection({
    super.key,
    required this.workspaceId,
    required this.source,
    this.memberAccessSource,
    this.personAccessSource,
    this.workers = const [],
    this.people = const [],
    this.refresh,
    this.expandable = false,
    this.planSource,
  });

  /// When set, inviting people requires the paid plan's `workspace.sharing`.
  /// Existing access stays visible and revocable on Free.
  final AxAccountPlanDataSource? planSource;

  /// Fires when an invitation is sent, accepted, declined or revoked; the
  /// lists reload quietly so the owner sees the response while waiting here.
  final Listenable? refresh;

  /// Collapse the section behind an expandable header (the Workspace page).
  final bool expandable;

  final String workspaceId;

  /// People the owner already knows; new people are added by sharing a Space.
  final List<AxPerson> people;
  final AxWorkspaceSharingDataSource source;

  /// Enable "Show access" for each person: which Workers, models, efforts and
  /// mode they get. Both sources are needed, plus the Workspace's Workers.
  final AxWorkspaceMemberAccessDataSource? memberAccessSource;
  final AxWorkspacePersonAccessDataSource? personAccessSource;
  final List<AxWorker> workers;

  @override
  State<WorkspaceSharingSection> createState() =>
      _WorkspaceSharingSectionState();
}

class _WorkspaceSharingSectionState extends State<WorkspaceSharingSection> {
  bool _loading = true;
  bool _busy = false;
  Object? _error;
  List<AxPersonWithAccess> _people = const [];
  List<AxSharedWorkspaceInvitation> _invitations = const [];
  late final AccountPlanController? _plan = widget.planSource == null
      ? null
      : AccountPlanController(widget.planSource!);

  bool get _canInvite =>
      _plan == null || _plan.plan.has(workspaceSharingFeature);

  @override
  void initState() {
    super.initState();
    widget.refresh?.addListener(_onRefresh);
    _plan?.addListener(_onPlanChanged);
    unawaited(_plan?.refresh());
    unawaited(_load());
  }

  void _onPlanChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(WorkspaceSharingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refresh != widget.refresh) {
      oldWidget.refresh?.removeListener(_onRefresh);
      widget.refresh?.addListener(_onRefresh);
    }
    if (oldWidget.workspaceId != widget.workspaceId) unawaited(_load());
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(_onRefresh);
    _plan?.dispose();
    super.dispose();
  }

  void _onRefresh() {
    if (mounted && !_busy) unawaited(_load(quiet: true));
  }

  Future<void> _load({bool quiet = false}) async {
    final workspaceId = widget.workspaceId;
    setState(() {
      if (!quiet) _loading = true;
      _error = null;
    });
    try {
      final people = await widget.source.loadPeopleWithAccess(workspaceId);
      final invitations =
          await widget.source.loadSharedWorkspaceInvitations(workspaceId);
      if (!mounted || workspaceId != widget.workspaceId) return;
      setState(() {
        _people = people;
        _invitations = invitations;
      });
    } catch (error) {
      if (mounted && workspaceId == widget.workspaceId) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && workspaceId == widget.workspaceId) {
        setState(() => _loading = false);
      }
    }
  }

  /// Run a change, report failures, then refresh the lists.
  Future<void> _act(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      // The plan changed since it was loaded; show the upgrade note instead.
      if (error is AxApiException && error.code == paidPlanRequiredCode) {
        unawaited(_plan?.refresh());
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  /// People not yet sharing this Workspace, by email.
  List<AxPerson> get _options {
    final taken = {
      for (final p in _people.where((p) => p.active)) p.email.toLowerCase(),
      for (final i in _invitations.where((i) => i.status == 'pending'))
        i.email.toLowerCase(),
    };
    return [
      for (final p in widget.people)
        if (!taken.contains(p.email.toLowerCase())) p
    ];
  }

  Future<void> _addPeople() async {
    final options = _options;
    final person = await showDialog<AxPerson>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Add people'),
              content: SizedBox(
                  width: 420,
                  child: options.isEmpty
                      ? const Text(
                          key: ValueKey('sharing-no-people'),
                          'No one to add yet. First share a Space with someone to establish a contact. Once they accept the invitation, you can share this Workspace with them.')
                      : ListView(shrinkWrap: true, children: [
                          for (final p in options)
                            ListTile(
                                key: ValueKey('sharing-add-${p.userId}'),
                                contentPadding: EdgeInsets.zero,
                                title: Text(p.displayName),
                                subtitle: Text(p.email),
                                onTap: () => Navigator.pop(context, p)),
                        ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
              ],
            ));
    if (person == null) return;
    var sent = false;
    await _act(() async {
      await widget.source
          .createWorkspaceInvitation(widget.workspaceId, person.email);
      sent = true;
    });
    // Cloud accepted it; the row then follows the invitee's answer live.
    if (sent && mounted) {
      ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Invitation sent to ${person.email}.')));
    }
  }

  Future<void> _revokePerson(AxPersonWithAccess person) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              constraints: SyntilaDialogStyle.small,
              title: Text('Revoke access for ${person.displayName}?'),
              content: const Text(
                  'They stop being able to run on this Workspace. Work already running finishes.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    key: const ValueKey('sharing-confirm-revoke'),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Revoke')),
              ],
            ));
    if (confirmed != true) return;
    await _act(() =>
        widget.source.revokePersonGrant(widget.workspaceId, person.userId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final title = Text('Share workspace',
        style:
            theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700));
    final Widget invite = _canInvite
        ? IconButton(
            key: const ValueKey('sharing-invite'),
            tooltip: 'Add people',
            onPressed: _busy || _loading || !(_plan?.loaded ?? true)
                ? null
                : _addPeople,
            icon: const Icon(Icons.add))
        : Tooltip(
            key: const ValueKey('sharing-requires-paid'),
            message: 'Sharing a Workspace is part of $paidPlanName.',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(paidPlanName, style: muted),
            ]),
          );
    final body = <Widget>[
      if (_loading)
        const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()))
      else if (_error != null)
        Row(children: [
          const Expanded(child: Text('Sharing could not be loaded.')),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ])
      else ...[
        for (final invitation
            in _invitations.where((item) => item.status == 'pending'))
          ListTile(
              key: ValueKey('sharing-invitation-${invitation.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(invitation.email),
              subtitle: Align(
                  alignment: Alignment.centerLeft,
                  child: ActionStatusChip(
                      status: axInvitationStatus(invitation.status),
                      kind: AxActionKind.invitation)),
              trailing: TextButton(
                  key: ValueKey('sharing-revoke-invitation-${invitation.id}'),
                  onPressed: _busy
                      ? null
                      : () => _act(() => widget.source
                          .revokeWorkspaceInvitation(
                              widget.workspaceId, invitation.id)),
                  child: const Text('Cancel invitation'))),
        if (_people.isEmpty)
          Text('No one has access yet.', style: muted)
        else
          for (final person in _people) _personTile(person, muted),
      ],
    ];
    if (widget.expandable) {
      return Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          key: const ValueKey('sharing-expansion'),
          leading: const Icon(Icons.group_add_outlined),
          title: title,
          subtitle: _loading || _error != null
              ? null
              : Text('${_people.where((p) => p.active).length} with access',
                  style: muted),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          expandedAlignment: Alignment.centerLeft,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Align(alignment: Alignment.centerRight, child: invite),
            ...body,
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [Expanded(child: title), invite]),
        const SizedBox(height: 8),
        ...body,
      ],
    );
  }

  int? _hours(AxPersonWithAccess person) => person.maxRunSecondsPerMonth == null
      ? null
      : person.maxRunSecondsPerMonth! ~/ 3600;

  Widget _quotaSelector(
      {required Key key,
      required int selected,
      required Map<int, String> choices,
      required ValueChanged<int> onChanged}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<int>(
      key: key,
      enabled: !_busy,
      color: SyntilaColors.composerBackground(isDark),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: SyntilaMenuStyle.shadow(isDark),
      shape: SyntilaMenuStyle.shape(isDark),
      menuPadding: SyntilaMenuStyle.padding,
      onSelected: onChanged,
      itemBuilder: (menuContext) => [
        for (final choice in choices.entries)
          SyntilaMenuEntry<int>(
            value: choice.key,
            child: MenuItemButton(
              style: SyntilaMenuStyle.item(isDark),
              leadingIcon: Icon(
                  choice.key == selected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 15),
              onPressed: () => Navigator.pop(menuContext, choice.key),
              child: Text(choice.value, style: SyntilaMenuStyle.textStyle),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(choices[selected]!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 16),
        ]),
      ),
    );
  }

  Widget _personTile(AxPersonWithAccess person, TextStyle muted) {
    final mode =
        person.mode == null ? 'Default access' : _modeLabels[person.mode]!;
    final usage = person.usage;
    final theme = Theme.of(context);
    final initial = person.displayName.trim().isEmpty
        ? '?'
        : person.displayName.trim()[0].toUpperCase();
    return Card(
        key: ValueKey('sharing-person-${person.userId}'),
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                CircleAvatar(
                    radius: 16,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    foregroundColor: theme.colorScheme.onPrimaryContainer,
                    child: Text(initial)),
                const SizedBox(width: 10),
                Expanded(
                    child: Text('${person.displayName} · ${person.email}',
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                if (person.active)
                  TextButton(
                      key: ValueKey('sharing-revoke-${person.userId}'),
                      onPressed: _busy ? null : () => _revokePerson(person),
                      child: const Text('Revoke access'))
                else
                  Text('Access revoked', style: muted),
              ]),
              Text(
                  '$mode${person.custom ? ' (custom)' : ''} · ${usage.requests} request${usage.requests == 1 ? '' : 's'} · about ${_duration(usage.approxSeconds)}'
                  '${usage.lastUsedAt == null ? '' : ' · last used ${usage.lastUsedAt}'}',
                  style: muted),
              if (person.active)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: Wrap(spacing: 16, runSpacing: 8, children: [
                    Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('At once:', style: muted),
                          _quotaSelector(
                            key: ValueKey('sharing-quota-${person.userId}'),
                            selected: person.maxConcurrentRequests.clamp(1, 10),
                            choices: {for (var n = 1; n <= 10; n++) n: '$n'},
                            onChanged: (value) => unawaited(_act(() =>
                                widget.source.setPersonQuota(
                                    widget.workspaceId, person.userId, value))),
                          ),
                        ]),
                    Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Run time per month:', style: muted),
                          _quotaSelector(
                            key: ValueKey('sharing-runtime-${person.userId}'),
                            selected: _runTimeHours.contains(_hours(person))
                                ? _hours(person) ?? -1
                                : -1,
                            choices: {
                              for (final hours in _runTimeHours)
                                hours ?? -1:
                                    hours == null ? 'No limit' : '$hours h'
                            },
                            onChanged: (hours) => unawaited(_act(() =>
                                widget.source.setPersonRunTimeLimit(
                                    widget.workspaceId,
                                    person.userId,
                                    hours == -1 ? null : hours * 3600))),
                          ),
                        ]),
                  ]),
                ),
              if (person.active &&
                  widget.memberAccessSource != null &&
                  widget.personAccessSource != null)
                ExpansionTile(
                  key: ValueKey('sharing-edit-${person.userId}'),
                  title: const Text('Show access'),
                  tilePadding: EdgeInsets.zero,
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  maintainState: true,
                  onExpansionChanged: (expanded) {
                    if (!expanded) unawaited(_load());
                  },
                  children: [
                    Container(
                        margin: const EdgeInsets.only(top: 4, bottom: 8),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                            border: Border.all(
                                color: Theme.of(context).dividerColor),
                            borderRadius: BorderRadius.circular(14)),
                        child: WorkspaceMemberAccessSection(
                            key: ValueKey('person-access-${person.userId}'),
                            workspaceId: widget.workspaceId,
                            workers: widget.workers,
                            source: widget.memberAccessSource!,
                            personSource: widget.personAccessSource,
                            userId: person.userId,
                            personName: person.displayName))
                  ],
                ),
              if (person.active && person.maxRunSecondsPerMonth != null)
                Text(
                    'Used this month: about ${_duration(person.usage.monthSeconds)} of ${_duration(person.maxRunSecondsPerMonth!)}',
                    style: muted),
            ])));
  }
}

/// Shown to a signed-in person who has been invited to use someone's
/// Workspace. Accepting only grants access; it adds no one to any Space.
class WorkspaceInvitationsBanner extends StatefulWidget {
  const WorkspaceInvitationsBanner({
    super.key,
    required this.source,
    this.onAccepted,
  });

  final AxWorkspaceSharingDataSource source;
  final VoidCallback? onAccepted;

  @override
  State<WorkspaceInvitationsBanner> createState() =>
      _WorkspaceInvitationsBannerState();
}

class _WorkspaceInvitationsBannerState
    extends State<WorkspaceInvitationsBanner> {
  List<AxMyWorkspaceInvitation> _invitations = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final next = await widget.source.loadMyWorkspaceInvitations();
      if (mounted) setState(() => _invitations = next);
    } catch (_) {
      // The banner is optional; a failed check simply shows nothing.
    }
  }

  Future<void> _accept(AxMyWorkspaceInvitation invitation) async {
    setState(() => _busy = true);
    try {
      await widget.source.acceptWorkspaceInvitation(invitation.id);
      widget.onAccepted?.call();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_invitations.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      for (final invitation in _invitations)
        Card(
            key: ValueKey('workspace-invitation-${invitation.id}'),
            child: ListTile(
                title: Text(
                    '${invitation.ownerName} invited you to use ${invitation.workspaceName}'),
                subtitle: const Text(
                    'Accepting lets your own Spaces run on it. The owner sees usage only.'),
                trailing: FilledButton(
                    key: ValueKey(
                        'accept-workspace-invitation-${invitation.id}'),
                    onPressed: _busy ? null : () => _accept(invitation),
                    child: const Text('Accept')))),
    ]);
  }
}
