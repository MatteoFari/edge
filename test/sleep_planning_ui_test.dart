import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _data = SleepData(
  day: '2026-10-08',
  planUpdatedDay: '2026-10-08',
  planNightDay: '2026-10-08',
  baselineMin: 480,
  extraSleepMin: 60,
  retentionPercent: 85,
  adjustmentPercent: 25,
  maxExtraMin: 60,
  latestShortfallMin: 240,
  need: Metric(value: 540, tier: MetricTier.estimate, confidence: .2),
  debt: Metric(value: 240, tier: MetricTier.estimate, confidence: .2),
  tstHistory: [450, 470, 480, 460, 490],
  night: {
    'duration_min': 240,
    'in_bed_min': 250,
    'onset_ts': 1791420240,
    'wake_ts': 1791435696,
    'light_min': 100,
    'deep_min': 70,
    'rem_min': 70,
  },
);

Future<void> _pump(
  WidgetTester t,
  SleepData data, {
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool reduced = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(brightness, style: InterfaceStyle.expressive),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            disableAnimations: reduced,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: SleepDetail(data: data),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _showPlan(WidgetTester t) async {
  await t.scrollUntilVisible(
    find.text('Estimated sleep plan'),
    250,
    scrollable: find
        .descendant(
          of: find.byKey(const PageStorageKey('sleep-night')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await t.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'three estimates remain readable with large text in $brightness',
      (t) async {
        await _pump(t, _data, scale: 2, brightness: brightness);
        await _showPlan(t);
        expect(find.text('Baseline sleep estimate'), findsOneWidget);
        expect(find.text('Extra sleep recommended'), findsOneWidget);
        expect(find.text('Next sleep recommendation'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'plan follows usual comparisons once; shortfall is separate from extra',
    (t) async {
      await _pump(t, _data, reduced: false);
      final scrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey('sleep-night')),
            matching: find.byType(Scrollable),
          )
          .first;
      await _showPlan(t);
      await t.drag(scrollable, const Offset(0, 220));
      await t.pumpAndSettle();
      expect(find.text('Next sleep'), findsOneWidget);
      final usual = t.getTopLeft(find.text('Against your usual')).dy;
      final next = t.getTopLeft(find.text('Next sleep')).dy;
      expect(next, greaterThan(usual));
      expect(
        find.textContaining('4h 00m below your sleep reference'),
        findsOneWidget,
      );
      await t.scrollUntilVisible(
        find.text('Sleep need breakdown'),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('sleep-night')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Sleep need breakdown'));
      await t.pumpAndSettle();
      expect(find.text('Recent sleep shortfall'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'missing recent days do not render invented recommendation or zero debt',
    (t) async {
      await _pump(
        t,
        const SleepData(
          day: '2026-10-08',
          baselineMin: 480,
          latestShortfallMin: 240,
          planNightDay: '2026-10-08',
          missingPlanDays: 2,
        ),
      );
      expect(find.text('Baseline sleep estimate'), findsOneWidget);
      expect(find.text('Next sleep recommendation'), findsNothing);
      expect(
        find.textContaining('2 recent days are incomplete'),
        findsOneWidget,
      );
      expect(find.text('Recent sleep shortfall'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'explicit historical night does not display a current planning estimate',
    (t) async {
      await _pump(
        t,
        const SleepData(day: '2026-10-01', showCurrentPlan: false),
      );
      expect(find.text('Estimated sleep plan'), findsNothing);
    },
  );
}
