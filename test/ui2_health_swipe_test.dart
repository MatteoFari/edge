import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _tabs = ['Overview', 'Explore', 'Trends', 'Vitals', 'Labs'];
const _fixture = HealthScreen(
  data: HealthData(),
  explore: ExploreData(),
  vitals: VitalsData(),
  labs: LabsData(),
);

Future<void> _pump(
  WidgetTester t, {
  InterfaceStyle style = InterfaceStyle.expressive,
  double scale = 1,
  bool reduceMotion = false,
  TextDirection direction = TextDirection.ltr,
  Widget screen = _fixture,
}) async {
  t.view.physicalSize = const Size(390 * 3, 800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, style: style),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduceMotion,
        ),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: Scaffold(body: screen),
    ),
  );
  await t.pumpAndSettle();
}

int _selected(WidgetTester t) => t.widget<SubTabs>(find.byType(SubTabs)).index;

Future<void> _swipe(WidgetTester t, {bool forward = true}) async {
  await t.drag(find.byType(PageView), Offset(forward ? -300 : 300, 0));
  await t.pumpAndSettle();
}

ScrollPosition _vertical(WidgetTester t, int tab) => t
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(PageStorageKey('health-tab-$tab')),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

class _Repo extends LocalRepository {
  int vitalsReads = 0;

  @override
  Future<Map<String, dynamic>> getToday() async => const {
    'status': {'today_day': '2026-10-05'},
  };

  @override
  Future<List<String>> availableDays() async => const ['2026-10-05'];

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => {
    'date': date,
  };

  @override
  Future<Map<String, dynamic>> getDayLungs(String date) async {
    vitalsReads++;
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {};

  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async => const {};
}

void main() {
  for (final style in InterfaceStyle.values) {
    testWidgets('${style.name}: swipe every Health tab in both directions', (
      t,
    ) async {
      await _pump(t, style: style);
      await _swipe(t, forward: false);
      expect(_selected(t), 0);
      for (var i = 1; i < _tabs.length; i++) {
        await _swipe(t);
        expect(_selected(t), i);
        final viewport = t.getRect(find.byType(SubTabs));
        final selected = t.getRect(find.text(_tabs[i]));
        expect(selected.left, greaterThanOrEqualTo(viewport.left));
        expect(selected.right, lessThanOrEqualTo(viewport.right));
      }
      await _swipe(t);
      expect(_selected(t), 4);
      for (var i = 3; i >= 0; i--) {
        await _swipe(t, forward: false);
        expect(_selected(t), i);
      }
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('chip taps and swipes agree, including reduced motion', (
    t,
  ) async {
    await _pump(t, reduceMotion: true);
    await t.ensureVisible(find.text('Labs'));
    await t.tap(find.text('Labs'));
    await t.pump();
    expect(_selected(t), 4);
    expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 4);
    await _swipe(t, forward: false);
    expect(_selected(t), 3);
    await t.ensureVisible(find.text('Overview'));
    await t.tap(find.text('Overview'));
    await t.pump();
    expect(_selected(t), 0);
    expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets('vertical scrolling and chip-strip drags do not switch tabs', (
    t,
  ) async {
    await _pump(t);
    await t.drag(find.byType(SubTabs), const Offset(-250, 0));
    await t.pumpAndSettle();
    expect(_selected(t), 0);
    await t.drag(
      find.byKey(const PageStorageKey('health-tab-0')),
      const Offset(0, -300),
    );
    await t.pumpAndSettle();
    expect(_selected(t), 0);
    final offset = _vertical(t, 0).pixels;
    expect(offset, greaterThan(0));
    await _swipe(t);
    await _swipe(t, forward: false);
    expect(_vertical(t, 0).pixels, closeTo(offset, .01));
    expect(t.takeException(), isNull);
  });

  testWidgets('swiping loads Vitals only when visited and retains its data', (
    t,
  ) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _Repo();
    app.repo = repo;
    await _pump(
      t,
      screen: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const HealthScreen(
          data: HealthData(),
          explore: ExploreData(),
          labs: LabsData(),
        ),
      ),
    );
    expect(repo.vitalsReads, 0);
    await _swipe(t);
    await _swipe(t);
    expect(repo.vitalsReads, 0);
    await _swipe(t);
    expect(_selected(t), 3);
    expect(repo.vitalsReads, 1);
    await _swipe(t);
    await _swipe(t, forward: false);
    expect(repo.vitalsReads, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('large text keeps the selected tab visible without overflow', (
    t,
  ) async {
    await _pump(t, scale: 3.1);
    for (var i = 1; i < _tabs.length; i++) {
      await _swipe(t);
      final viewport = t.getRect(find.byType(SubTabs));
      final selected = t.getRect(find.text(_tabs[i]));
      expect(selected.left, greaterThanOrEqualTo(viewport.left));
      expect(selected.right, lessThanOrEqualTo(viewport.right));
      expect(t.takeException(), isNull);
    }
  });

  testWidgets('RTL reverses the physical swipe direction', (t) async {
    await _pump(t, direction: TextDirection.rtl);
    await _swipe(t, forward: false);
    expect(_selected(t), 1);
    await _swipe(t);
    expect(_selected(t), 0);
    expect(t.takeException(), isNull);
  });
}
