import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/screens/calm_breathing.dart';
import 'package:openstrap_edge/ui2/screens/start_card.dart';
import 'package:openstrap_edge/ui2/screens/wellness_screen.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _settle(WidgetTester t, {Finder? until}) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
    if ((until ?? find.byType(StartCard)).evaluate().isNotEmpty) break;
  }
  await t.pumpAndSettle();
}

Future<void> _pump(WidgetTester t, Widget screen, AppState app) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(
          create: (_) => ThemeController.seed(
            AppThemeChoice.light,
            Brightness.light,
            interfaceStyle: InterfaceStyle.expressive,
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(
          Brightness.light,
          style: InterfaceStyle.expressive,
        ).copyWith(platform: TargetPlatform.android),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(body: screen),
      ),
    ),
  );
  await _settle(t);
  expect(find.byType(StartCard), findsOneWidget);
  expect(t.getRect(find.byType(StartCard)).left, S.x4);
  expect(find.byType(Image), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'edge_start_entry_cards_test.db';
    await databaseFactory.deleteDatabase(
      path.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      path.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });
  setUp(() async {
    WellnessScreen.tabRequest.value = -1;
    final db = await LocalDb.instance;
    await db.delete('breathing_session');
  });

  testWidgets('Workout opens the catalogue with its actual activity count', (
    t,
  ) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await _pump(t, const WorkoutScreen(), app);
    expect(find.text('${allActivities.length} activities'), findsOneWidget);
    expect(find.text('Pick one and go'), findsOneWidget);
    await t.tap(find.text('Choose activity'));
    await _settle(t);
    expect(find.byType(ActivityPicker), findsOneWidget);
    expect(
      t.widget<ActivityPicker>(find.byType(ActivityPicker)).recent,
      isEmpty,
    );
    await t.tap(find.bySemanticsLabel('Back'));
    await _settle(t);
    expect(find.byType(StartCard), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Wellness opens breathing and reloads the recorded last sitting', (
    t,
  ) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await _pump(t, const WellnessScreen(), app);
    expect(find.text('${kBreathPatterns.length} exercises'), findsOneWidget);
    expect(find.text('Pick one and go'), findsOneWidget);
    expect(find.textContaining('Last:'), findsNothing);
    await t.tap(find.text('Begin'));
    await _settle(t);
    expect(find.byType(CalmBreathing), findsOneWidget);
    // Record a completed sitting while the entry is off screen. Returning
    // through the card's existing callback must refresh its last-session line.
    await t.runAsync(
      () => LocalDb.putBreathingSession(
        startedAt: DateTime(2026, 10, 8, 9).millisecondsSinceEpoch,
        endedAt: DateTime(2026, 10, 8, 9, 5).millisecondsSinceEpoch,
        pattern: kBreathPatterns.first.key,
        seconds: 300,
      ),
    );
    await t.tap(find.bySemanticsLabel('Close breathing'));
    await _settle(t, until: find.text('Last: 5 min'));
    expect(find.text('Last: 5 min'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an unreadable last duration does not become a zero minute sitting',
    (t) async {
      await t.runAsync(() async {
        final db = await LocalDb.instance;
        await db.insert('breathing_session', {
          'started_at': 1,
          'ended_at': 2,
          'pattern': kBreathPatterns.first.key,
          'seconds': 'unreadable',
        });
      });
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await _pump(t, const WellnessScreen(), app);
      expect(find.text('Pick one and go'), findsOneWidget);
      expect(find.textContaining('Last:'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
