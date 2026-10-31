import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';

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

  AxAccountPlan get plan => _plan;
  bool get loaded => _loaded;

  Future<void> refresh() async {
    try {
      _plan = await _source.loadAccountPlan();
    } catch (_) {
      _plan = AxAccountPlan.free;
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
            title: Text(!_controller.loaded
                ? 'Loading…'
                : plan.isPaid
                    ? paidPlanName
                    : 'Free'),
            subtitle: plan.isPaid && end != null
                ? Text(plan.status == 'past_due'
                    ? 'Access until ${MaterialLocalizations.of(context).formatMediumDate(end.toLocal())}'
                    : 'Renews ${MaterialLocalizations.of(context).formatMediumDate(end.toLocal())}')
                : null,
          );
        },
      );
}
