import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/weight_store.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/weight_trend.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Repo extends LocalRepository {
  Completer<Map<String, dynamic>>? past;
  bool failed = true;
  @override
  Future<Map<String, dynamic>> getToday() async => {
    'daily': {
      'readiness': {'value': 70, 'confidence': .8, 'tier': 'HIGH'},
    },
    'sleep': {'duration_min': {'value': 400, 'confidence': .8, 'tier': 'HIGH'}},
    'status': {'today_day': todayLabel()},
  };
  @override
  Future<Map<String, dynamic>> getInsights() async => {};
  @override
  Future<Map<String, dynamic>> getProfile() async => {};
  @override
  Future<int> pendingActivityCount() async => 0;
  @override
  Future<List<String>> availableDays() async => [
    todayLabel(),
    dayLabelOf(DateTime.now().subtract(const Duration(days: 1))),
  ];
  @override
  Future<Map<String, dynamic>> getDayOverview(String day) async =>
      past == null ? {'readiness': 42} : await past!.future;
  @override
  Future<Map<String, dynamic>> getDayStrain(String day) async => {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String day) async => {};
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async {
    if (failed) throw StateError('Read failed');
    return {'points': []};
  }

  @override
  Future<Map<String, dynamic>> getJournalInsights({
    String range = '90d',
  }) async => {};
  @override
  Future<Map<String, dynamic>> getCycle() async {
    if (failed) throw StateError('Read failed');
    return {'enabled': false};
  }
}

class _SleepRepo extends _Repo {
  bool held = false;
  Map<String, dynamic> plan = {
    'sleep_planning': {
      'reference': {'reference_sec': 480 * 60},
      'reference_confidence': .7,
    },
  };
  @override
  Future<Map<String, dynamic>> getInsights() async => plan;
  @override
  Future<Map<String, dynamic>> getToday() async => {
    'daily': {'readiness': 70},
    'sleep': {'duration_min': 240},
    'status': {'today_day': '2026-10-08',
      if (held) 'last_sleep_day': '2026-10-07'},
  };
  @override
  Future<Map<String, dynamic>> getDayOverview(String day) async => {'readiness': 70};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String day) async => {'duration_min': 240};
}

Future<void> _pump(
  WidgetTester t,
  Widget child, {
  AppState? app,
  bool expressive = false,
  bool imperial = false,
  bool reduced = true,
  double scale = 1,
  LocaleController? locale,
}) async {
  SharedPreferences.setMockInitialValues({});
  final theme = ThemeController.seed(
    AppThemeChoice.light,
    Brightness.light,
    interfaceStyle: expressive
        ? InterfaceStyle.expressive
        : InterfaceStyle.original,
  );
  final units = UnitsController.seed(
    imperial ? UnitSystem.imperial : UnitSystem.metric,
  );
  addTearDown(theme.dispose);
  addTearDown(units.dispose);
  t.view.physicalSize = const Size(390, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: units),
        if (app != null) ChangeNotifierProvider.value(value: app),
        if (locale != null) ChangeNotifierProvider.value(value: locale),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, style: expressive ? InterfaceStyle.expressive : InterfaceStyle.original),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(disableAnimations: reduced, textScaler: TextScaler.linear(scale)),
          child: w!,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await t.pump();
}

void main() {
  setUpAll(() async {
    for (final family in ['.SF Pro Text', 'Manrope']) {
      final loader = FontLoader(family);
      loader.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-400.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-600.ttf'));
      await loader.load();
    }
  });
  testWidgets('a pending or failed date load cannot relabel old Home values', (
    t,
  ) async {
    final repo = _Repo()..past = Completer();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await _pump(t, const HomeScreen(), app: app);
    await t.pumpAndSettle();
    for (var i = 0; i < 20; i++) { await t.pump(const Duration(milliseconds: 20)); }
    expect(find.text('70'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await t.pump();
    expect(find.text('70'), findsNothing);
    repo.past!.completeError(StateError('Read failed'));
    await t.pumpAndSettle();
    expect(find.text('70'), findsNothing);
    expect(find.text('Today could not be read'), findsOneWidget);
    repo.past = null;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('metric read failure offers retry instead of absence', (t) async {
    final repo = _Repo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await _pump(t, const MetricDetail('hrv'), app: app);
    await t.pumpAndSettle();
    expect(find.text('Could not load this summary'), findsOneWidget);
    expect(find.text('Nothing recorded today'), findsNothing);
    repo.failed = false;
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(find.text('Could not load this summary'), findsNothing);
    expect(find.text('Nothing recorded today'), findsOneWidget);
  });

  testWidgets('cycle read failure does not claim tracking is disabled', (
    t,
  ) async {
    final repo = _Repo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await _pump(t, const CycleTab(), app: app);
    await t.pumpAndSettle();
    expect(find.text('Could not load your data'), findsOneWidget);
    expect(find.text('Cycle tracking is off'), findsNothing);
    repo.failed = false;
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(find.text('Cycle tracking is off'), findsOneWidget);
  });

  testWidgets('horizontal chart inspection wins over enclosing tabs', (
    t,
  ) async {
    var tab = 0;
    double? value;
    await _pump(
      t,
      StatefulBuilder(
        builder: (c, update) => SubPages(
          index: tab,
          count: 2,
          onChanged: (i) => update(() => tab = i),
          builder: (c, i) => i == 0
              ? Center(
                  child: SizedBox(
                    height: 130,
                  width: double.infinity,
                    child: Scrubber(
                      value: value,
                      horizontalDragToScrub: true,
                      onChanged: (v) => value = v,
                      label: 'Sleep stages',
                      describe: (v) => '$v',
                      child: const ColoredBox(color: Colors.blue, child: SizedBox.expand()),
                    ),
                  ),
                )
              : const Text('Body clock'),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.drag(find.byType(Scrubber), const Offset(-180, 0));
    await t.pumpAndSettle();
    expect(tab, 0);
    expect(value, isNotNull);
    await t.dragFrom(const Offset(320, 30), const Offset(-240, 0));
    await t.pumpAndSettle();
    expect(tab, 1);
  });

  testWidgets('a passed alarm today is not Next or Later today', (t) async {
    await _pump(
      t,
      AlarmScreenView(
        armedAt: DateTime(2026, 10, 8, 7),
        state: AlarmArmState.confirmed,
        connected: true,
        now: DateTime(2026, 10, 8, 11),
        schedule: const [],
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('NEXT'), findsNothing);
    expect(find.text('Later today'), findsNothing);
    expect(find.textContaining('In the past'), findsOneWidget);
  });

  testWidgets('historical metric chart dates end at the selected date', (
    t,
  ) async {
    final end = DateTime(2026, 2, 12, 12);
    await _pump(
      t,
      MetricDetail(
        'hrv',
        day: '2026-02-12',
        data: MetricData(
          daysAvailable: 7,
          series: [
            for (var i = 0; i < 7; i++)
              (
                t:
                    end.subtract(Duration(days: i)).millisecondsSinceEpoch ~/
                    1000,
                v: 60.0 + i,
              ),
          ],
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('7 days'));
    await t.pumpAndSettle();
    final chart = t.widget<ChartFrame>(find.byType(ChartFrame).first);
    expect(chart.xLabels.last, isNot('Today'));
    expect(chart.xLabels.first, isNot(contains('ago')));
  });

  testWidgets('weight chart keeps sub-pound changes before label formatting', (
    t,
  ) async {
    final history = {
      for (var i = 0; i < 2; i++)
        '2026-10-0${7 + i}': WeightReading(
          id: '$i',
          time: DateTime(2026, 10, 7 + i),
          kg: 70 + i * .05,
          source: 'Scale',
          sourceId: 'scale',
        ),
    };
    await _pump(
      t,
      WeightTrendScreen(load: () async => history),
      imperial: true,
    );
    await t.pumpAndSettle();
    final chart = t.widget<ChartFrame>(find.byType(ChartFrame));
    expect(chart.series.last!, greaterThan(chart.series.first!));
    expect(chart.series.last! - chart.series.first!, lessThan(1));
    final scrubber = find.descendant(of: find.byType(ChartFrame), matching: find.byType(Scrubber));
    await t.tap(scrubber);
    await t.pumpAndSettle();
    expect(t.widget<ChartFrame>(find.byType(ChartFrame)).footnote, contains('lb'));
    expect(t.widget<ChartFrame>(find.byType(ChartFrame)).footnote, contains('October'));
  });

  testWidgets(
    'shared controls work with keyboard and static loading is honest',
    (t) async {
      var taps = 0;
      await _pump(
        t,
        Column(
          children: [
            Pressable(onTap: () => taps++, child: const Text('Open')),
            const MotionLoadingIndicator(),
          ],
        ),
      );
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(taps, 1);
      expect(
        t
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        isNotNull,
      );
    },
  );

  testWidgets('legacy briefing never substitutes the current provider', (
    t,
  ) async {
    final config = CoachConfig();
    addTearDown(config.dispose);
    await config.save(
      baseUrl: 'http://127.0.0.1:11434/v1',
      model: 'current-model',
    );
    await _pump(
      t,
      SentPayload(
        inputs: const {'hrv': 62},
        config: config,
        savedBriefing: true,
      ),
    );
    await t.tap(find.byKey(const ValueKey('briefing-payload-toggle')));
    await t.pumpAndSettle();
    expect(find.textContaining('not saved with this briefing'), findsOneWidget);
    expect(find.textContaining('current-model'), findsNothing);
  });

  testWidgets('language choices scroll and expose selection at large text', (t) async {
    final locale = LocaleController.seed('en');
    addTearDown(locale.dispose);
    await _pump(t, const ProfileHomeView(stats: ProfileStats()), locale: locale, scale: 2);
    await t.scrollUntilVisible(find.text('Language'), 200);
    await t.tap(find.text('Language'));
    await t.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    final list = find.descendant(of: sheet, matching: find.byType(ListView));
    expect(list, findsOneWidget);
    final english = t.widgetList<ListTile>(find.descendant(of: sheet, matching: find.byType(ListTile)))
        .firstWhere((w) => (w.title as Text).data == 'English');
    expect(english.selected, isTrue);
    await t.scrollUntilVisible(find.text('हिन्दी'), 100,
        scrollable: find.descendant(of: list, matching: find.byType(Scrollable)).first);
    expect(t.takeException(), isNull);
  });

  test('automatic Home uses a saved reference; explicit past days do not', () async {
    final repo = _SleepRepo();
    expect((await HomeData.load(repo)).sleepReferenceMin.value, 480);
    repo.held = true;
    final held = await HomeData.loadForWakingDay(repo);
    expect(held.dayId, '2026-10-07');
    expect(held.sleepReferenceMin.value, 480);
    expect((await HomeData.loadForDay(repo, '2026-09-30')).sleepReferenceMin.value, isNull);
    (repo.plan['sleep_planning'] as Map)['reference_confidence'] = 0;
    expect((await HomeData.loadForWakingDay(repo)).sleepReferenceMin.value, isNull);
    repo.plan = {};
    expect((await HomeData.loadForWakingDay(repo)).sleepReferenceMin.value, isNull);
  });

  testWidgets(
    'missing nightly target compares known sleep to a labelled baseline',
    (t) async {
      await _pump(
        t,
        const HomeScreen(
          data: HomeData(
            dayId: '2026-10-08',
            sleepMin: Metric(value: 240, confidence: .8),
            sleepReferenceMin: Metric(value: 480, confidence: .7),
            sleepNeedMin: Metric(value: 540),
          ),
        ),
        expressive: true,
      );
      await t.pumpAndSettle();
      final meter =
          t
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) =>
                          w is CustomPaint && w.painter is ExpressiveSleepMeter,
                    ),
                  )
                  .painter!
              as ExpressiveSleepMeter;
      expect(meter.fraction, .5);
      expect(find.text('vs baseline 8h 00m'), findsOneWidget);
      expect(find.text('of 9h 00m'), findsNothing);
    },
  );
}
