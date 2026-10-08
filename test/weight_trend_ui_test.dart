import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/weight_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/health/health_weight_import.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/theme/theme_switcher.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/profile/weight_import_settings.dart';
import 'package:openstrap_edge/ui2/screens/weight_trend.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

WeightReading _r(String id, String day, double kg) => WeightReading(
  id: id,
  time: DateTime.parse(day),
  kg: kg,
  source: 'Scale app',
  sourceId: 'scale.app',
);

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  bool imperial = false,
  double scale = 1,
  Future<void> Function()? settleReads,
}) async {
  SharedPreferences.setMockInitialValues({});
  final units = UnitsController.seed(
    imperial ? UnitSystem.imperial : UnitSystem.metric,
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: units),
        ChangeNotifierProvider.value(
          value: ThemeController.seed(
            AppThemeChoice.dark,
            Brightness.dark,
            interfaceStyle: InterfaceStyle.expressive,
          ),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: ThemeReactive(builder: (_) => screen),
      ),
    ),
  );
  if (settleReads != null) await settleReads();
  await tester.pumpAndSettle();
}

class _SettingsBridge implements WeightBridge {
  @override
  Future<WeightAccess> status() async => const WeightAccess(
    available: true,
    weight: true,
    backgroundAvailable: true,
    historyAvailable: true,
  );
  @override
  Future<WeightAccess> request(String kind) => status();
  @override
  Future<void> schedule(bool enabled) async {}
  @override
  Future<Map<dynamic, dynamic>> read({
    String? token,
    bool snapshot = false,
  }) async => {
    'records': [],
    'deleted': [],
    'token': 't',
    'historyGranted': false,
    'snapshotStartMs': 0,
    'snapshotEndMs': DateTime.now().millisecondsSinceEpoch,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final chart in [false, true]) {
    testWidgets(
      '${chart ? 'mounted chart' : 'mounted Explore row'} follows manual saves, removal, restore and deletion',
      (tester) async {
        await tester.runAsync(() async {
          sqfliteFfiInit();
          databaseFactory = databaseFactoryFfi;
          await LocalDb.close();
          final previousName = LocalDb.dbName;
          final temp = await Directory.systemTemp.createTemp(
            'edge_weight_live_ui_',
          );
          LocalDb.dbName = '${temp.path}/weight.db';
          try {
            final db = await LocalDb.instance;
            final store = WeightStore(db);
            await store.apply(
              readings: [_r('r1', '2026-10-07', 71)],
              deleted: [],
              token: 't',
              successfulAt: DateTime(2026, 10, 8),
              historyGranted: false,
            );
            late Future<Map<String, WeightReading>> pending;
            Future<Map<String, WeightReading>> load() =>
                pending = store.byDay(since: DateTime(2026, 10, 1));
            await _pump(
              tester,
              chart
                  ? WeightTrendScreen(load: load)
                  : Scaffold(body: WeightExploreRow(load: load)),
              settleReads: () async {
                await pending;
              },
            );
            expect(find.text('2026-10-07 · Scale app'), findsOneWidget);
            await LocalDb.putJournalMetrics('2026-10-07', {
              'weight_kg': const JournalMetricValue(74),
            });
            await pending;
            await tester.pumpAndSettle();
            expect(find.text('2026-10-07 · Entered by you'), findsOneWidget);
            expect(
              double.parse(
                tester.widget<MetricRow>(find.byType(MetricRow)).value,
              ),
              74,
            );
            await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
            final backup = '${temp.path}/backup.db';
            await File(db.path).copy(backup);
            await LocalDb.putJournalMetrics('2026-10-07', {});
            await pending;
            await tester.pumpAndSettle();
            expect(find.text('2026-10-07 · Scale app'), findsOneWidget);
            expect(
              double.parse(
                tester.widget<MetricRow>(find.byType(MetricRow)).value,
              ),
              71,
            );
            await LocalDb.importFromDbFile(backup);
            await pending;
            await tester.pumpAndSettle();
            expect(find.text('2026-10-07 · Entered by you'), findsOneWidget);
            expect(
              double.parse(
                tester.widget<MetricRow>(find.byType(MetricRow)).value,
              ),
              74,
            );
            await LocalDb.deleteDays({'2026-10-07'});
            await pending;
            await tester.pumpAndSettle();
            expect(find.text('2026-10-07 · Entered by you'), findsNothing);
            expect(find.text('2026-10-07 · Scale app'), findsNothing);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await LocalDb.close();
            LocalDb.dbName = previousName;
            await temp.delete(recursive: true);
          }
        });
      },
    );

    testWidgets(
      '${chart ? 'chart' : 'Explore row'} ignores an older load completing after the current load',
      (tester) async {
        final older = Completer<Map<String, WeightReading>>();
        final newer = Completer<Map<String, WeightReading>>();
        var reads = 0;
        Future<Map<String, WeightReading>> load() => switch (++reads) {
          1 => Future.value({'2026-10-07': _r('one', '2026-10-07', 71)}),
          2 => older.future,
          _ => newer.future,
        };
        await _pump(
          tester,
          chart
              ? WeightTrendScreen(load: load)
              : Scaffold(body: WeightExploreRow(load: load)),
        );
        WeightStore.notifyCommitted();
        await tester.pump();
        WeightStore.notifyCommitted();
        await tester.pump();
        newer.complete({'2026-10-08': _r('current', '2026-10-08', 75)});
        await tester.pumpAndSettle();
        expect(find.text('2026-10-08 · Scale app'), findsOneWidget);
        older.completeError(StateError('old read failed'));
        await tester.pumpAndSettle();
        expect(find.text('2026-10-08 · Scale app'), findsOneWidget);
        expect(
          find.text('Weight history could not be read. Try again.'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('chart errors show retry and do not become an empty history', (
    tester,
  ) async {
    var failed = true;
    await _pump(
      tester,
      WeightTrendScreen(
        load: () async {
          if (failed) throw StateError('db locked');
          return {};
        },
      ),
    );
    expect(
      find.text('Weight history could not be read. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Not enough entries for a trend'), findsNothing);
    failed = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Not enough entries for a trend'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'single reading retains latest date and named source without a trend',
    (tester) async {
      await _pump(
        tester,
        WeightTrendScreen(
          load: () async => {'2026-10-01': _r('r1', '2026-10-01', 71)},
        ),
      );
      expect(find.text('71.0'), findsOneWidget);
      expect(find.text('2026-10-01 · Scale app'), findsOneWidget);
      expect(find.text('Not enough entries for a trend'), findsOneWidget);
    },
  );

  testWidgets('sparse history keeps gaps, uses lbs and supports large text', (
    tester,
  ) async {
    await _pump(
      tester,
      WeightTrendScreen(
        load: () async => {
          '2026-03-28': _r('one', '2026-03-28', 70),
          '2026-03-30': _r('two', '2026-03-30', 71),
        },
      ),
      imperial: true,
      scale: 2,
    );
    final frame = tester.widget<ChartFrame>(find.byType(ChartFrame));
    expect(frame.series, hasLength(3));
    expect(frame.series[1], isNull);
    expect(frame.unit, 'lb');
    expect(find.text('2026-03-30 · Scale app'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual source is labelled and retained with imported chart history',
    (tester) async {
      await _pump(
        tester,
        WeightTrendScreen(
          load: () async => {
            '2026-10-01': WeightReading(
              id: 'manual',
              time: DateTime(2026, 10, 1),
              kg: 71,
              source: '',
              sourceId: 'manual',
              manual: true,
            ),
          },
        ),
      );
      expect(find.text('2026-10-01 · Entered by you'), findsOneWidget);
    },
  );

  testWidgets(
    'Android settings default off, enable access on tap, show optional grants separately',
    (tester) async {
      await tester.runAsync(() async {
        sqfliteFfiInit();
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await WeightStore.create(db);
        final runner = WeightImportRunner(
          bridge: _SettingsBridge(),
          openDb: () async => db,
        );
        await _pump(
          tester,
          Scaffold(
            body: SingleChildScrollView(
              child: WeightImportSettings(runner: runner),
            ),
          ),
          scale: 2,
        );
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse,
        );
        expect(find.text('No successful import yet'), findsOneWidget);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(SwitchListTile));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(find.text('Allow daily background import'), findsOneWidget);
        expect(find.text('Allow older weight history'), findsOneWidget);
        expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue,
        );
        expect(find.textContaining('Last successful import:'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await db.close();
      });
    },
  );
}
