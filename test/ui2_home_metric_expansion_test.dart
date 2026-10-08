import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  sleepTargetMin: Metric(value: 487),
  strain: Metric(value: 12.4),
  rhr: Metric(value: 51),
  steps: Metric(value: 6234),
  calories: Metric(value: 520),
);

const _experimentalResp = {
  'value': 22.2,
  'experimental': true,
  'label': 'Experimental respiratory rate',
  'chart_key': 'resp_rate_experimental',
};

class _Repo extends LocalRepository {
  bool fail = false;
  int loads = 0;
  Completer<Map<String, dynamic>>? nextHeart;
  String? heartDay;
  final Map<String, Map<String, dynamic>> hearts = {};
  Map<String, dynamic> insights = {
    'sleep_coach': {
      'need': {
        'value': {'need_sec': 540 * 60},
      },
    },
    'sleep_debt': {
      'value': {'debt_hours': 4},
    },
    'sleep_planning': {
      'reference': {'reference_sec': 480 * 60},
      'result': {
        'value': {'shortfall_adjustment_sec': 60 * 60},
      },
    },
  };
  @override
  Future<Map<String, dynamic>> getInsights() async => insights;
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({
    int days = 7,
    String? before,
  }) async => [];
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
    return hearts[date] ??
        {
          'baselines': {
            'hrv': {'value': 72, 'baseline': 66},
            'resting_hr': {'value': 51, 'baseline': 53},
            'resp': {'value': 14.3, 'baseline': 14.6},
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
  testWidgets(
    'compact Sleep shows readable plan values in both themes and large text',
    (t) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const data = HomeMetricPreviewData(
        day: '2026-10-08',
        sleep: SleepData(
          baselineMin: 480,
          extraSleepMin: 60,
          need: Metric(value: 540),
          debt: Metric(value: 240),
        ),
      );
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 3.1]) {
          await t.pumpWidget(
            MaterialApp(
              theme: buildTheme(brightness, style: InterfaceStyle.expressive),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('en'),
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(S.x4),
                    child: Builder(
                      builder: (c) =>
                          buildHomeMetricPreview(c, data, HomeRingKind.sleep),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          for (final label in [
            'Baseline sleep estimate',
            'Recent sleep shortfall',
            'Extra sleep recommended',
            'Next sleep recommendation',
          ]) {
            final finder = find.text(label);
            expect(finder, findsOneWidget);
            expect(t.widget<Text>(finder).maxLines, isNull);
          }
          for (final value in ['8h 00m', '4h 00m', '1h 00m', '9h 00m']) {
            expect(find.text(value), findsOneWidget);
          }
          expect(t.takeException(), isNull);
        }
      }
    },
  );
  test(
    'compact Sleep loads the same plan and hides it on explicit historical nights',
    () async {
      final repo = _Repo();
      final today = todayLabel();
      final date = DateTime.parse(today);
      final previous = dayLabelOf(
        DateTime(date.year, date.month, date.day - 1),
      );
      var data = await HomeMetricPreviewData.load(
        repo,
        HomeRingKind.sleep,
        today,
      );
      expect(data.sleep!.need.value, 540);
      expect(data.sleep!.debt.value, 240);
      data = await HomeMetricPreviewData.load(
        repo,
        HomeRingKind.sleep,
        previous,
      );
      expect(data.sleep!.showCurrentPlan, false);
      expect(data.sleep!.need.value, isNull);
      data = await HomeMetricPreviewData.load(
        repo,
        HomeRingKind.sleep,
        previous,
        includeCurrentPlan: true,
      );
      expect(data.sleep!.need.value, 540);
      repo.insights = {
        'sleep_plan_stale': {'kind': 'plan_context'},
      };
      data = await HomeMetricPreviewData.load(repo, HomeRingKind.sleep, today);
      expect(data.sleep!.planStale, true);
      expect(data.sleep!.need.value, isNull);
    },
  );
  setUpAll(() async {
    // Match the phone's bundled font advances when checking clipped readings.
    for (final family in ['.SF Pro Text', 'Manrope']) {
      final loader = FontLoader(family);
      for (final weight in [400, 500, 600, 700]) {
        loader.addFont(
          rootBundle.load('assets/fonts/Manrope/Manrope-$weight.ttf'),
        );
      }
      await loader.load();
    }
  });
  for (final full in [false, true]) {
    testWidgets(
      '${full ? 'full' : 'expanded'} Strain keeps all five coloured zones on one row',
      (t) async {
        t.view.physicalSize = const Size(360, 1200);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final semantics = t.ensureSemantics();
        const data = DayStrainData(
          curve: [0, 4, 8, 12],
          strain: 12,
          zoneMin: [1200, 120, 80, 36, 4],
        );
        try {
          for (final brightness in Brightness.values) {
            for (final scale in [1.0, 1.3, 3.1]) {
              await t.pumpWidget(
                MaterialApp(
                  theme: buildTheme(
                    brightness,
                    style: InterfaceStyle.expressive,
                  ),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  locale: const Locale('en'),
                  builder: (c, child) => MediaQuery(
                    data: MediaQuery.of(c).copyWith(
                      textScaler: TextScaler.linear(scale),
                      disableAnimations: true,
                    ),
                    child: child!,
                  ),
                  home: full
                      ? const DayStrainDetail(data: data)
                      : Scaffold(
                          body: Padding(
                            padding: const EdgeInsets.all(S.x4),
                            child: SingleChildScrollView(
                              child: Builder(
                                builder: (c) => buildHomeMetricPreview(
                                  c,
                                  const HomeMetricPreviewData(
                                    day: '2026-10-08',
                                    strain: data,
                                  ),
                                  HomeRingKind.strain,
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              );
              await t.pumpAndSettle();
              final row = find.byType(ZoneMinutesRow);
              if (full) {
                await t.scrollUntilVisible(
                  row,
                  300,
                  scrollable: find.byType(Scrollable).first,
                );
              } else {
                await t.ensureVisible(row);
              }
              await t.pumpAndSettle();
              final p = P.of(t.element(row));
              final top = t.getTopLeft(find.text('Z1')).dy;
              for (var i = 0; i < 5; i++) {
                final label = find.text('Z${i + 1}');
                expect(t.getTopLeft(label).dy, top);
                final circle = t.widget<Container>(
                  find
                      .ancestor(of: label, matching: find.byType(Container))
                      .first,
                );
                final decoration = circle.decoration! as BoxDecoration;
                expect(decoration.shape, BoxShape.circle);
                expect(decoration.border!.top.color, ZoneBar.cols(p)[i]);
                expect(
                  find.bySemanticsLabel('Z${i + 1}, ${data.zoneMin![i]} min'),
                  findsOneWidget,
                );
              }
              final scroll = t.state<ScrollableState>(
                find.descendant(of: row, matching: find.byType(Scrollable)),
              );
              final bounds = t.getRect(row);
              if (scale <= 1.3) {
                expect(scroll.position.maxScrollExtent, 0);
                expect(
                  t.getRect(find.text('Z5')).right,
                  lessThanOrEqualTo(bounds.right),
                );
                expect(
                  t.getRect(find.text('4 min')).right,
                  lessThanOrEqualTo(bounds.right),
                );
              } else {
                expect(scroll.position.maxScrollExtent, greaterThan(0));
                await t.drag(row, const Offset(-1000, 0));
                await t.pumpAndSettle();
                expect(
                  t.getRect(find.text('Z5')).right,
                  lessThanOrEqualTo(bounds.right),
                );
                expect(
                  t.getRect(find.text('Z5')).left,
                  greaterThanOrEqualTo(bounds.left),
                );
              }
              expect(
                t.takeException(),
                isNull,
                reason: '$full, $brightness, $scale',
              );
            }
          }
        } finally {
          semantics.dispose();
        }
      },
    );
  }
  testWidgets('missing zone readings do not become zero minutes', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => buildHomeMetricPreview(
              c,
              const HomeMetricPreviewData(day: '2026-10-08'),
              HomeRingKind.strain,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ZoneMinutesRow), findsNothing);
    expect(find.text('0 min'), findsNothing);
    await t.pumpWidget(
      const MaterialApp(home: DayStrainDetail(data: DayStrainData())),
    );
    expect(find.byType(ZoneMinutesRow), findsNothing);
    expect(find.text('0 min'), findsNothing);
    expect(t.takeException(), isNull);
  });
  for (final (scale, height) in [(1.0, 210.0), (1.3, 194.0)]) {
    for (final history in [false, true]) {
      testWidgets(
        'bounded Recovery keeps every reading visible at ${scale}x with history=$history',
        (t) async {
          t.view.physicalSize = const Size(390, 1000);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          final data = HomeMetricPreviewData(
            day: '2026-10-07',
            recovery: history
                ? const [null, null, 61, 70, 64, null, 72]
                : const [],
            baselines: const {
              'hrv': {'value': 113, 'baseline': 113},
              'resting_hr': {'value': 45, 'baseline': 50},
              'resp': {'value': null, 'baseline': 14.6},
            },
            resp: {..._experimentalResp, 'value': 12.0},
          );
          await t.pumpWidget(
            MaterialApp(
              theme: buildTheme(
                Brightness.light,
                style: InterfaceStyle.expressive,
              ),
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(
                  c,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    key: const ValueKey('bounded-recovery-preview'),
                    width: 324,
                    height: height,
                    child: ClipRect(
                      child: Builder(
                        builder: (c) => buildHomeMetricPreview(
                          c,
                          data,
                          HomeRingKind.recovery,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          final bounds = t.getRect(
            find.byKey(const ValueKey('bounded-recovery-preview')),
          );
          for (final text in [
            'HRV',
            '113 ms',
            'Usual 113 ms',
            'Resting heart rate',
            '45 bpm',
            'Usual 50 bpm',
            'Breathing rate',
            '12.0 br/min',
          ]) {
            final reading = t.getRect(find.text(text));
            expect(
              reading.left,
              greaterThanOrEqualTo(bounds.left),
              reason: text,
            );
            expect(
              reading.right,
              lessThanOrEqualTo(bounds.right),
              reason: text,
            );
            expect(reading.top, greaterThanOrEqualTo(bounds.top), reason: text);
            expect(
              reading.bottom,
              lessThanOrEqualTo(bounds.bottom),
              reason: text,
            );
          }
          expect(find.text('Experimental respiratory rate'), findsNothing);
          expect(find.text('Usual 14.6 br/min'), findsNothing);
          expect(find.byType(ChartFrame), findsOneWidget);
          if (history || scale > 1) {
            expect(
              t.widget<ChartFrame>(find.byType(ChartFrame)).height,
              lessThan(S.x16 + S.x6),
            );
          }
          expect(t.widget<Text>(find.text('12.0 br/min')).style!.fontSize, 17);
          expect(t.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('Recovery includes overnight breathing rate and its own usual', (
    t,
  ) async {
    await _pump(t);
    await t.tap(find.byKey(const ValueKey('expressive-recovery')));
    await t.pumpAndSettle();
    final panel = find.byKey(const ValueKey('expanded-recovery'));
    Finder inPanel(String text) =>
        find.descendant(of: panel, matching: find.text(text));
    expect(inPanel('72 ms'), findsOneWidget);
    expect(inPanel('51 bpm'), findsOneWidget);
    expect(inPanel('Breathing rate'), findsOneWidget);
    expect(inPanel('14.3 br/min'), findsOneWidget);
    expect(inPanel('Usual 14.6 br/min'), findsOneWidget);
    expect(inPanel('Full details'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('a measured first night has no fabricated breathing baseline', (
    t,
  ) async {
    final (repo, _) = await _pump(t);
    repo.hearts[todayLabel()] = {
      'baselines': {
        'resp': {'value': 14.3, 'baseline': null, 'status': 'calibrating'},
      },
    };
    await t.tap(find.byKey(const ValueKey('expressive-recovery')));
    await t.pumpAndSettle();
    expect(find.text('14.3 br/min'), findsOneWidget);
    expect(find.textContaining('Usual'), findsNothing);
    expect(t.takeException(), isNull);
  });
  for (final value in [null, double.nan, double.infinity]) {
    testWidgets(
      'a marked experiment is measured when canonical $value is absent',
      (t) async {
        final (repo, _) = await _pump(t);
        repo.hearts[todayLabel()] = {
          'baselines': {
            'resp': {'value': value, 'baseline': 14.6},
          },
          'resp': _experimentalResp,
          'avg_hr': 68,
        };
        await t.tap(find.byKey(const ValueKey('expressive-recovery')));
        await t.pumpAndSettle();
        expect(find.text('Breathing rate'), findsOneWidget);
        expect(find.text('Experimental respiratory rate'), findsNothing);
        expect(find.text('22.2 br/min'), findsOneWidget);
        expect(find.textContaining('Usual'), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
    testWidgets(
      'absent or invalid experimental breathing $value stays absent',
      (t) async {
        final (repo, _) = await _pump(t);
        repo.hearts[todayLabel()] = {
          'baselines': {
            'resp': {'value': 14.3, 'baseline': 14.6},
          },
          'resp': {..._experimentalResp, 'value': value},
          'avg_hr': 68,
        };
        await t.tap(find.byKey(const ValueKey('expressive-recovery')));
        await t.pumpAndSettle();
        expect(find.text('Breathing rate'), findsNothing);
        expect(find.text('Experimental respiratory rate'), findsNothing);
        expect(find.textContaining('br/min'), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'the selected experiment never shows a different canonical reading',
    (t) async {
      final (repo, _) = await _pump(t);
      repo.hearts[todayLabel()] = {
        'baselines': {
          'resp': {'value': 14.3, 'baseline': 14.6},
        },
        'resp': _experimentalResp,
      };
      await t.tap(find.byKey(const ValueKey('expressive-recovery')));
      await t.pumpAndSettle();
      expect(find.text('Breathing rate'), findsOneWidget);
      expect(find.text('Experimental respiratory rate'), findsNothing);
      expect(find.text('Usual 14.6 br/min'), findsNothing);
      expect(find.text('14.3 br/min'), findsNothing);
      expect(find.text('22.2 br/min'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
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
      final (repo, _) = await _pump(t, scale: scale, reduced: true);
      repo.hearts[todayLabel()] = {
        'baselines': {
          'hrv': {'value': 72, 'baseline': 66},
          'resting_hr': {'value': 51, 'baseline': 53},
          'resp': {'value': 14.3, 'baseline': 14.6},
        },
        'resp': _experimentalResp,
      };
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
      repo.hearts[day] = {
        'baselines': {
          'resp': {'value': 13.2, 'baseline': 13.5},
        },
        'resp': {..._experimentalResp, 'value': 12.0},
      };
      final data = await HomeMetricPreviewData.load(
        repo,
        HomeRingKind.recovery,
        day,
      );
      expect(data.recovery.length, 7);
      expect(data.recovery.last, 71);
      expect(repo.heartDay, day);
      expect(data.baselines['resp'], {'value': 13.2, 'baseline': 13.5});
      expect(data.resp, {..._experimentalResp, 'value': 12.0});
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
