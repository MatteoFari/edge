import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _day = '2026-08-12';
Map<String, dynamic> _timeline({String date = _day, int bpm = 88}) => {
  'date': date,
  'day_start': localDayStartSec(date),
  'hr': [
    {'t': localDayStartSec(date)! + 12 * 3600, 'v': bpm},
  ],
};

class _Repo extends LocalRepository {
  bool fail = false;
  Map<String, dynamic> timeline = _timeline();
  Completer<Map<String, dynamic>>? delayed;
  final requested = <String>[];

  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => {};
  @override
  Future<List<String>> availableDays() async => [_day];
  @override
  Future<Map<String, dynamic>> getInsights() async => {};
  @override
  Future<Map<String, dynamic>> getJournalInsights({
    String range = '90d',
  }) async => {};
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) {
    requested.add(date);
    if (fail) throw StateError('read failed');
    final pending = delayed;
    delayed = null;
    return pending?.future ?? Future.value(timeline);
  }
}

Future<AppState> _open(WidgetTester t, _Repo repo, {double scale = 1, bool settle = true}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  await t.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: const MetricDetail('resting_hr', day: _day),
      ),
    ),
  );
  if (settle) {
    await t.pumpAndSettle();
  } else {
    for (var i = 0; i < 5; i++) { await t.pump(); }
  }
  return app;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'recorded HR is accessible even without a nightly resting score',
    (t) async {
      final repo = _Repo();
      await _open(t, repo);
      expect(find.byType(LiveHrCard), findsOneWidget);
      expect(repo.requested, [_day]);
      final chart = find.byKey(const ValueKey('day-hr-scrubber'));
      await t.ensureVisible(chart);
      await t.pumpAndSettle();
      final box = t.getRect(chart);
      await t.tapAt(Offset(box.left + box.width * 720 / 1439, box.center.dy));
      await t.pump();
      expect(
        t.widget<Text>(find.byKey(const ValueKey('day-hr-reading'))).data,
        contains('88 bpm'),
      );
      expect(find.text('What happened'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'a read failure offers retry rather than claiming no recordings',
    (t) async {
      final repo = _Repo()..fail = true;
      await _open(t, repo);
      expect(find.text('Could not read your heart rate'), findsOneWidget);
      repo.fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('day-hr-scrubber')), findsOneWidget);
      expect(find.text('Could not read your heart rate'), findsNothing);
    },
  );

  testWidgets('a held-over curve never takes the selected date', (t) async {
    final repo = _Repo()..timeline = _timeline(date: '2026-08-11');
    await _open(t, repo);
    expect(find.byKey(const ValueKey('day-hr-scrubber')), findsNothing);
    expect(find.text('Wednesday, 12 August, no record'), findsOneWidget);
  });

  testWidgets('an older in-flight read cannot overwrite a newer derive', (
    t,
  ) async {
    final old = Completer<Map<String, dynamic>>();
    final repo = _Repo()..delayed = old;
    final app = await _open(t, repo, settle: false);
    app.insightsRevision.value++;
    await t.pumpAndSettle();
    old.complete(_timeline(bpm: 66));
    await t.pumpAndSettle();
    final scrub = t.widget<Scrubber>(
      find.byKey(const ValueKey('day-hr-scrubber')),
    );
    expect(scrub.describe(720 / 1439), contains('88 bpm'));
    expect(scrub.describe(720 / 1439), isNot(contains('66 bpm')));
  });

  testWidgets('large text keeps the day graph and its controls readable', (
    t,
  ) async {
    await _open(t, _Repo(), scale: 2);
    await t.ensureVisible(find.byKey(const ValueKey('day-hr-expand')));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
