import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

String _day(int back) {
  final now = DateTime.now();
  return dayLabelOf(DateTime(now.year, now.month, now.day - back));
}

class _Repo extends LocalRepository {
  String? sleepDay = _day(1);
  final reads = <String>[];

  @override
  Future<Map<String, dynamic>> getToday() async => {
    'status': {
      'today_day': _day(0),
      'last_sleep_day': sleepDay,
      'overnight_state': sleepDay == _day(0) ? 'ready' : 'building',
    },
    'daily': {
      'readiness': {'value': 70},
      'strain': {'value': 1},
      'steps': {'value': 100},
    },
    'sleep': {
      'duration_min': {'value': 400},
    },
  };
  @override
  Future<Map<String, dynamic>> getProfile() async => {};
  @override
  Future<Map<String, dynamic>> getInsights() async => {};
  @override
  Future<List<String>> availableDays() async => [_day(0), _day(1), _day(2)];
  @override
  Future<int> pendingActivityCount() async => 0;
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async => {};
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async {
    reads.add(date);
    return {'readiness': 42, 'resting_hr': 60};
  }

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => {
    'strain': 13.4,
    'steps': 10000,
    'calories': 750,
  };
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {
    'duration_min': 459,
  };
}

Widget _frame(AppState app, {Widget? child}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<AppState>.value(value: app),
    ChangeNotifierProvider<ThemeController>(
      create: (_) => ThemeController.seed(
        AppThemeChoice.light,
        Brightness.light,
        interfaceStyle: InterfaceStyle.expressive,
      ),
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, style: InterfaceStyle.expressive),
    home: Scaffold(body: child ?? const HomeScreen()),
  ),
);

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = inMemoryDatabasePath;
  });
  tearDown(LocalDb.close);

  test(
    'midnight keeps the whole dated day; completed sleep advances it',
    () async {
      final repo = _Repo();
      final before = await HomeData.loadForWakingDay(repo);
      expect(before.dayId, _day(1));
      expect(before.readiness.value, 42);
      expect(before.sleepMin.value, 459);
      expect(before.strain.value, 13.4);
      expect(before.steps.value, 10000);
      // The calendar read is still current, including for explicit date picks.
      expect((await HomeData.load(repo)).dayId, _day(0));

      repo.sleepDay = _day(0);
      final after = await HomeData.loadForWakingDay(repo);
      expect(after.dayId, _day(0));
      expect(after.readiness.value, 70);
      expect(after.steps.value, 100);
    },
  );

  test('no previous sleep keeps the current honest first-run view', () async {
    final repo = _Repo()..sleepDay = null;
    expect((await HomeData.loadForWakingDay(repo)).dayId, _day(0));
    expect(repo.reads, isEmpty);
  });

  test('a future sleep date cannot select a future Home day', () async {
    final repo = _Repo()..sleepDay = _day(-1);
    expect((await HomeData.loadForWakingDay(repo)).dayId, _day(0));
    expect(repo.reads, isEmpty);
  });

  test('calibration counts survive the dated-day read', () async {
    await LocalDb.putDayResult(
      dayId: _day(1),
      algoVersion: kAlgoVersion,
      windowJson: '{}',
      payloadJson: jsonEncode({
        'readiness_absent_diag': {'note': 'need_baseline:have=9,need=14'},
      }),
    );
    // An absent historical score must retain the measured baseline progress.
    final d = await HomeData.loadForDay(_AbsentRepo(), _day(1));
    expect(d.readiness.value, isNull);
    expect(d.readiness.note, 'need_baseline:have=9,need=14');
    final full = await ReadinessData.load(_AbsentRepo(), want: _day(1));
    expect(full.readiness.note, d.readiness.note);
  });

  test(
    'continuing the dated day retains its frozen morning headline',
    () async {
      await LocalDb.putDayResult(
        dayId: _day(1),
        algoVersion: kAlgoVersion,
        windowJson: '{}',
        payloadJson: jsonEncode({
          'scalars': {'readiness': 42},
        }),
      );
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      await LocalDb.setFrozenHeadline(_day(1), 65);
      expect((await repo.getDayOverview(_day(1)))['readiness'], 65);
      await LocalDb.setFrozenHeadline(_day(0), 70);
      expect((await repo.getDayOverview(_day(1)))['readiness'], 42);
    },
  );

  testWidgets('Home keeps its alarm and opens the displayed day', (t) async {
    final app = AppState.forTesting()..repo = _Repo();
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(app));
    await _settle(t);
    expect(t.widget<RingTrio>(find.byType(RingTrio)).day, _day(1));
    expect(find.text('42'), findsOneWidget);
    expect(find.text('Set an alarm'), findsOneWidget);
    expect(find.text('Breakdown of your day'), findsNothing);
    final link = find.text('Heart rate');
    await t.scrollUntilVisible(
      link,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // Apply ensureVisible's scroll jump before reading the text's tap position.
    await t.pump();
    expect(link.hitTestable(), findsOneWidget);
    await t.tap(link);
    await _settle(t);
    expect(
      t.widget<MetricDetail>(find.byType(MetricDetail)).day,
      _day(1),
    );
  });

  testWidgets('new sleep refreshes Home without restarting the app', (t) async {
    final repo = _Repo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(app));
    await _settle(t);
    expect(find.text('42'), findsOneWidget);
    repo.sleepDay = _day(0);
    app.insightsRevision.value++;
    await _settle(t);
    expect(find.text('42'), findsNothing);
    expect(find.text('70'), findsOneWidget);
  });

  testWidgets('dated metric window and labels exclude the next day', (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    int noon(String day) {
      final d = DateTime.parse(day);
      return DateTime(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/
          1000;
    }

    await t.pumpWidget(
      _frame(
        app,
        child: MetricDetail(
          'calories',
          day: _day(1),
          data: MetricData(
            daysAvailable: 2,
            series: [(t: noon(_day(1)), v: 750.0), (t: noon(_day(0)), v: 20.0)],
          ),
        ),
      ),
    );
    await _settle(t);
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && w.data == '750' && w.style?.fontSize == 48,
      ),
      findsOneWidget,
    );
    expect(find.text('Today'), findsNothing);
    expect(t.takeException(), isNull);
  });

  test('dated chart boundaries count local calendar days across DST', () {
    for (final end in [DateTime(2026, 3, 30), DateTime(2026, 10, 26)]) {
      final before = DateTime(end.year, end.month, end.day - 1, 12);
      expect(daysBehind(before.millisecondsSinceEpoch ~/ 1000, end: end), 1);
    }
  });
}

class _AbsentRepo extends _Repo {
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async => {};
}
