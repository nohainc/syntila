import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';
import 'subscription_page.dart';

/// Product name of the paid tier. Cloud and the API only say `paid`.
const paidPlanName = 'Syntila Plus';

/// Paid feature names; they match `PAID_FEATURES` in Cloud.
const workspaceSharingFeature = 'workspace.sharing';

/// Loads the viewer's plan once and shares it with gated widgets. Unknown or
/// failed loads count as Free; Cloud still decides every paid action.
class AccountPlanController extends ChangeNotifier {
  AccountPlanController(this._source);

  final AxAccountPlanDataSource _source;
  AxAccountPlan _plan = AxAccountPlan.free;
  bool _loaded = false;
  bool _loadFailed = false;

  AxAccountPlan get plan => _plan;
  bool get loaded => _loaded;
  bool get loadFailed => _loadFailed;

  Future<void> refresh() async {
    try {
      _plan = await _source.loadAccountPlan();
      _loadFailed = false;
      // Any successful load (Profile, sharing, a refresh after an upgrade or
      // a server denial) updates what the composers offer.
      AxAccountPlanCache.instance.plan = _plan;
    } catch (_) {
      _plan = AxAccountPlan.free;
      _loadFailed = true;
    }
    _loaded = true;
    notifyListeners();
  }
}

/// Shows [child] when the plan includes [feature], otherwise [locked].
class PaidFeatureGate extends StatelessWidget {
  const PaidFeatureGate({
    super.key,
    required this.controller,
    required this.feature,
    required this.child,
    this.locked = const SizedBox.shrink(),
  });

  final AccountPlanController controller;
  final String feature;
  final Widget child;
  final Widget locked;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.plan.has(feature) ? child : locked,
      );
}

/// Profile summary of the viewer's plan.
class AccountPlanSummary extends StatefulWidget {
  const AccountPlanSummary({super.key, required this.source});

  final AxAccountPlanDataSource source;

  @override
  State<AccountPlanSummary> createState() => _AccountPlanSummaryState();
}

class _AccountPlanSummaryState extends State<AccountPlanSummary> {
  late final _controller = AccountPlanController(widget.source);

  @override
  void initState() {
    super.initState();
    unawaited(_controller.refresh());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final plan = _controller.plan;
          final end = plan.currentPeriodEnd;
          return ListTile(
            key: const ValueKey('profile-account-plan'),
            contentPadding: EdgeInsets.zero,
            trailing: TextButton(
              onPressed: !_controller.loaded || _controller.loadFailed
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) =>
                                SubscriptionPage(plan: _controller.plan)),
                      ),
              child: const Text('View plans'),
            ),
            title: Text(!_controller.loaded
                ? 'Loading…'
                : _controller.loadFailed
                    ? 'Plan unavailable'
                    : plan.isPaid
                        ? paidPlanName
                        : 'Free'),
            subtitle: _controller.loadFailed
                ? const Text(
                    'Could not load your plan. Please try again later.')
                : plan.isPaid && end != null
                    ? Text(plan.status == 'past_due'
                        ? 'Access until ${MaterialLocalizations.of(context).formatMediumDate(end.toLocal())}'
                        : 'Renews ${MaterialLocalizations.of(context).formatMediumDate(end.toLocal())}')
                    : _controller.loaded && !plan.isPaid
                        // Free runs one AI task at a time; Plus runs them in parallel.
                        ? const Text('$paidPlanName: Run AI tasks in parallel.')
                        : null,
          );
        },
      );
}

/// Owned Workspace usage against the Free allowance. Shown on the Workspaces
/// page; Cloud refuses registrations past the allowance, this only explains it.
/// Existing Workspaces above the allowance (for example after a downgrade)
/// stay connected and manageable; only new registrations are blocked.
class WorkspaceAllowanceNote extends StatefulWidget {
  const WorkspaceAllowanceNote({super.key, required this.source});

  final AxAccountPlanDataSource source;

  @override
  State<WorkspaceAllowanceNote> createState() => _WorkspaceAllowanceNoteState();
}

class _WorkspaceAllowanceNoteState extends State<WorkspaceAllowanceNote> {
  late final _controller = AccountPlanController(widget.source);

  @override
  void initState() {
    super.initState();
    unawaited(_controller.refresh());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final plan = _controller.plan;
          final owned = plan.ownedWorkspaces;
          if (owned == null) return const SizedBox.shrink();
          final limit = plan.workspaceLimit;
          final atLimit = limit != null && owned >= limit;
          return Padding(
            key: const ValueKey('workspace-allowance'),
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(limit == null
                    ? '$owned personal Workspaces ($paidPlanName, no limit)'
                    : '$owned of $limit personal Workspace${limit == 1 ? '' : 's'} used (Free)'),
                if (atLimit)
                  const Text(
                      'Free includes one personal Workspace. Upgrade to $paidPlanName to connect more machines.'),
              ],
            ),
          );
        },
      );
}
