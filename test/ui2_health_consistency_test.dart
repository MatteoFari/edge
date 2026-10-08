import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/lab_catalogue.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show prettyDay;
import 'package:openstrap_edge/ui2/screens/investigate.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _latest = '2026-10-05';
const _older = '2026-10-03';
const _health = HealthData(
  today: {
    'status': {'today_day': _latest},
    'daily': {
      'resting_hr': {'value': 51, 'confidence': .8},
    },
  },
);

class _Repo extends LocalRepository {
  bool failOverview = false, failVitals = false;
  Completer<void>? holdVitals;

  @override
  Future<Map<String, dynamic>> getToday() async {
    if (failOverview) throw StateError('read failed');
    return _health.today;
  }

  @override
  Future<Map<String, dynamic>> getInsights() async => const {};

  @override
  Future<Map<String, dynamic>> getProfile() async => const {};

  @override
  Future<List<String>> availableDays() async => const [_latest, _older];

  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => const {};

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => {
    'date': date,
    'highs': {
      'low_hr': {'v': date == _latest ? 50 : 45},
      'peak_hr': {'v': date == _latest ? 150 : 120},
    },
  };

  @override
  Future<Map<String, dynamic>> getDayLungs(String date) async {
    final held = holdVitals;
    holdVitals = null;
    if (held != null) await held.future;
    if (failVitals) throw StateError('vitals failed');
    return {
      'resp': {
        'value': date == _latest ? 20.0 : 15.0,
        'label': 'Breathing rate',
        'experimental': true,
        'chart_key': 'resp_rate_experimental',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {
    'worn_min': 1200,
    'coverage_pct': 83.3,
  };

  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async => {
    'rmssd': date == _latest ? 80 : 40,
  };
}

Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump();
  }
}

Future<void> _pump(
  WidgetTester t,
  Widget screen, {
  AppState? app,
  InterfaceStyle style = InterfaceStyle.expressive,
  double scale = 1,
  bool reduceMotion = true,
}) async {
  t.view.physicalSize = const Size(390 * 3, 900 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(const SizedBox.shrink());
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ThemeController.seed(
            AppThemeChoice.light,
            Brightness.light,
            interfaceStyle: style,
          ),
        ),
        if (app != null) ChangeNotifierProvider<AppState>.value(value: app),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, style: style),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await _frames(t);
}

Finder get _search => find.descendant(
  of: find.byType(DomainSearchField),
  matching: find.byType(TextField),
);

ScrollPosition _scroll(WidgetTester t, int tab) => t
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(PageStorageKey('health-tab-$tab')),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

void main() {
  for (final style in InterfaceStyle.values) {
    testWidgets(
      '${style.name}: Explore searches methods and keeps absent routes',
      (t) async {
        await _pump(
          t,
          const HealthScreen(data: _health, explore: ExploreData(), tab: 1),
          style: style,
        );
        expect(
          find.byKey(const ValueKey('health-catalogue-spo2')),
          findsNothing,
        );
        await t.enterText(_search, 'RMSSD');
        await t.pumpAndSettle();
        final hrv = find.byKey(const ValueKey('health-catalogue-hrv'));
        expect(hrv, findsOneWidget);
        expect(t.widget<MetricRow>(hrv).sub, contains('Not measured yet'));
        await t.ensureVisible(hrv);
        await t.pumpAndSettle();
        final offset = _scroll(t, 1).pixels;
        await t.tap(hrv);
        await t.pumpAndSettle();
        expect(
          t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey,
          'hrv',
        );
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(t.widget<TextField>(_search).controller!.text, 'RMSSD');
        expect(_scroll(t, 1).pixels, closeTo(offset, .01));
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('Explore no-match and clear retain the whole honest catalogue', (
    t,
  ) async {
    await _pump(
      t,
      const HealthScreen(data: _health, explore: ExploreData(), tab: 1),
    );
    await t.enterText(_search, 'no-such-measure');
    await t.pumpAndSettle();
    expect(find.text('No measures match your search'), findsOneWidget);
    expect(find.text('0 results'), findsOneWidget);
    expect(find.byType(MetricRow), findsNothing);
    await t.tap(
      find.descendant(
        of: find.byType(DomainSearchField),
        matching: find.byType(Pressable),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('No measures match your search'), findsNothing);
    expect(find.byKey(const ValueKey('health-catalogue-hrv')), findsOneWidget);
    expect(t.widget<TextField>(_search).controller!.text, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'a failed Overview read retries and a failed refresh keeps readings',
    (t) async {
      final repo = _Repo()..failOverview = true;
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await _pump(t, const HealthScreen(), app: app);
      expect(find.text('Could not read your health readings'), findsOneWidget);
      expect(find.text('No resting heart rate'), findsNothing);
      repo.failOverview = false;
      await t.tap(find.text('Try again'));
      await _frames(t);
      expect(find.text('51'), findsOneWidget);
      repo.failOverview = true;
      app.bumpInsights();
      await _frames(t);
      expect(find.text('Could not read your health readings'), findsOneWidget);
      expect(find.text('51'), findsOneWidget);
      repo.failOverview = false;
      await t.tap(find.text('Try again'));
      await _frames(t);
      expect(find.text('Could not read your health readings'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'a pending or failed Vitals day never borrows the previous readings',
    (t) async {
      final repo = _Repo();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await _pump(t, const HealthScreen(data: _health, tab: 3), app: app);
      expect(find.text('20.0'), findsOneWidget);
      final held = Completer<void>();
      repo.holdVitals = held;
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _frames(t);
      expect(find.text('20.0'), findsNothing);
      expect(find.text('15.0'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      repo.failVitals = true;
      held.complete();
      await _frames(t);
      expect(find.text('Could not read your vitals'), findsOneWidget);
      expect(find.text('20.0'), findsNothing);
      repo.failVitals = false;
      await t.tap(find.text('Try again'));
      await _frames(t);
      expect(find.text('15.0'), findsOneWidget);
      final row = t
          .widgetList<MetricRow>(find.byType(MetricRow))
          .firstWhere((row) => row.name == 'Breathing rate');
      expect(
        (row.destination! as MetricDetail).metricKey,
        'resp_rate_experimental',
      );
      expect((row.destination! as MetricDetail).day, _older);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'held-night, selected HRV and latest temperature routes keep their dates',
    (t) async {
      const data = HealthData(
        today: {
          'status': {
            'today_day': _latest,
            'showing_prior_overnight': true,
            'overnight_day': _older,
          },
          'daily': {
            'resting_hr': {'value': 51, 'confidence': .8},
          },
        },
      );
      await _pump(t, const HealthScreen(data: data));
      final overview = t.widget<MetricRow>(find.byType(MetricRow).first);
      expect((overview.destination! as MetricDetail).day, _older);

      int stamp(String day) => localDayStartSec(day)! + 12 * 3600;
      await _pump(
        t,
        HealthScreen(
          data: HealthData(
            charts: {
              'resting_hr': [(t: stamp(_older), v: 51.0)],
            },
          ),
          tab: 2,
        ),
      );
      final trend = t.widget<TrendCard>(find.byType(TrendCard));
      expect((trend.destination! as MetricDetail).day, _older);

      final hrvData = HealthData(
        today: const {
          'status': {'today_day': _latest},
          'skin_temp': {'value': .25, 'confidence': .8},
        },
        charts: {
          'hrv': [
            (t: stamp('2026-10-02'), v: 35.0),
            (t: stamp(_older), v: 40.0),
            (t: stamp(_latest), v: 80.0),
          ],
        },
      );
      await _pump(
        t,
        HealthScreen(
          data: hrvData,
          vitals: const VitalsData(day: _older, hrv: {'rmssd': 40}),
          tab: 3,
        ),
      );
      expect(find.text('Latest night'), findsOneWidget);
      final temp = t
          .widgetList<MetricRow>(find.byType(MetricRow))
          .firstWhere((row) => row.name == 'Skin temperature');
      expect((temp.destination! as MetricDetail).day, _latest);
      final dive = t.widget<DeepDiveCard>(find.byType(DeepDiveCard));
      expect((dive.destination! as Investigate).day, _older);
      final chart = t.widget<ChartFrame>(find.byType(ChartFrame));
      expect(chart.series.last, 40);
      expect(chart.series.whereType<double>(), isNot(contains(80)));
      expect(chart.xLabels.last, prettyDay(_older));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('malformed Vitals abstains without a fabricated reading', (
    t,
  ) async {
    await _pump(
      t,
      const HealthScreen(
        data: _health,
        tab: 3,
        vitals: VitalsData(
          day: _older,
          timeline: {
            'highs': {
              'low_hr': {'v': 'bad'},
              'peak_hr': {'v': 120},
            },
          },
          lungs: {
            'resp': {'value': 'bad'},
          },
          wear: {'worn_min': 'bad', 'coverage_pct': 'bad'},
          hrv: {'rmssd': 'bad'},
        ),
      ),
    );
    expect(find.text('Nothing measured for this day'), findsOneWidget);
    expect(find.byType(MetricRow), findsNothing);
    expect(find.text('—'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('lab validation preserves the marker, value and invalid date', (
    t,
  ) async {
    final marker = kLabMarkersByKey['ferritin']!;
    await _pump(
      t,
      HealthScreen(
        data: _health,
        labs: LabsData(markers: [marker]),
        tab: 4,
      ),
    );
    await t.tap(find.text('Add a result'));
    await t.pumpAndSettle();
    final value = find.byKey(const ValueKey('health-lab-value'));
    final date = find.byKey(const ValueKey('health-lab-date'));
    await t.enterText(value, '78 ng/mL');
    await t.enterText(date, '2026-02-30');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('number on its own'), findsOneWidget);
    expect(
      t
          .widget<DropdownButton<LabMarker>>(
            find.byType(DropdownButton<LabMarker>),
          )
          .value,
      marker,
    );
    expect(
      t
          .widget<EditableText>(
            find.descendant(of: value, matching: find.byType(EditableText)),
          )
          .controller
          .text,
      '78 ng/mL',
    );
    expect(
      t
          .widget<EditableText>(
            find.descendant(of: date, matching: find.byType(EditableText)),
          )
          .controller
          .text,
      '2026-02-30',
    );
    await t.enterText(value, '78');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(
      find.text('The date needs to be YYYY-MM-DD. Nothing was saved.'),
      findsOneWidget,
    );
    await t.enterText(date, '2099-01-01');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(
      find.text('That date is after today. Nothing was saved.'),
      findsOneWidget,
    );
    expect(
      t
          .widget<EditableText>(
            find.descendant(of: value, matching: find.byType(EditableText)),
          )
          .controller
          .text,
      '78',
    );
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'search and realistic lab units fit at 3.1x with reduced motion',
    (t) async {
      await _pump(
        t,
        const HealthScreen(data: _health, explore: ExploreData(), tab: 1),
        scale: 3.1,
      );
      await t.enterText(_search, 'no-such-measure');
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final ferritin = kLabMarkersByKey['ferritin']!;
      await _pump(
        t,
        HealthScreen(
          data: _health,
          tab: 4,
          labs: LabsData(
            markers: [ferritin],
            results: const [
              {
                'marker': 'ferritin',
                'taken_on': _older,
                'value': 1248,
                'unit': 'ng/mL',
              },
            ],
          ),
        ),
        scale: 3.1,
      );
      expect(find.text('1248'), findsOneWidget);
      expect(find.text('ng/mL'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
