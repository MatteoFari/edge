import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/start_card.dart';
import 'package:openstrap_edge/ui2/screens/wellness_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Repo extends LocalRepository {
  bool fail = false;

  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async {
    if (fail) throw StateError('read failed');
    return {'custom_walk': const JournalMetricValue(1)};
  }

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [
    JournalFieldSpec(
      key: 'custom_walk',
      label: 'Walk',
      kind: JournalFieldKind.rating,
      unit: '',
      max: 1,
      step: 1,
      custom: true,
    ),
    JournalFieldSpec(
      key: 'custom_read',
      label: 'Read',
      kind: JournalFieldKind.rating,
      unit: '',
      max: 1,
      step: 1,
      custom: true,
    ),
  ];

  @override
  Future<Map<String, dynamic>> getJournalInsights({
    String range = '90d',
  }) async {
    if (fail) throw StateError('findings read failed');
    return const {'numeric_insights': []};
  }

  @override
  Future<Map<String, dynamic>> getWeekdayEffect({
    String key = 'readiness',
  }) async => const {};
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
  }
  await t.pumpAndSettle();
}

Future<AppState> _pump(
  WidgetTester t,
  Widget screen,
  _Repo repo, {
  double scale = 1,
}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, style: InterfaceStyle.expressive),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: Scaffold(body: screen),
      ),
    ),
  );
  await _settle(t);
  return app;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'edge_wellness_today_test.db';
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
    await db.delete('med_def');
    await db.delete('med_dose');
  });
  tearDown(() => WellnessScreen.tabRequest.value = -1);

  testWidgets(
    'Today shortcuts select retained tabs and state due versus upcoming',
    (t) async {
      final now = DateTime.now();
      final minute = now.hour * 60 + now.minute;
      await t.runAsync(() async {
        await MedDb.putDef(
          await LocalDb.instance,
          MedDef(
            key: 'vitamins',
            label: 'Vitamins',
            createdAt: now
                .subtract(const Duration(days: 2))
                .millisecondsSinceEpoch,
            schedule: [const MedSchedule(0, []), MedSchedule(1439, [])],
          ),
        );
      });
      await _pump(t, const WellnessScreen(), _Repo());
      expect(t.widget<SubTabs>(find.byType(SubTabs)).items, [
        'Today',
        'Habits',
        'Medication',
      ]);
      expect(find.byType(StartCard), findsOneWidget);
      final habits = find.widgetWithText(ActionCard, 'Habits');
      await t.ensureVisible(habits);
      expect(find.text('1 of 2 completed today'), findsOneWidget);
      expect(
        find.text(
          minute < 1439 ? '1 due now · 1 upcoming' : '2 due now · 0 upcoming',
        ),
        findsOneWidget,
      );
      final todayScroll = t
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const PageStorageKey('wellness-today')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final before = todayScroll.pixels;
      await t.tap(habits);
      await _settle(t);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 1);
      await t.tap(find.text('Today'));
      await _settle(t);
      expect(todayScroll.pixels, before);
      final medication = find.widgetWithText(ActionCard, 'Medication');
      await t.ensureVisible(medication);
      await t.tap(medication);
      await _settle(t);
      expect(
        t.widget<SubTabs>(find.byType(SubTabs)).index,
        WellnessScreen.medsTab,
      );
      expect(WellnessScreen.medsTab, 2);
      expect(find.byType(MedRow), findsNWidgets(2));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed Wellness read offers retry instead of an endless spinner',
    (t) async {
      final repo = _Repo()..fail = true;
      await _pump(t, const WellnessScreen(), repo);
      expect(find.text('Could not load Wellness'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      repo.fail = false;
      await t.tap(find.text('Try again'));
      await _settle(t);
      expect(find.byType(StartCard), findsOneWidget);
      expect(find.text('Could not load Wellness'), findsNothing);
    },
  );

  testWidgets('findings read errors do not claim an empty analysis', (t) async {
    final repo = _Repo()..fail = true;
    await _pump(t, const JournalFindings(), repo);
    expect(find.text('Could not load your findings'), findsOneWidget);
    expect(find.text('Nothing separated itself yet'), findsNothing);
    repo.fail = false;
    await t.tap(find.text('Try again'));
    await _settle(t);
    expect(find.text('Nothing separated itself yet'), findsOneWidget);
  });

  testWidgets(
    'a medication not due today exposes removal without dose actions',
    (t) async {
      final tomorrow = DateTime.now().weekday % 7 + 1;
      await t.runAsync(() async {
        await MedDb.putDef(
          await LocalDb.instance,
          MedDef(
            key: 'vitamin_d',
            label: 'Vitamin D',
            schedule: [
              MedSchedule(480, [tomorrow]),
            ],
          ),
        );
      });
      WellnessScreen.tabRequest.value = WellnessScreen.medsTab;
      await _pump(t, const WellnessScreen(), _Repo(), scale: 3.1);
      await t.ensureVisible(find.bySemanticsLabel('More for Vitamin D'));
      await t.pumpAndSettle();
      await t.tap(find.bySemanticsLabel('More for Vitamin D'));
      await _settle(t);
      expect(find.text('Skipped on purpose'), findsNothing);
      await t.scrollUntilVisible(
        find.text('Remove Vitamin D'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await t.pumpAndSettle();
      expect(find.text('Remove Vitamin D'), findsOneWidget);
      await t.tap(find.text('Remove Vitamin D'));
      await _settle(t);
      await t.ensureVisible(find.text('Remove'));
      await t.pumpAndSettle();
      await t.tap(find.text('Remove'));
      await _settle(t);
      expect(find.text('Nothing scheduled'), findsOneWidget);
      final defs = await t.runAsync(
        () async => MedDb.defs(await LocalDb.instance),
      );
      expect(defs, isEmpty);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'medication schedule is scrollable at large text with reduced motion',
    (t) async {
      await _pump(t, const WellnessScreen(), _Repo(), scale: 3.1);
      final context = t.element(find.byType(WellnessScreen));
      final result = pickMedSchedule(context);
      await t.pumpAndSettle();
      final sheet = t.widget<BottomSheet>(find.byType(BottomSheet));
      expect(sheet.animationController?.duration, Duration.zero);
      await t.scrollUntilVisible(
        find.text('Save'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(await result, isNotNull);
      expect(t.takeException(), isNull);
    },
  );
}
