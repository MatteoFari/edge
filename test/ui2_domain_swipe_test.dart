import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _settle(WidgetTester t) async {
  // Database reads answer on the real event loop, outside the test clock.
  for (var i = 0; i < 20; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
  }
  await t.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester t,
  Widget screen,
  AppState app, {
  InterfaceStyle style = InterfaceStyle.expressive,
  double scale = 1,
}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, style: style),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: Scaffold(body: screen),
      ),
    ),
  );
  await _settle(t);
}

Future<void> _swipe(WidgetTester t, bool forward) async {
  await t.drag(find.byType(PageView), Offset(forward ? -300 : 300, 0));
  await _settle(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'edge_domain_swipe_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });
  setUp(() {
    Prefs.setBool('cycle_tracking_enabled', false);
    WellnessScreen.tabRequest.value = -1;
  });
  tearDown(() => WellnessScreen.tabRequest.value = -1);

  for (final style in InterfaceStyle.values) {
    for (final domain in [
      (const WorkoutScreen(), ['For you', 'Activities', 'History']),
      (const WellnessScreen(), ['Mind', 'Recovery', 'Habits', 'Medication']),
      (const NutritionScreen(), ['Today', 'Week', 'Goals']),
    ]) {
      testWidgets('${style.name}: ${domain.$2.first} tabs swipe and tap', (
        t,
      ) async {
        final app = AppState.forTesting();
        addTearDown(app.dispose);
        await _pump(t, domain.$1, app, style: style);
        for (var i = 1; i < domain.$2.length; i++) {
          await _swipe(t, true);
          expect(t.widget<SubTabs>(find.byType(SubTabs)).index, i);
        }
        await _swipe(t, true);
        expect(
          t.widget<SubTabs>(find.byType(SubTabs)).index,
          domain.$2.length - 1,
        );
        for (var i = domain.$2.length - 2; i >= 0; i--) {
          await _swipe(t, false);
          expect(t.widget<SubTabs>(find.byType(SubTabs)).index, i);
        }
        await t.ensureVisible(find.text(domain.$2.last));
        await t.tap(find.text(domain.$2.last));
        await _settle(t);
        expect(
          t.widget<PageView>(find.byType(PageView)).controller!.page,
          domain.$2.length - 1,
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets(
    'Wellness notification links and optional Cycle stay synchronized',
    (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await _pump(t, const WellnessScreen(), app);
      WellnessScreen.tabRequest.value = WellnessScreen.medsTab;
      await _settle(t);
      expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 3);
      await app.setCycleTrackingEnabled(true);
      await _settle(t);
      await _swipe(t, true);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 4);
      await app.setCycleTrackingEnabled(false);
      await _settle(t);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 3);
      expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 3);
      await _swipe(t, false);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 2);
      WellnessScreen.tabRequest.value = -1;
      WellnessScreen.tabRequest.value = WellnessScreen.medsTab;
      await _settle(t);
      expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 3);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final name in ['Running', 'Yoga']) {
    testWidgets('$name summary swipes through its available tabs', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final summary = ActivitySummary(
        ActivityResult(
          activityByName(name)!,
          start: DateTime(2026, 10, 7, 10),
          duration: const Duration(minutes: 30),
        ),
      );
      await _pump(t, summary, app);
      final count = t.widget<SubTabs>(find.byType(SubTabs)).items.length;
      expect(count, name == 'Running' ? 3 : 2);
      for (var i = 1; i < count; i++) {
        await _swipe(t, true);
        expect(t.widget<SubTabs>(find.byType(SubTabs)).index, i);
      }
      await t.tap(find.text('Overview'));
      await _settle(t);
      expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 0);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('large text keeps Wellness tabs visible while swiping', (
    t,
  ) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await _pump(t, const WellnessScreen(), app, scale: 3.1);
    for (var i = 1; i < 4; i++) {
      await _swipe(t, true);
    }
    expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 3);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
