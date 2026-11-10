import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';
import '../../brand.dart';

const _plusName = 'Syntila Plus';

/// Approved Syntila Plus prices in whole US dollars. There is no checkout yet,
/// so the page shows them without a purchase action.
class PlusPrice {
  const PlusPrice(this.period, this.unit, this.dollars);

  final String period;
  final String unit;
  final int dollars;
}

const plusPrices = [
  PlusPrice('1 month', 'month', 9),
  PlusPrice('1 year', 'year', 81),
];

/// Whole-percent saving of the yearly price against twelve monthly payments.
int get plusYearlySavingPercent {
  final monthly = plusPrices[0].dollars * 12;
  return ((monthly - plusPrices[1].dollars) * 100 / monthly).round();
}

/// One line of the Free and Plus comparison. The values mirror the limits in
/// Cloud's `account-plan.ts`, which enforces them; this page only explains.
class _Benefit {
  const _Benefit(this.feature, this.free, this.plus, [this.note]);

  final String feature;
  final String free;
  final String plus;
  final String? note;
}

// Values shown as an icon. The words stay as the tooltip and in the row's
// screen-reader label.
const _included = 'Included';
const _notIncluded = 'Not included';
const _noPlanLimit = 'No plan limit';

const _benefitGroups = <(String, List<_Benefit>)>[
  (
    'AI work',
    [
      _Benefit('Chat & Work', _included, _included),
      _Benefit('Research', _notIncluded, _included,
          'Independent investigations by different models, combined into one answer. The person sending the request needs Plus.'),
      _Benefit('Implement', _notIncluded, _included,
          'Work planned in phases and carried out step by step with verification. The person sending the request needs Plus.'),
      _Benefit('AI tasks running at once', '1', _noPlanLimit,
          'Counts the tasks you start, in every Space. Your Workspace\'s parallel slots and your AI provider\'s limits still apply.'),
    ]
  ),
  (
    'Workspaces',
    [
      _Benefit('Personal Workspaces', '1', _noPlanLimit,
          'The machines you connect to run AI work.'),
      _Benefit('Share Workers with Space members', _included, _included,
          'Let the members of your Spaces use your Workspace\'s Workers for Chat and Work in those Spaces.'),
      _Benefit('Share a Workspace with a person', _notIncluded, _included,
          'Invite someone to use your whole Workspace as their own, in any of their Spaces. Only you need Plus; the people you invite can be on Free.'),
    ]
  ),
  (
    'Collaboration',
    [
      _Benefit('People per Space', '4', _noPlanLimit,
          'Including the owner. Pending invitations count. The Space owner\'s plan decides.'),
    ]
  ),
  (
    'Files',
    [
      _Benefit('Upload storage', '1 GB', '25 GB',
          'Counts the files you upload, in every Space.'),
      _Benefit('Size of one file', '25 MB', '100 MB'),
    ]
  ),
];

/// The viewer's plan, the Plus prices and the Free and Plus comparison.
/// Purchases are not possible yet, so the page offers no purchase action.
class SubscriptionPage extends StatelessWidget {
  const SubscriptionPage({super.key, required this.plan});

  final AxAccountPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Plans & subscription')),
      body: LayoutBuilder(builder: (context, constraints) {
        // Larger text needs the room a narrow screen lacks, so both stack.
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final wide = constraints.maxWidth / scale >= 640;
        final gutter = wide ? SyntilaSpacing.xl : SyntilaSpacing.lg;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
              horizontal: gutter, vertical: SyntilaSpacing.xl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CurrentPlanCard(plan: plan),
                  const SizedBox(height: SyntilaSpacing.xxl),
                  _Heading(_plusName, style: text.titleLarge),
                  const SizedBox(height: SyntilaSpacing.xs),
                  Text(
                      'Use Research and Implement, run AI tasks in parallel, connect more machines, share your Workspace and bring more people and files into your Spaces.',
                      style: text.bodyMedium?.copyWith(color: muted)),
                  const SizedBox(height: SyntilaSpacing.lg),
                  _Prices(wide: wide),
                  const SizedBox(height: SyntilaSpacing.md),
                  _BillingNotice(isPaid: plan.isPaid),
                  const SizedBox(height: SyntilaSpacing.xxl),
                  _Heading('Compare plans', style: text.titleLarge),
                  const SizedBox(height: SyntilaSpacing.md),
                  _Comparison(wide: wide),
                  const SizedBox(height: SyntilaSpacing.xxl),
                  _Heading('If your plan changes', style: text.titleMedium),
                  const SizedBox(height: SyntilaSpacing.sm),
                  Text(
                      'Moving from Plus to Free never deletes anything. Your Workspaces, Space members and files stay, and running AI tasks finish. '
                      'You can\'t add more until you are within the Free limits, and people you shared a Workspace with can\'t use it until you return to Plus.',
                      style: text.bodyMedium?.copyWith(color: muted)),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label, {this.style});

  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) =>
      Semantics(header: true, child: Text(label, style: style));
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.highlighted = false, this.padding});

  final Widget child;
  final bool highlighted;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(SyntilaSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SyntilaRadius.radiusLg,
        border: Border.all(
            color: highlighted ? colors.primary : colors.outlineVariant,
            width: highlighted ? 1.5 : 1),
      ),
      child: child,
    );
  }
}

class _CurrentPlanCard extends StatelessWidget {
  const _CurrentPlanCard({required this.plan});

  final AxAccountPlan plan;

  String? _status(BuildContext context) {
    if (!plan.isPaid) return null;
    final end = plan.currentPeriodEnd;
    if (end == null) return 'Active';
    final date =
        MaterialLocalizations.of(context).formatShortDate(end.toLocal());
    return switch (plan.status) {
      'past_due' => 'Payment needs attention. Access until $date',
      'trialing' => 'Trial until $date',
      _ => 'Active until $date',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final status = _status(context);
    final owned = plan.ownedWorkspaces;
    final limit = plan.workspaceLimit;
    final storage = plan.attachmentStorageBytes;
    final fileSize = plan.attachmentMaxFileBytes;
    final facts = [
      if (owned != null)
        limit == null
            ? '$owned personal Workspace${owned == 1 ? '' : 's'}'
            : '$owned of $limit personal Workspace${limit == 1 ? '' : 's'} used',
      if (storage != null) '${formatFileSize(storage)} upload storage',
      if (fileSize != null) 'Files up to ${formatFileSize(fileSize)}',
    ];
    return _Panel(
      highlighted: plan.isPaid,
      padding: const EdgeInsets.all(SyntilaSpacing.xl),
      child: Column(
        key: const ValueKey('subscription-current-plan'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your plan',
              style: theme.textTheme.labelLarge?.copyWith(color: muted)),
          const SizedBox(height: SyntilaSpacing.xs),
          _Heading(plan.isPaid ? _plusName : 'Free',
              style: theme.textTheme.headlineMedium),
          if (status != null) ...[
            const SizedBox(height: SyntilaSpacing.xs),
            Text(status, style: theme.textTheme.bodyMedium),
          ],
          if (facts.isNotEmpty) ...[
            const SizedBox(height: SyntilaSpacing.md),
            for (final fact in facts)
              Padding(
                padding: const EdgeInsets.only(top: SyntilaSpacing.xs),
                child: Text(fact,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              ),
          ],
        ],
      ),
    );
  }
}

class _Prices extends StatelessWidget {
  const _Prices({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final price in plusPrices)
        _PriceCard(
            price: price,
            saving: price.unit == 'year'
                ? 'Save $plusYearlySavingPercent% compared with paying monthly'
                : null),
    ];
    if (!wide) {
      return Column(children: [
        for (final (index, card) in cards.indexed) ...[
          if (index > 0) const SizedBox(height: SyntilaSpacing.sm),
          card,
        ],
      ]);
    }
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (index, card) in cards.indexed) ...[
          if (index > 0) const SizedBox(width: SyntilaSpacing.md),
          Expanded(child: card),
        ],
      ]),
    );
  }
}

class _PriceCard extends StatelessWidget {
  const _PriceCard({required this.price, this.saving});

  final PlusPrice price;
  final String? saving;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      label: '${price.period}: ${price.dollars} US dollars'
          '${saving == null ? '' : '. $saving'}',
      child: ExcludeSemantics(
        child: _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(price.period,
                  style: theme.textTheme.labelLarge?.copyWith(color: muted)),
              const SizedBox(height: SyntilaSpacing.xs),
              Text.rich(TextSpan(children: [
                TextSpan(
                    text: '\$${price.dollars}',
                    style: theme.textTheme.headlineMedium),
                TextSpan(
                    text: ' / ${price.unit}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              ])),
              if (saving != null) ...[
                const SizedBox(height: SyntilaSpacing.xs),
                Text(saving!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.primary)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BillingNotice extends StatelessWidget {
  const _BillingNotice({required this.isPaid});

  final bool isPaid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      key: const ValueKey('subscription-billing-notice'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.info_outline, size: 16, color: muted),
        ),
        const SizedBox(width: SyntilaSpacing.sm),
        Expanded(
          child: Text(
              isPaid
                  ? 'Your account has $_plusName. Managing a subscription in the app is not available yet.'
                  : 'Buying $_plusName in the app is not available yet. Nothing on this page charges you; billing terms will be shown before any purchase.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
      ],
    );
  }
}

class _Comparison extends StatelessWidget {
  const _Comparison({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = Divider(height: 1, color: theme.colorScheme.outlineVariant);
    return _Panel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (wide) ...[
            _WideRow(
              feature: const SizedBox.shrink(),
              free: Text('Free', style: theme.textTheme.titleSmall),
              plus: Text(_plusName, style: theme.textTheme.titleSmall),
            ),
            divider,
          ],
          for (final (index, (title, benefits)) in _benefitGroups.indexed) ...[
            if (index > 0) divider,
            Padding(
              padding: const EdgeInsets.fromLTRB(SyntilaSpacing.lg,
                  SyntilaSpacing.lg, SyntilaSpacing.lg, SyntilaSpacing.xs),
              child: _Heading(title,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
            for (final benefit in benefits)
              _BenefitRow(benefit: benefit, wide: wide),
            const SizedBox(height: SyntilaSpacing.sm),
          ],
          divider,
          Padding(
            padding: const EdgeInsets.all(SyntilaSpacing.lg),
            child: Wrap(
              spacing: SyntilaSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.all_inclusive,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                Text(
                    'No limit set by the plan. Other limits, such as your Workspace\'s capacity, still apply.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WideRow extends StatelessWidget {
  const _WideRow(
      {required this.feature, required this.free, required this.plus});

  final Widget feature;
  final Widget free;
  final Widget plus;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: SyntilaSpacing.lg, vertical: SyntilaSpacing.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: feature),
          for (final value in [free, plus]) ...[
            const SizedBox(width: SyntilaSpacing.lg),
            // The values are short, so their columns stay narrow.
            SizedBox(
                width: 104 * MediaQuery.textScalerOf(context).scale(1),
                child: Align(alignment: Alignment.topCenter, child: value)),
          ],
        ]),
      );
}

class _BenefitRow extends StatelessWidget {
  const _BenefitRow({required this.benefit, required this.wide});

  final _Benefit benefit;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final body = theme.textTheme.bodyMedium;
    final strong = body?.copyWith(fontWeight: FontWeight.w600);
    final feature = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(benefit.feature, style: strong),
        if (benefit.note != null) ...[
          const SizedBox(height: SyntilaSpacing.xxs),
          Text(benefit.note!,
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ],
      ],
    );
    final Widget row;
    if (wide) {
      row = _WideRow(
        feature: feature,
        free: _PlanValue(benefit.free, style: body),
        plus: _PlanValue(benefit.plus, style: strong),
      );
    } else {
      Widget value(String planName, String value) => Padding(
            padding: const EdgeInsets.only(top: SyntilaSpacing.sm),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: Text(planName, style: body?.copyWith(color: muted))),
              const SizedBox(width: SyntilaSpacing.md),
              _PlanValue(value, style: planName == 'Free' ? body : strong),
            ]),
          );
      row = Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: SyntilaSpacing.lg, vertical: SyntilaSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            feature,
            value('Free', benefit.free),
            value(_plusName, benefit.plus),
          ],
        ),
      );
    }
    return Semantics(
      container: true,
      label: '${benefit.feature}. Free: ${benefit.free}. '
          '$_plusName: ${benefit.plus}.'
          '${benefit.note == null ? '' : ' ${benefit.note}'}',
      child: ExcludeSemantics(child: row),
    );
  }
}

/// One plan's value for a benefit: an icon for included, not included and no
/// plan limit, otherwise the text.
class _PlanValue extends StatelessWidget {
  const _PlanValue(this.value, {this.style});

  final String value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, color) = switch (value) {
      _included => (Icons.check_circle, colors.primary),
      _notIncluded => (Icons.close, colors.onSurfaceVariant),
      _noPlanLimit => (Icons.all_inclusive, colors.onSurface),
      _ => (null, null),
    };
    if (icon == null) return Text(value, style: style);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Tooltip(
      message: value,
      child: Icon(icon, size: 20 * scale, color: color, semanticLabel: value),
    );
  }
}
