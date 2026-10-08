import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gps/route_models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/activity/setup.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Repo extends LocalRepository {
  final List<Map<String, dynamic>> rows;
  final intervals = <({int from, int until})>[];
  Completer<void>? gate;
  bool fail = false;
  _Repo(this.rows);

  @override
  Future<Map<String, dynamic>> getProfile() async => {'weight_kg': 70.0};
  @override
  Future<Map<String, dynamic>> getInsights() async => {
    'load': {
      'value': {'ctl': 25.0, 'atl': 30.0, 'tsb': -5.0},
    },
  };
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => {'points': []};
  @override
  Future<Map<String, dynamic>> getRecords() async => {
    'workouts_tracked': rows.length,
  };
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async => {
    'workouts': rows
        .where(
          (r) =>
              (r['start_ts'] as int) >=
              DateTime.now()
                      .subtract(const Duration(days: 31))
                      .millisecondsSinceEpoch ~/
                  1000,
        )
        .toList(),
  };
  @override
  Future<Map<String, dynamic>> getWorkoutHistory({
    required int fromTs,
    required int untilTs,
  }) async {
    intervals.add((from: fromTs, until: untilTs));
    if (gate != null) await gate!.future;
    if (fail) throw StateError('History did not answer');
    return {
      'workouts': [
        for (final r in rows)
          if ((r['start_ts'] as int) >= fromTs &&
              (r['start_ts'] as int) < untilTs)
            r,
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getWorkout(String id) async =>
      rows.firstWhere((r) => r['id'] == id);
  @override
  Future<WorkoutRoute?> getWorkoutRoute(String id) async => null;
}

Map<String, dynamic> _session(
  String id,
  DateTime start, {
  String type = 'running',
  bool private = false,
  bool zones = false,
}) => {
  'id': id,
  'type': type,
  'start_ts': start.millisecondsSinceEpoch ~/ 1000,
  'end_ts':
      start.add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
  'duration_min': 30,
  'status': 'done',
  'private': private,
  'strain': zones ? 4.2 : null,
  if (zones) 'zone_min': [10, 10, 10, 0, 0],
};

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await t.pump();
  }
  await t.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester t,
  _Repo repo, {
  double scale = 1,
  InterfaceStyle style = InterfaceStyle.expressive,
}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(
          create: (_) => UnitsController.seed(UnitSystem.metric),
        ),
        ChangeNotifierProvider(
          create: (_) => ThemeController.seed(
            AppThemeChoice.light,
            Brightness.light,
            interfaceStyle: style,
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(
          Brightness.light,
          style: style,
        ).copyWith(platform: TargetPlatform.android),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: const Scaffold(body: WorkoutScreen()),
      ),
    ),
  );
  await _settle(t);
}

Finder _list(int tab) => find.byKey(PageStorageKey('workout-tab-$tab'));
Finder _scroll(int tab) =>
    find.descendant(of: _list(tab), matching: find.byType(Scrollable)).first;

Future<void> _show(WidgetTester t, Finder finder, {int tab = 2}) async {
  await t.scrollUntilVisible(finder, 220, scrollable: _scroll(tab));
  await t.pumpAndSettle();
}

Future<void> _top(WidgetTester t, {int tab = 2}) async {
  t.state<ScrollableState>(_scroll(tab)).position.jumpTo(0);
  await t.pumpAndSettle();
}

Future<void> _tab(WidgetTester t, String label) async {
  await t.ensureVisible(find.text(label));
  await t.tap(find.text(label));
  await _settle(t);
}

Future<void> _history(WidgetTester t) => _tab(t, 'History');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'edge_workout_history_ui_test.db';
    SharedPreferences.setMockInitialValues({'notify_auto_detect': false});
    await Prefs.ensureLoaded();
  });
  setUp(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      path.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    Prefs.setString(Prefs.workoutsRange, 'month');
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      path.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  testWidgets(
    'inline catalogue search retains its query and scroll on detail return',
    (t) async {
      await _pump(t, _Repo([]));
      await _tab(t, 'Activities');
      expect(find.byType(TextField), findsOneWidget);
      await t.enterText(find.byType(TextField), '  walking  ');
      await t.pumpAndSettle();
      expect(find.text('Walking'), findsOneWidget);
      expect(find.text('Running'), findsNothing);
      expect(find.text('QUICK START'), findsNothing);
      final before = t.state<ScrollableState>(_scroll(1)).position.pixels;
      await t.tap(find.text('Walking'));
      await _settle(t);
      expect(find.byType(ActivitySetup), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Back'));
      await _settle(t);
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        '  walking  ',
      );
      expect(t.state<ScrollableState>(_scroll(1)).position.pixels, before);
      await t.enterText(find.byType(TextField), 'zzzz');
      await t.pumpAndSettle();
      expect(find.text('No activity matches that'), findsOneWidget);
      await t.tap(
        find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == 'Clear',
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('QUICK START'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'all-time history and combined filters include old sessions and more than 200 imports',
    (t) async {
      final now = DateTime.now();
      final old = DateTime(now.year - 2, now.month, now.day, 8);
      final repo = _Repo([
        _session('old', old),
        _session(
          'recent',
          DateTime(now.year, now.month, now.day, 7),
          type: 'weight_training',
        ),
      ]);
      await t.runAsync(
        () => LocalDb.putImportedWorkouts([
          for (var i = 0; i < 206; i++)
            {
              'uuid': 'import-$i',
              'start_ts': old.millisecondsSinceEpoch ~/ 1000 + i * 60,
              'end_ts': old.millisecondsSinceEpoch ~/ 1000 + i * 60 + 30,
              'kind': i == 0 ? 'WALKING' : 'RUNNING',
              'source': 'Test recorder',
            },
        ]),
      );
      await _pump(t, repo);
      await _history(t);
      expect(find.text('Sessions in this view: 1'), findsOneWidget);
      await t.tap(find.text('All time'));
      await _settle(t);
      expect(repo.intervals.last.from, 0);
      expect(find.text('Sessions in this view: 208'), findsOneWidget);
      expect(find.textContaining('All stored history through'), findsOneWidget);
      expect(find.text('Weekly load'), findsNothing);
      expect(find.text('2 recorded here · all time'), findsOneWidget);

      await t.tap(find.text('All activities'));
      await t.pumpAndSettle();
      await t.tap(find.text('Walking'));
      await t.pumpAndSettle();
      await t.tap(find.text('Imported'));
      await t.pumpAndSettle();
      expect(find.text('Sessions in this view: 1'), findsOneWidget);
      await _show(
        t,
        find.byKey(const ValueKey('workout-history-imported-import-0')),
      );
      expect(
        find.byKey(ValueKey('workout-date-${dayLabelOf(old)}')),
        findsOneWidget,
      );
      expect(find.textContaining('${old.year}'), findsWidgets);
      expect(find.textContaining('Test recorder ·'), findsOneWidget);

      await _top(t);
      await t.tap(find.text('Recorded here'));
      await t.pumpAndSettle();
      await _show(t, find.text('No sessions match these filters'));
      expect(find.text('No sessions recorded yet'), findsNothing);
      await t.tap(find.text('Reset filters'));
      await _settle(t);
      await _top(t);
      expect(find.text('Sessions in this view: 208'), findsOneWidget);
      await t.tap(find.text('Recorded here'));
      await t.pumpAndSettle();
      await t.tap(find.text('All activities'));
      await t.pumpAndSettle();
      await t.tap(find.text('Running'));
      await t.pumpAndSettle();
      expect(find.text('Sessions in this view: 1'), findsOneWidget);
      await _show(
        t,
        find.byKey(const ValueKey('workout-history-recorded-old')),
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'loading, retryable failure, and empty history keep import and logging reachable',
    (t) async {
      final repo = _Repo([])..gate = Completer<void>();
      await _pump(t, repo);
      await _history(t);
      await _show(t, find.text('Reading your workout history…'));
      expect(find.text('No sessions recorded yet'), findsNothing);
      await _top(t);
      expect(find.textContaining('Import from'), findsOneWidget);
      await _show(t, find.text('Log a past workout'));

      repo.fail = true;
      repo.gate!.complete();
      await _settle(t);
      await _show(t, find.text('Could not read your workout history'));
      expect(find.text('No sessions recorded yet'), findsNothing);
      repo.fail = false;
      await t.tap(find.text('Try again'));
      await _settle(t);
      await _top(t);
      await t.tap(find.text('All time'));
      await _settle(t);
      await _show(t, find.text('No sessions recorded yet'));
      await _top(t);
      expect(find.textContaining('Import from'), findsOneWidget);
      await _show(t, find.text('Log a past workout'));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'history details and swipes retain the selected filters and scroll',
    (t) async {
      final now = DateTime.now();
      final repo = _Repo([
        for (var i = 0; i < 15; i++)
          _session(
            'row-$i',
            DateTime(now.year, now.month, now.day - i, 8),
            zones: true,
            private: true,
          ),
      ]);
      await _pump(t, repo);
      await _history(t);
      await t.tap(find.text('Recorded here'));
      await t.pumpAndSettle();
      final row = find.byKey(const ValueKey('workout-history-recorded-row-5'));
      await _show(t, row);
      final before = t.state<ScrollableState>(_scroll(2)).position.pixels;
      await t.tap(find.descendant(of: row, matching: find.text('Running')));
      await _settle(t);
      expect(find.byType(ActivitySummary), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Back'));
      await _settle(t);
      expect(
        t.state<ScrollableState>(_scroll(2)).position.pixels,
        closeTo(before, .1),
      );
      await t.drag(find.byType(PageView), const Offset(300, 0));
      await t.pumpAndSettle();
      await t.drag(find.byType(PageView), const Offset(-300, 0));
      await t.pumpAndSettle();
      expect(
        t.state<ScrollableState>(_scroll(2)).position.pixels,
        closeTo(before, .1),
      );
      expect(
        find.descendant(of: row, matching: find.text('TIME IN ZONES')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );

  for (final style in InterfaceStyle.values) {
    testWidgets(
      '${style.name}: large text and reduced motion preserve actions and honest missing values',
      (t) async {
        final now = DateTime.now();
        await _pump(
          t,
          _Repo([
            _session('missing', DateTime(now.year, now.month, now.day, 8)),
          ]),
          scale: 3.1,
          style: style,
        );
        await _show(t, find.text('fitness'), tab: 0);
        await _tab(t, 'Activities');
        final running = find.text('Running');
        await _show(t, running, tab: 1);
        final tile = find
            .ancestor(of: running, matching: find.byType(Surface))
            .first;
        expect(t.getSize(tile).width, 390 - S.x4 * 2);
        await _history(t);
        await _show(
          t,
          find.byKey(const ValueKey('workout-history-recorded-missing')),
        );
        expect(find.text('Not costed'), findsOneWidget);
        expect(find.text('No reading'), findsOneWidget);
        expect(find.text('Fix the times'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is Pressable && w.semanticLabel == 'Delete this session',
          ),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      },
    );
  }

  test('history windows end at local midnight across both DST changes', () {
    for (final day in [DateTime(2026, 3, 29, 12), DateTime(2026, 10, 25, 12)]) {
      final window = workoutHistoryWindow('month', day);
      expect(window.until, DateTime(day.year, day.month, day.day + 1));
      expect(
        window.from,
        day.month == 3 ? DateTime(2026, 2, 28) : DateTime(2026, 9, 25),
      );
      expect(window.until.hour, 0);
      if (day.timeZoneName == 'CEST') {
        final midnight = DateTime(day.year, day.month, day.day);
        expect(
          window.until.difference(midnight).inHours,
          day.month == 3 ? 23 : 25,
        );
      }
    }
    expect(
      workoutHistoryWindow('month', DateTime(2026, 3, 31)).from,
      DateTime(2026, 2, 28),
    );
    expect(
      workoutHistoryWindow('year', DateTime(2024, 2, 29)).from,
      DateTime(2023, 2, 28),
    );
  });
}
