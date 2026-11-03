import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';

/// An honest overview until a billing provider and prices are configured.
class SubscriptionPage extends StatelessWidget {
  const SubscriptionPage({super.key, required this.plan});

  final AxAccountPlan plan;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Plans & subscription')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Make more room for your work',
                    style: text.headlineMedium),
                const SizedBox(height: 12),
                Text(
                    'Syntila Plus gives you more space to collaborate and run AI work in parallel.',
                    style: text.bodyLarge),
                const SizedBox(height: 12),
                Chip(
                    label: Text(
                        'Your current plan: ${plan.isPaid ? 'Syntila Plus' : 'Free'}')),
                const SizedBox(height: 32),
                Text('Choose your subscription', style: text.titleLarge),
                const SizedBox(height: 8),
                const Text(
                    'Purchases are not available yet. Pricing and billing terms will be shown when checkout is ready.'),
                const SizedBox(height: 16),
                LayoutBuilder(builder: (context, constraints) {
                  final width = constraints.maxWidth >= 650
                      ? (constraints.maxWidth - 24) / 3
                      : constraints.maxWidth;
                  return Wrap(spacing: 12, runSpacing: 12, children: [
                    for (final period in const ['1 week', '1 month', '1 year'])
                      SizedBox(
                          width: width,
                          child: Card(
                            child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(period, style: text.titleLarge),
                                    const SizedBox(height: 12),
                                    Text('Pricing coming soon',
                                        style: text.titleMedium),
                                    const SizedBox(height: 16),
                                    const FilledButton(
                                        onPressed: null,
                                        child: Text('Not available yet')),
                                  ],
                                )),
                          )),
                  ]);
                }),
                const SizedBox(height: 40),
                Text('Compare plans', style: text.titleLarge),
                const SizedBox(height: 12),
                const Card(
                    child: Column(children: [
                  _ComparisonRow('Feature', 'Free', 'Syntila Plus',
                      header: true),
                  _ComparisonRow('Chat & Work', 'Included', 'Included'),
                  _ComparisonRow(
                      'Personal Workspaces', '1', 'No plan-based cap'),
                  _ComparisonRow('Workspace sharing', 'Join shared Workspaces',
                      'Share your Workspace'),
                  _ComparisonRow('People per owned Space', '4, including owner',
                      'No plan-based cap'),
                  _ComparisonRow('AI executions', '1 at a time',
                      'Parallel, subject to capacity'),
                  _ComparisonRow('Uploaded storage', '1 GB', '25 GB'),
                  _ComparisonRow('Individual file size', '25 MB', '100 MB'),
                ])),
                const SizedBox(height: 16),
                Text(
                    'Space limits depend on the owner’s plan. Upload limits apply to the uploader. AI execution also depends on available Workspace capacity and your Worker’s capabilities.',
                    style: text.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComparisonRow extends StatelessWidget {
  const _ComparisonRow(this.feature, this.free, this.plus,
      {this.header = false});
  final String feature;
  final String free;
  final String plus;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final style = header
        ? Theme.of(context).textTheme.titleSmall
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 4, child: Text(feature, style: style)),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: Text(free, style: style)),
        const SizedBox(width: 8),
        Expanded(flex: 4, child: Text(plus, style: style)),
      ]),
    );
  }
}
