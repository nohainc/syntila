import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';

/// "3 members · 1 pending invitation · 4 people allowed." for a Space, with the
/// reason a Free-owned Space cannot take more people. Cloud enforces the
/// allowance (the owner's plan decides); this only explains it. Existing
/// members and invitations stay manageable at the limit.
class SpaceMemberUsageNote extends StatefulWidget {
  const SpaceMemberUsageNote({
    super.key,
    required this.source,
    required this.spaceId,
    required this.isOwner,
    required this.members,
    required this.pendingInvitations,
  });

  final AxSpaceMemberUsageDataSource source;
  final String spaceId;
  final bool isOwner;

  /// Live counts from the member and invitation lists on screen; the allowance
  /// itself always comes from Cloud.
  final int members;
  final int pendingInvitations;

  static String summary({
    required int members,
    required int pendingInvitations,
    required int? limit,
  }) {
    final parts = [
      '$members ${members == 1 ? 'member' : 'members'}',
      if (pendingInvitations > 0)
        '$pendingInvitations pending ${pendingInvitations == 1 ? 'invitation' : 'invitations'}',
      if (limit != null) '$limit people allowed',
    ];
    return '${parts.join(' · ')}.';
  }

  @override
  State<SpaceMemberUsageNote> createState() => _SpaceMemberUsageNoteState();
}

class _SpaceMemberUsageNoteState extends State<SpaceMemberUsageNote> {
  AxSpaceMemberUsage? _usage;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(SpaceMemberUsageNote old) {
    super.didUpdateWidget(old);
    if (old.spaceId != widget.spaceId ||
        old.members != widget.members ||
        old.pendingInvitations != widget.pendingInvitations) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final spaceId = widget.spaceId;
    try {
      final usage = await widget.source.loadSpaceMemberUsage(spaceId: spaceId);
      if (mounted && spaceId == widget.spaceId) setState(() => _usage = usage);
    } catch (_) {
      // Counts are informational; Cloud still enforces the allowance.
    }
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    // No cap means there is nothing to report; unlimited is not advertised.
    if (usage == null || usage.limit == null) return const SizedBox.shrink();
    final atLimit = widget.members + widget.pendingInvitations >= usage.limit!;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      key: const ValueKey('space-member-usage'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            SpaceMemberUsageNote.summary(
              members: widget.members,
              pendingInvitations: widget.pendingInvitations,
              limit: usage.limit,
            ),
            style: TextStyle(fontSize: 13, color: muted),
          ),
          if (atLimit)
            Text(
              widget.isOwner
                  ? 'Free includes up to ${usage.limit} people in each Space, including the owner. Upgrade to Syntila Plus to allow larger Spaces, or remove a member or invitation.'
                  : 'Free includes up to ${usage.limit} people in each Space, including the owner. The Space owner needs to upgrade or free a slot.',
              style: TextStyle(fontSize: 13, color: muted),
            ),
        ],
      ),
    );
  }
}
