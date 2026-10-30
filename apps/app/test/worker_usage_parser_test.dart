import 'dart:convert';

import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:syntila_design/syntila_design.dart';
import 'package:flutter_test/flutter_test.dart';

const _claude = '''
You are currently using your subscription to power your Claude Code usage

Current session: 0% used
Current week (all models): 21% used · resets Oct 22 at 8:59pm (Europe/Bratislava)

What's contributing to your limits usage?

Last 24h · 427 requests · 38 sessions
  51% of your usage was at >150k context

Last 7d · 2072 requests · 139 sessions
  38% of your usage was at >150k context
  Top subagents: Explore 1%
''';

const _codex = '''
{
  "ordinaryUsageAllowed": true,
  "rateLimits": {
    "limitId": "codex",
    "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1792244044},
    "secondary": {"usedPercent": 36, "windowDurationMins": 10080, "resetsAt": 1792662209},
    "planType": "plus"
  },
  "rateLimitResetCredits": {"availableCount": 1}
}
''';

const _gemini =
    'Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-24T08:34:56Z\n'
    'Gemini Models\tFive Hour Limit Remaining\t100%\t2026-10-17T13:34:56Z\n'
    'Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t75%\t2026-10-24T08:34:56Z\n';

const _geminiAtLimit = 'Gemini Models\tWeekly Limit Remaining\t64%\t'
    '2026-10-31T09:24:46Z\n'
    'Gemini Models\tFive Hour Limit Remaining\t95%\t'
    '2026-10-26T02:10:23Z\n'
    'Claude and GPT models\tWeekly Limit Remaining\t0%\t'
    '2026-10-31T09:07:12Z\n'
    'Claude and GPT models\tFive Hour Limit Remaining\tdisabled\t\n'
    'Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t93%\t'
    '2026-11-01T11:40:14Z\n';

/// GitHub Copilot `account.getQuota` on a Free plan (CLI 1.0.103).
const _copilot = '''
{
  "quotaSnapshots": {
    "chat": {"isUnlimitedEntitlement": false, "entitlementRequests": 200,
      "usedRequests": 2, "overage": 0, "remainingPercentage": 99,
      "resetDate": "2026-10-23T18:49:24.741Z", "hasQuota": true},
    "completions": {"isUnlimitedEntitlement": false,
      "entitlementRequests": 2000, "usedRequests": 0, "overage": 0,
      "remainingPercentage": 100, "resetDate": "2026-10-23T18:49:24.741Z",
      "hasQuota": true},
    "premium_interactions": {"isUnlimitedEntitlement": false,
      "entitlementRequests": 0, "usedRequests": 0, "overage": 0,
      "remainingPercentage": 0, "resetDate": "2026-10-23T18:49:24.741Z",
      "hasQuota": false}
  }
}
''';

const _grok = {
  'config': {
    'creditUsagePercent': 69.0,
    'currentPeriod': {
      'type': 'USAGE_PERIOD_TYPE_WEEKLY',
      'start': '2026-10-23T21:07:15.175+00:00',
      'end': '2026-10-30T21:07:15.175+00:00',
    },
    'prepaidBalance': {'val': 0},
    'isUnifiedBillingUser': true,
    'billingPeriodStart': '2026-10-23T21:07:15.175+00:00',
    'billingPeriodEnd': '2026-10-30T21:07:15.175+00:00',
  },
  'subscription_tier': 'Free',
};

void main() {
  test('Grok billing uses the common weekly usage window', () {
    final window = parseWorkerUsage(jsonEncode(_grok))!.windows.single;
    expect(window.label, 'Week');
    expect(window.usedPercent, 69);
    expect(window.remainingPercent, 31);
    expect(window.resetsAt, DateTime.parse('2026-10-30T21:07:15.175Z'));
  });

  test('Grok validates percentages and preserves raw fallback on bad reports',
      () {
    for (final value in [-1, 101, '69', null]) {
      expect(
          parseWorkerUsage(jsonEncode({
            'config': {
              'creditUsagePercent': value,
            }
          })),
          isNull);
    }
    expect(parseWorkerUsage('{"config":'), isNull);
    expect(
        parseWorkerUsage(jsonEncode({
          'config': {
            'creditUsagePercent': 69,
            'currentPeriod': {'end': 'invalid'},
          }
        })),
        isNull);
    for (final value in [0, 100]) {
      expect(
          parseWorkerUsage(jsonEncode({
            'config': {
              'creditUsagePercent': value,
            }
          }))!
              .windows
              .single
              .usedPercent,
          value);
    }
  });

  test('Grok uses billing end when current period is absent', () {
    final usage = parseWorkerUsage(jsonEncode({
      'config': {
        'creditUsagePercent': 20,
        'billingPeriodEnd': '2026-10-30T23:07:15+02:00',
      }
    }))!;
    expect(usage.windows.single.label, 'Credits');
    expect(
        usage.windows.single.resetsAt, DateTime.utc(2026, 10, 30, 21, 7, 15));
  });

  testWidgets('Grok billing renders the shared table and retains original JSON',
      (tester) async {
    final output = jsonEncode(_grok);
    final controller = AxWorkerUsageController(_Source(output));
    addTearDown(controller.dispose);
    await controller.load(
        workspaceId: 'w', workerId: 'grok', workerName: 'Grok');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body:
                AxWorkerUsagePanel(controller: controller, onRefresh: () {}))));
    expect(find.byKey(const ValueKey('worker-usage-table')), findsOneWidget);
    expect(find.text('Week'), findsOneWidget);
    expect(find.text('69% used'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        0.69);
    await tester
        .tap(find.byKey(const ValueKey('worker-usage-toggle-original')));
    await tester.pump();
    expect(find.text(output), findsOneWidget);
  });

  test('Copilot quota report', () {
    final now = DateTime.utc(2026, 10, 23, 20);
    final usage = parseWorkerUsage(_copilot, now: now)!;
    expect(usage.windows.map((w) => w.label),
        ['Chat requests', 'Code completions']);
    expect(usage.windows[0].usedPercent, 1);
    expect(usage.windows[1].usedPercent, 0);
    // The reported reset equals the snapshot time (past), so none is shown.
    expect(usage.windows.every((w) => w.resetsAt == null), isTrue);
    expect(usage.notes, [
      'Chat requests: 2 of 200 used',
      'Code completions: 0 of 2000 used',
      'Premium requests: not included in this plan',
    ]);
    final future = parseWorkerUsage(
        _copilot.replaceAll('2026-10-23T18:49:24.741Z', '2026-11-01T00:00:00Z'),
        now: now)!;
    expect(future.windows[0].resetsAt, DateTime.utc(2026, 11));
    expect(usageResetLabel(future.windows[0], now), 'Resets in 8 d 4 hr 0 min');
  });

  test('Claude report', () {
    final usage = parseWorkerUsage(_claude, now: DateTime.utc(2026, 10, 17))!;
    expect(usage.windows.map((w) => w.label), ['Session', 'Week']);
    expect(usage.windows[1].usedPercent, 21);
    expect(usage.windows[1].resetsText, 'Oct 22 at 8:59pm (Europe/Bratislava)');
    expect(usage.notes, isEmpty);
    expect(usage.windows[1].resetsAt, DateTime.utc(2026, 10, 22, 18, 59));
  });

  test('Codex report', () {
    final usage = parseWorkerUsage(_codex)!;
    expect(usage.windows.map((w) => w.label), ['5 hours', 'Week']);
    expect(usage.windows[1].usedPercent, 36);
    expect(usage.windows[0].resetsAt, DateTime.utc(2026, 10, 17, 13, 34, 4));
    expect(usage.windows[1].resetsAt, DateTime.utc(2026, 10, 22, 9, 43, 29));
    expect(usage.notes.any((n) => n.startsWith('Plan:')), isFalse);
    expect(usage.notes, contains('1 free rate limit reset available'));
  });

  test('Gemini report converts remaining to used', () {
    final usage = parseWorkerUsage(_gemini)!;
    expect(usage.windows.map((w) => w.label), ['Week', '5 hours', 'Week']);
    expect(usage.windows.map((w) => w.usedPercent), [0, 0, 25]);
    expect(usage.windows[2].group, 'Gemini 4 Argon');
    expect(usage.windows[1].resetsAt, DateTime.utc(2026, 10, 17, 13, 34, 56));
  });

  test('Gemini parses exhausted and disabled quota rows', () {
    final usage = parseWorkerUsage(_geminiAtLimit)!;
    expect(usage.windows.map((w) => w.usedPercent), [36, 5, 100, 7]);
    expect(usage.windows[2].group, 'Claude and GPT models');
    expect(usage.notes, [
      'Claude and GPT models: Five Hour Limit Remaining disabled',
    ]);
  });

  test('countdowns use hours for sessions and days for weeks', () {
    final now = DateTime.utc(2026, 10, 17);
    expect(
        usageResetLabel(
            AxUsageWindow(
                label: '5 hours',
                usedPercent: 0,
                resetsAt: now.add(const Duration(hours: 1, minutes: 29))),
            now),
        'Resets in 1 hr 29 min');
    expect(
        usageResetLabel(
            AxUsageWindow(
                label: 'Week',
                usedPercent: 0,
                resetsAt:
                    now.add(const Duration(days: 2, hours: 2, minutes: 30))),
            now),
        'Resets in 2 d 2 hr 30 min');
    expect(
        usageResetLabel(
            AxUsageWindow(
                label: 'Session',
                usedPercent: 0,
                resetsAt: now.add(const Duration(seconds: 1))),
            now),
        'Resets in 0 hr 1 min');
    expect(
        usageResetLabel(
            AxUsageWindow(label: 'Week', usedPercent: 0, resetsAt: now), now),
        'Reset time reached — refresh usage');
    expect(
        usageResetLabel(
            const AxUsageWindow(label: 'Session', usedPercent: 0), now),
        '');
  });

  test('Claude reset dates handle DST, year rollover and unknown zones', () {
    AxUsageWindow window(String text, DateTime now) =>
        parseWorkerUsage('Current week (all models): 21% used · resets $text',
                now: now)!
            .windows
            .single;
    expect(
        window('Oct 26 at 8:59pm (Europe/Bratislava)',
                DateTime.utc(2026, 10, 17))
            .resetsAt,
        DateTime.utc(2026, 10, 26, 19, 59));
    expect(
        window('Jan 2 at 12:30am (Europe/Bratislava)',
                DateTime.utc(2026, 12, 31))
            .resetsAt,
        DateTime.utc(2027, 1, 1, 23, 30));
    expect(
        window('8:59pm (Europe/Bratislava)', DateTime.utc(2026, 10, 17, 20))
            .resetsAt,
        DateTime.utc(2026, 10, 18, 18, 59));
    final unknown =
        window('Oct 22 at 8:59pm (Unknown/Zone)', DateTime.utc(2026, 10, 17));
    expect(unknown.resetsAt, isNull);
    expect(
        usageResetLabel(unknown, DateTime.utc(2026)), contains('Unknown/Zone'));
  });

  test('unknown or malformed reports are not parsed', () {
    for (final text in [
      '',
      'Usage: unavailable',
      '{not json',
      '{"rateLimits": {"primary": {"usedPercent": 140, "windowDurationMins": 300}}}',
      '{"other": 1}',
      'Current session: lots used',
      'Gemini Models\tWeekly Limit Remaining\t100%',
      'Gemini Models\tWeekly Limit Remaining\t101%\t2026-10-24T08:34:56Z',
      'Gemini Models\tWeekly Limit Remaining\t50%\tnot-a-date',
      '$_gemini\nextra unexpected line',
    ]) {
      expect(parseWorkerUsage(text), isNull, reason: text);
    }
  });

  testWidgets('panel shows summary, original on request, raw on failure',
      (tester) async {
    Future<AxWorkerUsageController> pump(String output) async {
      final controller = AxWorkerUsageController(_Source(output));
      await controller.load(
          workspaceId: 'w', workerId: 'k', workerName: 'Worker');
      return controller;
    }

    final ok = await pump(_codex
        .replaceAll('1792244044', '4102444800')
        .replaceAll('1792662209', '4103049600'));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AxWorkerUsagePanel(controller: ok, onRefresh: () {}))));
    expect(find.byKey(const ValueKey('worker-usage-table')), findsOneWidget);
    expect(find.byIcon(Icons.speed), findsNothing);
    expect(find.text('Worker usage'), findsOneWidget);
    expect(find.textContaining('Plan:'), findsNothing);
    final original = find.text('Original');
    expect(find.ancestor(of: original, matching: find.byType(TextButton)),
        findsNothing);
    final timestamp = find.textContaining('as of ');
    expect(timestamp, findsNothing);
    final refresh = tester.widget<IconButton>(find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Refresh usage'));
    expect(refresh.constraints,
        const BoxConstraints.tightFor(width: 32, height: 32));
    expect((refresh.icon as Icon).size, 20);
    expect(refresh.style!.shape!.resolve({}), isA<RoundedRectangleBorder>());
    expect(tester.widget<Text>(original).style,
        Theme.of(tester.element(original)).textTheme.bodySmall);

    final bar = tester
        .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator))
        .first;
    expect(bar.color, SyntilaColors.primaryForeground(false));
    expect(bar.backgroundColor, SyntilaColors.surfaceHoverLight);
    expect(find.textContaining('Resets in'), findsWidgets);
    for (final element in find.textContaining('Resets in').evaluate()) {
      final paragraph = element.renderObject! as RenderParagraph;
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(paragraph.size.width, greaterThan(120));
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                    width: 400,
                    child: AxWorkerUsagePanel(
                        controller: ok, onRefresh: () {}))))));
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                    width: 240,
                    child: AxWorkerUsagePanel(
                        controller: ok, onRefresh: () {}))))));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('% used'), findsWidgets);
    expect(find.textContaining('Resets in'), findsWidgets);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
            body: AxWorkerUsagePanel(
                controller: ok, onRefresh: () {}, attached: true))));
    await tester.pump(const Duration(milliseconds: 300));
    final darkBar = tester
        .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator))
        .first;
    expect(darkBar.color, SyntilaColors.primaryForeground(true));
    expect(darkBar.backgroundColor, SyntilaColors.surfaceHoverDark);

    await tester
        .tap(find.byKey(const ValueKey('worker-usage-toggle-original')));
    await tester.pump();
    expect(find.byKey(const ValueKey('worker-usage-table')), findsNothing);
    expect(find.byKey(const ValueKey('worker-usage-text')), findsOneWidget);
    expect(ok.visible, isTrue);
    await tester.tap(find.byKey(const ValueKey('worker-usage-text')));
    await tester.pump();
    expect(ok.visible, isTrue);

    final bad = await pump('something new');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AxWorkerUsagePanel(controller: bad, onRefresh: () {}))));
    expect(find.byKey(const ValueKey('worker-usage-unparsed')), findsOneWidget);
    expect(find.text('something new'), findsOneWidget);
  });
}

class _Source implements AxWorkerUsageDataSource {
  _Source(this.output);
  final String output;
  @override
  Future<AxWorkerUsageReport> readWorkerUsage(
          {required String workspaceId, required String workerId}) async =>
      AxWorkerUsageReport(
          status: 'ok', output: output, fetchedAt: DateTime.utc(2026, 10, 17));
}
