import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/screens/home_metric_preview.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _home = HomeData(
  readiness: Metric(value: 73),
  sleepMin: Metric(value: 431),
  sleepNeedMin: Metric(value: 487),
  strain: Metric(value: 12.4),
  rhr: Metric(value: 51),
  steps: Metric(value: 6234),
  calories: Metric(value: 520),
);

class _Repo extends LocalRepository {
  bool fail = false;
  int loads = 0;
  Completer<Map<String, dynamic>>? nextHeart;
  String? heartDay;
  @override
  Future<int> pendingActivityCount() async => 0;
  @override
  Future<List<String>> availableDays() async {
    final n = DateTime.now();
    return [
      for (var i = 0; i < 10; i++)
        dayLabelOf(DateTime(n.year, n.month, n.day - i)),
    ];
  }

  @override
  Future<Map<String, dynamic>> getToday() async => {
    'status': {'today_day': todayLabel()},
  };
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async {
    if (fail) throw StateError('failed');
    final now = DateTime.now();
    return {
      'points': [
        for (var i = 0; i < 10; i++)
          {
            't':
                DateTime(
                  now.year,
                  now.month,
                  now.day - i,
                  12,
                ).millisecondsSinceEpoch ~/
                1000,
            'v': 73.0 - i,
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async {
    loads++;
    heartDay = date;
    final pending = nextHeart;
    nextHeart = null;
    if (pending != null) return pending.future;
    return {
      'baselines': {
        'hrv': {'value': 72, 'baseline': 66},
        'resting_hr': {'value': 51, 'baseline': 53},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    final now = DateTime.parse(date);
    final start =
        DateTime(now.year, now.month, now.day, 0).millisecondsSinceEpoch ~/
        1000;
    return {
      'onset_ts': start,
      'wake_ts': start + 431 * 60,
      'duration_min': 431,
      'light_min': 221,
      'rem_min': 112,
      'deep_min': 98,
      'awake_min': 18,
      'stages_confidence': .7,
      'hypnogram': [
        {'t': start, 'stage': 'Light'},
        {'t': start + 60, 'stage': 'unobserved'},
        {'t': start + 120, 'stage': 'Deep'},
        {'t': start + 431 * 60, 'stage': 'Awake'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => {};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async {
    final now = DateTime.parse(date);
    final start =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
    return {
      'strain': 12.4,
      'zones': {'z1': 20, 'z2': 15, 'z3': 12, 'z4': 6, 'z5': 1},
      'curve': [
        {'t': start, 'v': 1.0},
        {'t': start + 120, 'v': 2.0},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => {
    'coverage_pct': 80,
  };
}

Widget _frame(AppState app, {double scale = 1, bool reduced = false}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<LocaleController>(
          create: (_) => LocaleController.seed('en'),
        ),
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduced,
          ),
          child: child!,
        ),
        home: const Scaffold(body: HomeScreen(data: _home)),
      ),
    );

Future<(_Repo, AppState)> _pump(
  WidgetTester t, {
  double scale = 1,
  bool reduced = false,
}) async {
  t.view.physicalSize = const Size(390, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final repo = _Repo(), app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  await t.pumpWidget(_frame(app, scale: scale, reduced: reduced));
  await t.pumpAndSettle();
  return (repo, app);
}

void main() {
  for (final kind in HomeRingKind.values) {
    testWidgets(
      '${kind.name} full details expands the whole summary and Back restores it',
      (t) async {
        await _pump(t);
        await t.tap(find.byKey(ValueKey('expressive-${kind.name}')));
        await t.pumpAndSettle();
        final panel = find.byKey(ValueKey('expanded-${kind.name}'));
        final origin = t.getRect(panel);
        await t.tap(find.text('Full details'));
        await t.pump();
        await t.pump();
        await t.pump();
        final morph = find.byKey(const ValueKey('detail-morph-surface'));
        expect(morph, findsOneWidget);
        expect(
          t
              .widget<ClipPath>(morph)
              .clipper!
              .getClip(t.getSize(morph))
              .getBounds(),
          origin,
        );
        await t.pumpAndSettle();
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(panel, findsOneWidget);
        expect(t.getRect(panel), origin);
        expect(find.text('Full details'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }
  for (final kind in HomeRingKind.values) {
    testWidgets(
      '${kind.name} morphs from its card into the same region without moving the alarm',
      (t) async {
        await _pump(t);
        final trio = t.getRect(find.byType(RingTrio));
        final alarm = t.getTopLeft(
          find.byKey(const ValueKey('home-next-alarm')),
        );
        final card = find.byKey(ValueKey('expressive-${kind.name}'));
        final origin = t.getRect(card);
        await t.tap(card);
        await t.pump();
        final panel = find.byKey(ValueKey('expanded-${kind.name}'));
        expect(t.getRect(panel).left, closeTo(origin.left, 1));
        expect(t.getRect(panel).top, closeTo(origin.top, 1));
        await t.pump(const Duration(milliseconds: 70));
        final moving = t.getRect(panel);
        expect(moving.width, greaterThanOrEqualTo(origin.width));
        expect(moving.height, greaterThan(origin.height));
        await t.pumpAndSettle();
        expect(t.getRect(panel).size, trio.size);
        expect(
          t.getTopLeft(find.byKey(const ValueKey('home-next-alarm'))),
          alarm,
        );
        expect(find.text('Full details'), findsOneWidget);
        await t.tap(
          find.byWidgetPredicate(
            (w) => w is Pressable && w.semanticLabel == 'Close summary',
          ),
        );
        await t.pumpAndSettle();
        expect(panel, findsNothing);
        expect(t.getRect(card), origin);
        expect(t.takeException(), isNull, reason: kind.name);
      },
    );
  }
  testWidgets('a vertical Home drag closes the summary while retaining Home', (
    t,
  ) async {
    await _pump(t);
    await t.tap(find.byKey(const ValueKey('expressive-recovery')));
    await t.pumpAndSettle();
    await t.dragFrom(const Offset(15, 600), const Offset(0, -160));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('expanded-recovery')), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'Back reverses an interrupted expansion and allows another metric',
    (t) async {
      await _pump(t);
      await t.tap(find.byKey(const ValueKey('expressive-recovery')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('expanded-recovery')), findsNothing);
      await t.tap(find.byKey(const ValueKey('expressive-strain')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('expanded-strain')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('reduced motion reaches the full region immediately', (t) async {
    await _pump(t, reduced: true);
    final region = t.getSize(find.byType(RingTrio));
    await t.tap(find.byKey(const ValueKey('expressive-sleep')));
    await t.pumpAndSettle();
    expect(t.getSize(find.byKey(const ValueKey('expanded-sleep'))), region);
    expect(t.takeException(), isNull);
  });
  testWidgets('read failures offer Retry instead of an empty chart', (t) async {
    final (repo, _) = await _pump(t);
    repo.fail = true;
    await t.tap(find.byKey(const ValueKey('expressive-recovery')));
    await t.pumpAndSettle();
    expect(find.text('Could not load this summary'), findsOneWidget);
    repo.fail = false;
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(find.text('Last 7 days'), findsOneWidget);
    expect(find.text('Usual 66 ms'), findsOneWidget);
  });
  testWidgets('a stale read cannot overwrite a newer durable revision', (
    t,
  ) async {
    final (repo, app) = await _pump(t);
    final old = Completer<Map<String, dynamic>>();
    repo.nextHeart = old;
    await t.tap(find.byKey(const ValueKey('expressive-recovery')));
    await t.pump();
    await t.pump();
    app.insightsRevision.value++;
    await t.pumpAndSettle();
    expect(find.text('72 ms'), findsOneWidget);
    old.complete({
      'baselines': {
        'hrv': {'value': 9, 'baseline': 9},
      },
    });
    await t.pumpAndSettle();
    expect(find.text('9 ms'), findsNothing);
    expect(find.text('72 ms'), findsOneWidget);
  });
  for (final scale in [2.0, 3.1]) {
    testWidgets('expanded cards keep controls reachable at ${scale}x text', (
      t,
    ) async {
      await _pump(t, scale: scale, reduced: true);
      for (final kind in HomeRingKind.values) {
        final card = find.byKey(ValueKey('expressive-${kind.name}'));
        await t.ensureVisible(card);
        await t.pumpAndSettle();
        await t.tap(card);
        await t.pumpAndSettle();
        expect(find.text('Full details'), findsOneWidget);
        final close = find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == 'Close summary',
        );
        await t.ensureVisible(close);
        await t.pumpAndSettle();
        await t.tap(close);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: kind.name);
      }
    });
  }
  test(
    'recovery history ends on the selected day, with missing days left empty',
    () async {
      final now = DateTime.now();
      final day = dayLabelOf(DateTime(now.year, now.month, now.day - 2));
      final repo = _Repo();
      final data = await HomeMetricPreviewData.load(
        repo,
        HomeRingKind.recovery,
        day,
      );
      expect(data.recovery.length, 7);
      expect(data.recovery.last, 71);
      expect(repo.heartDay, day);
      final values = denseDays(
        [
          (
            t:
                DateTime(
                  now.year,
                  now.month,
                  now.day - 2,
                  12,
                ).millisecondsSinceEpoch ~/
                1000,
            v: 73,
          ),
        ],
        7,
        end: DateTime.parse(day),
      );
      expect(values, [null, null, null, null, null, null, 73]);
    },
  );
  test(
    'sleep summaries retain unobserved gaps and use the full-detail stage ranges',
    () async {
      final repo = _Repo();
      final data = await HomeMetricPreviewData.load(
        repo,
        HomeRingKind.sleep,
        todayLabel(),
      );
      expect(data.sleep!.stages.contains(null), isTrue);
      expect(
        SleepData.stageRuns(data.sleep!.stages).any((r) => r.$1 == null),
        isTrue,
      );
    },
  );
  test('strain grids use actual local day length across DST', () async {
    final repo = _Repo();
    for (final day in ['2026-03-29', '2026-10-25']) {
      final d = DateTime.parse(day),
          next = DateTime.parse(day).copyWith(day: DateTime.parse(day).day + 1);
      final data = await DayStrainData.load(repo, want: day);
      expect(data.curve.length, next.difference(d).inMinutes);
      expect(data.curve[1], isNull);
      expect(data.curve[2], 2);
    }
  });
}
