import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/circadian_detail.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _latest = '2026-10-05', _older = '2026-10-03';

Map<String, dynamic> _night(String day) {
  final d = DateTime.parse(day);
  final onset =
      DateTime(d.year, d.month, d.day - 1, 23).millisecondsSinceEpoch ~/ 1000;
  return {
    'onset_ts': onset,
    'wake_ts': onset + 8 * 3600,
    'duration_min': day == _older ? 360 : 420,
    'in_bed_min': 480,
    'light_min': 200,
    'deep_min': 80,
    'rem_min': 80,
    'hypnogram': [
      {'t': onset, 'stage': 'light'},
      {'t': onset + 3600, 'stage': 'deep'},
      {'t': onset + 7200, 'stage': 'rem'},
    ],
  };
}

class _Repo extends LocalRepository {
  int heartReads = 0;
  bool failBodyClock = false;
  bool stalePlan = false;
  double regularity = 72;
  Completer<void>? holdHeart;
  final readNights = <String>[];

  @override
  Future<Map<String, dynamic>> getToday() async => const {
    'status': {'today_day': _latest},
  };

  @override
  Future<List<String>> availableDays() async => const [_latest, _older];

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    readNights.add(date);
    return _night(date);
  }

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => const {};

  @override
  Future<Map<String, dynamic>> getInsights() async => {
    if (stalePlan) 'sleep_plan_stale': {'kind': 'source_context'},
    'built_at_epoch': DateTime(2026, 10, 6, 9).millisecondsSinceEpoch ~/ 1000,
    'chronotype': {
      'value': {'type_label': 'Evening type'},
    },
    'regularity': {
      'value': {'sri': regularity},
    },
    'sleep_coach': {
      'need': {
        'value': {'need_sec': 28800},
      },
      'nap_credit_min': 20,
    },
    'sleep_debt': {
      'value': {'debt_hours': 1},
    },
  };

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async {
    heartReads++;
    final held = holdHeart;
    holdHeart = null;
    if (held != null) await held.future;
    if (failBodyClock) throw StateError('read failed');
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => const {};

  @override
  Future<List<Map<String, dynamic>>> sleepWindows({
    int days = 60,
    String? before,
  }) async => const [];
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester t,
  AppState app,
  Widget screen, {
  double scale = 1,
  bool reduced = true,
  bool settle = true,
}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, style: InterfaceStyle.expressive),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            disableAnimations: reduced,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  if (settle) {
    await _settle(t);
  } else {
    for (var i = 0; i < 12; i++) {
      await t.pump();
    }
  }
}

ScrollPosition _position(WidgetTester t, String key) => t
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(PageStorageKey(key)),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

void main() {
  late _Repo repo;
  late AppState app;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = _Repo();
    app = AppState.forTesting()..repo = repo;
  });
  tearDown(() => app.dispose());

  testWidgets(
    'Night defaults, Body clock loads lazily, both retain scrolling',
    (t) async {
      await _pump(t, app, const SleepDetail(day: _older));
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 0);
      expect(repo.heartReads, 0);
      await t.drag(
        find.byKey(const PageStorageKey('sleep-night')),
        const Offset(0, -300),
      );
      await _settle(t);
      final night = _position(t, 'sleep-night');
      final nightOffset = night.pixels;
      await t.drag(find.byType(PageView), const Offset(-600, 0));
      await _settle(t);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 1);
      expect(repo.heartReads, greaterThan(0));
      expect(find.text('Sleep, night by night'), findsOneWidget);
      await t.drag(
        find.byKey(const PageStorageKey('sleep-body-clock')),
        const Offset(0, -220),
      );
      await _settle(t);
      final body = _position(t, 'sleep-body-clock');
      final bodyOffset = body.pixels;
      final reads = repo.heartReads;
      await t.tap(find.text('Night'));
      await _settle(t);
      expect(night.pixels, nightOffset);
      night.jumpTo(0);
      await _settle(t);
      expect(t.widget<DayNav>(find.byType(DayNav)).day, _older);
      await t.tap(find.text('Body clock'));
      await _settle(t);
      expect(body.pixels, bodyOffset);
      expect(repo.heartReads, reads);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('Body clock dates its own history, not the selected old night', (
    t,
  ) async {
    await _pump(t, app, const SleepDetail(day: _older));
    await t.tap(find.text('Body clock'));
    await _settle(t);
    expect(
      find.textContaining('not a measurement of the selected night'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Summary updated Tuesday, 6 October'),
      findsOneWidget,
    );
    expect(find.textContaining('Monday, 5 October'), findsWidgets);
    expect(find.textContaining('Today, predicted'), findsNothing);
    await t.tap(find.text('Night'));
    await _settle(t);
    expect(find.text('6h 00m'), findsOneWidget);
    expect(t.widget<DayNav>(find.byType(DayNav)).day, _older);
  });

  testWidgets('old Body clock links open the tab and Back returns to source', (
    t,
  ) async {
    await _pump(
      t,
      app,
      Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(
              MaterialPageRoute<void>(builder: (_) => const CircadianDetail()),
            ),
            child: const Text('Old link'),
          ),
        ),
      ),
    );
    await t.tap(find.text('Old link'));
    await _settle(t);
    expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 1);
    await t.binding.handlePopRoute();
    await _settle(t);
    expect(find.text('Old link'), findsOneWidget);
  });

  testWidgets('failed read stays distinct from insufficient data and retries', (
    t,
  ) async {
    repo.failBodyClock = true;
    await _pump(
      t,
      app,
      const SleepDetail(
        data: SleepData(),
        initialTab: SleepDetailTab.bodyClock,
      ),
    );
    expect(find.textContaining('Could not read'), findsOneWidget);
    expect(find.text('No nights to plot yet'), findsNothing);
    repo.failBodyClock = false;
    await t.tap(find.text('Try again'));
    await _settle(t);
    expect(find.text('Sleep, night by night'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('sync/corrections refresh visited tab; older loads cannot win', (
    t,
  ) async {
    final held = Completer<void>();
    repo.holdHeart = held;
    repo.regularity = 43;
    await _pump(
      t,
      app,
      const SleepDetail(
        data: SleepData(),
        initialTab: SleepDetailTab.bodyClock,
      ),
      settle: false,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repo.regularity = 81;
    app.insightsRevision.value++;
    await _settle(t);
    await t.scrollUntilVisible(
      find.text('81 / 100'),
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('sleep-body-clock')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    held.complete();
    await _settle(t);
    expect(find.text('81 / 100'), findsOneWidget);
    expect(find.text('43 / 100'), findsNothing);
    final before = repo.heartReads;
    await t.tap(find.text('Night'));
    await _settle(t);
    app.insightsRevision.value++;
    await _settle(t);
    expect(repo.heartReads, greaterThan(before));
    expect(t.takeException(), isNull);
  });

  test(
    'missing calendar nights stay blank and timestamps retain local dates',
    () async {
      final d = await CircadianData.load(repo);
      expect(d.labels.length, 42);
      expect(d.labels.last, _latest);
      expect(d.actogram.where((column) => column != null).length, 2);
      expect(d.actogram[d.labels.indexOf('2026-10-04')], isNull);
      expect(d.updatedDay, dayLabelOf(DateTime(2026, 10, 6, 9)));
      expect(d.alertness.value, isNull);
    },
  );

  test('explicit historical nights carry no current recommendation', () async {
    final past = await SleepData.load(repo, want: _older);
    expect(past.showCurrentPlan, isFalse);
    expect(past.need.value, isNull);
    expect(past.debt.value, isNull);
    expect(past.napCreditMin, isNull);
    expect(past.planUpdatedDay, isNull);
    final currentView = await SleepData.load(repo);
    expect(currentView.showCurrentPlan, isTrue);
    expect(currentView.need.value, 480);
    expect(currentView.planUpdatedDay, '2026-10-06');
    final heldView = await SleepData.load(
      repo,
      want: _older,
      includeCurrentPlan: true,
    );
    expect(heldView.day, _older);
    expect(heldView.showCurrentPlan, isTrue);
    expect(heldView.need.value, 480);
    expect(heldView.planUpdatedDay, '2026-10-06');
  });

  testWidgets('held Home keeps the current plan separate from past nights', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    await _pump(
      t,
      app,
      const SleepDetail(day: _latest, includeCurrentPlan: true),
    );
    await t.scrollUntilVisible(
      find.text('Next sleep'),
      500,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('sleep-night')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Next sleep'), findsOneWidget);
    _position(t, 'sleep-night').jumpTo(0);
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    final night = _position(t, 'sleep-night');
    night.jumpTo(night.maxScrollExtent);
    await _settle(t);
    expect(find.text('Next sleep'), findsNothing);
    expect(t.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('outdated plans are distinct from an unestablished need', (
    t,
  ) async {
    repo.stalePlan = true;
    final d = await SleepData.load(repo);
    expect(d.planStale, isTrue);
    expect(d.need.value, isNull);
    expect(d.debt.value, isNull);
    expect(d.napCreditMin, isNull);
    await _pump(t, app, const SleepDetail(data: SleepData(planStale: true)));
    expect(find.text('Sleep plan needs refreshing'), findsOneWidget);
    expect(find.text('Sleep need not established'), findsNothing);
    expect(t.takeException(), isNull);
  });

  for (final scale in [2.0, 3.1]) {
    testWidgets('large text, empty nights and reduced motion at ${scale}x', (
      t,
    ) async {
      await _pump(
        t,
        app,
        const SleepDetail(data: SleepData(), circadianData: CircadianData()),
        scale: scale,
      );
      expect(find.text('No night to show'), findsOneWidget);
      await t.ensureVisible(find.text('Body clock'));
      await t.tap(find.text('Body clock'));
      await _settle(t);
      expect(find.text('No nights to plot yet'), findsOneWidget);
      expect(find.text('Update date unavailable'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('Body clock readings remain usable at ${scale}x text', (
      t,
    ) async {
      await _pump(
        t,
        app,
        const SleepDetail(
          data: SleepData(),
          initialTab: SleepDetailTab.bodyClock,
        ),
        scale: scale,
      );
      await t.scrollUntilVisible(
        find.text('Show'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('sleep-body-clock')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.tap(find.text('Show'));
      await _settle(t);
      expect(find.text('Hide'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('Health Trends no longer contains the large Body clock card', (
    t,
  ) async {
    await _pump(t, app, const Scaffold(body: HealthScreen(data: HealthData())));
    await t.tap(find.text('Trends'));
    await _settle(t);
    expect(find.text('Chronotype, jetlag and regularity'), findsNothing);
    expect(find.byType(CircadianDetail), findsNothing);
    expect(t.takeException(), isNull);
  });
}
