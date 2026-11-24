import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:url_launcher/url_launcher.dart';

import '../../ax/ax_data.dart';
import '../../brand.dart';

const _plusName = 'Syntila Plus';

/// Approved Syntila Plus prices in whole US dollars.
class PlusPrice {
  const PlusPrice(this.period, this.unit, this.dollars);

  final String period;
  final String unit;
  final int dollars;
}

const plusPrices = [
  PlusPrice('Monthly', 'month', 9),
  PlusPrice('Yearly', 'year', 81),
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
          'Combines independent investigations. The requester needs Plus.'),
      _Benefit('Implement', _notIncluded, _included,
          'Plans and verifies work in phases. The requester needs Plus.'),
      _Benefit('AI tasks running at once', '1', _noPlanLimit,
          'Across all Spaces. Worker and provider limits still apply.'),
    ]
  ),
  (
    'Workers',
    [
      _Benefit('Personal Workers', '1', _noPlanLimit,
          'Workers connected to run AI work.'),
      _Benefit('Share Workers with Space members', _included, _included,
          'Space members can use your Workers for Chat and Work in those Spaces.'),
      _Benefit('Share a Worker with a person', _notIncluded, _included,
          'Invite someone to use your Worker in any of their Spaces. Only you need Plus.'),
    ]
  ),
  (
    'Collaboration',
    [
      _Benefit('People per Space', '4', _noPlanLimit,
          'Includes the owner and pending invitations. The Space owner\'s plan decides.'),
    ]
  ),
  (
    'Files',
    [
      _Benefit('Upload storage', '1 GB', '20 GB', 'Across all Spaces.'),
      _Benefit('Size of one file', '10 MB', '100 MB'),
    ]
  ),
];

/// The viewer's plan, the Plus prices and the Free and Plus comparison.
/// The local development build can open the separate sandbox checkout.
class SubscriptionPage extends StatelessWidget {
  const SubscriptionPage({super.key, required this.plan});

  final AxAccountPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final sandboxCheckout = kDebugMode &&
        kIsWeb &&
        {'localhost', '127.0.0.1', '::1'}.contains(Uri.base.host);
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
                  _Prices(
                      wide: wide, sandboxCheckout: sandboxCheckout, plan: plan),
                  const SizedBox(height: SyntilaSpacing.md),
                  _BillingNotice(
                      isPaid: plan.isPaid, sandboxCheckout: sandboxCheckout),
                  const SizedBox(height: SyntilaSpacing.xxl),
                  _Heading('Compare plans', style: text.titleLarge),
                  const SizedBox(height: SyntilaSpacing.md),
                  _Comparison(wide: wide),
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
  const _Panel({required this.child, this.padding});

  final Widget child;
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
        border: Border.all(color: colors.outlineVariant),
      ),
      child: child,
    );
  }
}

class _Prices extends StatelessWidget {
  const _Prices(
      {required this.wide, required this.sandboxCheckout, required this.plan});

  final bool wide;
  final bool sandboxCheckout;
  final AxAccountPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isPastDue = plan.status == 'past_due';
    final status = plan.isPaid && plan.currentPeriodEnd != null
        ? '${isPastDue ? 'Payment needs attention. Access until' : plan.status == 'trialing' ? 'Trial until' : 'Active until'} ${MaterialLocalizations.of(context).formatShortDate(plan.currentPeriodEnd!.toLocal())}'
        : plan.isPaid
            ? 'Active'
            : null;
    final cards = [
      for (final price in plusPrices)
        _PriceCard(
          price: price,
          sandboxCheckout: sandboxCheckout,
          saving: price.unit == 'year'
              ? 'Save $plusYearlySavingPercent%'
              : 'Recommended',
          savingLabel: price.unit == 'year'
              ? 'Save $plusYearlySavingPercent% compared with paying monthly'
              : 'Recommended',
        ),
    ];
    final options = !wide
        ? Column(children: [
            for (final (index, card) in cards.indexed) ...[
              if (index > 0) const SizedBox(height: SyntilaSpacing.sm),
              card,
            ],
          ])
        : IntrinsicHeight(
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (index, card) in cards.indexed) ...[
              if (index > 0) const SizedBox(width: SyntilaSpacing.md),
              Expanded(child: card),
            ],
          ]));
    return Column(
      key: const ValueKey('subscription-current-plan'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading(_plusName, style: theme.textTheme.titleLarge),
        if (plan.isPaid && status != null) ...[
          const SizedBox(height: SyntilaSpacing.xs),
          Text(
            'Current plan: $status',
            style: theme.textTheme.bodySmall?.copyWith(
              color: isPastDue ? colors.error : colors.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        const SizedBox(height: SyntilaSpacing.md),
        options,
      ],
    );
  }
}

class _PriceCard extends StatelessWidget {
  const _PriceCard({
    required this.price,
    required this.sandboxCheckout,
    this.saving,
    this.savingLabel,
  });

  final PlusPrice price;
  final bool sandboxCheckout;
  final String? saving;
  final String? savingLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final content = Padding(
      padding: const EdgeInsets.all(SyntilaSpacing.xl),
      child: Semantics(
        button: sandboxCheckout,
        container: true,
        label: '${price.period}: ${price.dollars} US dollars'
            '${savingLabel == null ? '' : '. $savingLabel'}',
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: SyntilaSpacing.sm,
                runSpacing: SyntilaSpacing.xs,
                children: [
                  Text(price.period,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  if (saving != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: SyntilaSpacing.sm,
                          vertical: SyntilaSpacing.xs),
                      decoration: BoxDecoration(
                          color: colors.secondaryContainer,
                          borderRadius: SyntilaRadius.radiusLg),
                      child: Text(saving!,
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.onSecondaryContainer,
                              fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
              const SizedBox(height: SyntilaSpacing.lg),
              Center(
                child: Text('\$${price.dollars}',
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: SyntilaRadius.radiusLg,
        side: BorderSide(
          color: sandboxCheckout ? colors.outline : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: sandboxCheckout
          ? InkWell(
              onTap: () => launchUrl(
                Uri.base.resolve('/paddle-sandbox.html?plan=${price.unit}'),
                webOnlyWindowName: '_blank',
              ),
              child: content,
            )
          : content,
    );
  }
}

class _BillingNotice extends StatelessWidget {
  const _BillingNotice({required this.isPaid, required this.sandboxCheckout});

  final bool isPaid;
  final bool sandboxCheckout;

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
              sandboxCheckout
                  ? 'Sandbox test mode: no real payment will be taken.'
                  : isPaid
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
              child: Row(children: [
                Icon(
                    switch (title) {
                      'AI work' => Icons.auto_awesome_outlined,
                      'Workers' => Icons.devices_outlined,
                      'Collaboration' => Icons.groups_outlined,
                      _ => Icons.folder_outlined,
                    },
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: SyntilaSpacing.sm),
                Expanded(
                    child: _Heading(title,
                        style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))),
              ]),
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
                    'No limit set by the plan. Other limits, such as your Worker\'s capacity, still apply.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                SyntilaSpacing.lg, 0, SyntilaSpacing.lg, SyntilaSpacing.lg),
            child: Text(
                'Need more than 20 GB of upload storage? Contact support to discuss your options.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
