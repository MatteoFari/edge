import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/weight_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

WeightReading reading(
  String id,
  DateTime time,
  double kg, {
  bool manual = false,
}) => WeightReading(
  id: id,
  time: time,
  kg: kg,
  source: 'Scale app',
  sourceId: 'scale.app',
  manual: manual,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Database db;
  late WeightStore store;
  late String previousName;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    previousName = LocalDb.dbName;
    temp = await Directory.systemTemp.createTemp('edge_weight_test_');
    LocalDb.dbName = p.join(temp.path, 'weight.db');
    db = await LocalDb.instance;
    store = WeightStore(db);
  });
  tearDown(() async {
    await LocalDb.close();
    LocalDb.dbName = previousName;
    await temp.delete(recursive: true);
  });

  Future<void> save(
    List<WeightReading> rows, {
    List<String> deleted = const [],
    String token = 'next',
    int? from,
    int? to,
    bool Function()? canWrite,
  }) => store.apply(
    readings: rows,
    deleted: deleted,
    token: token,
    successfulAt: DateTime(2026, 10, 8),
    historyGranted: false,
    snapshotStartMs: from,
    snapshotEndMs: to,
    canWrite: canWrite,
  );

  test(
    'committed weight writes publish once; failures and unrelated journal edits do not',
    () async {
      var notifications = 0;
      void changed() => notifications++;
      WeightStore.changes.addListener(changed);
      try {
        await LocalDb.putJournalMetrics('2026-10-07', {
          'mood': const JournalMetricValue(4),
        });
        expect(notifications, 0);
        await LocalDb.putJournalMetrics('2026-10-07', {
          'weight_kg': const JournalMetricValue(74),
        });
        expect(notifications, 1);
        await LocalDb.putJournalMetrics('2026-10-07', {
          'weight_kg': const JournalMetricValue(74),
          'mood': const JournalMetricValue(3),
        });
        expect(notifications, 1);
        await LocalDb.putJournalMetrics('2026-10-07', {});
        expect(notifications, 2);
        await save([reading('r1', DateTime(2026, 10, 7), 71)]);
        expect(notifications, 3);
        await expectLater(
          save([
            reading('r2', DateTime(2026, 10, 8), 72),
          ], canWrite: () => false),
          throwsStateError,
        );
        expect(notifications, 3);
        await LocalDb.deleteDays({'2026-10-07'});
        expect(notifications, 4);
        await LocalDb.wipeAll();
        expect(notifications, 5);
      } finally {
        WeightStore.changes.removeListener(changed);
      }
    },
  );

  test(
    'latest reading retains source/date when older than the chart window',
    () async {
      await save([reading('old', DateTime(2025, 1, 1), 71)]);
      expect(await store.byDay(since: DateTime(2026, 10, 1)), isEmpty);
      expect((await store.latest())!.day, '2025-01-01');
      expect((await store.latest())!.source, 'Scale app');
      await LocalDb.putJournalMetrics('2025-01-01', {
        'weight_kg': const JournalMetricValue(74),
      });
      expect((await store.latest())!.manual, isTrue);
    },
  );

  test(
    'fresh and same-version repaired schema preserve the weight ledger',
    () async {
      final tables = await LocalDb.tableNames();
      expect(tables, containsAll(['imported_weight', 'weight_import_sync']));
      await save([reading('r1', DateTime(2026, 10, 7), 71)]);
      await db.execute('DROP TABLE weight_import_sync');
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(await db.query('imported_weight'), hasLength(1));
      expect(await db.query('weight_import_sync'), isEmpty);
      expect(LocalDb.lastRebuild, isNull);
    },
  );

  test(
    'schema 59 upgrades additively without rewriting manual entries',
    () async {
      await LocalDb.putJournalMetrics('2026-10-07', {
        'weight_kg': const JournalMetricValue(74),
      });
      await db.execute('DROP TABLE imported_weight');
      await db.execute('DROP TABLE weight_import_sync');
      await db.execute('PRAGMA user_version = 59');
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(await db.getVersion(), LocalDb.schemaVersion);
      expect(await db.query('imported_weight'), isEmpty);
      expect(
        (await LocalDb.journalMetricsForDay('2026-10-07'))['weight_kg']!.value,
        74,
      );
      expect(LocalDb.lastRebuild, isNull);
    },
  );

  test(
    'duplicate IDs replace, edits update, source deletions remove only imported rows',
    () async {
      final at = DateTime(2026, 10, 7, 8);
      await LocalDb.putJournalMetrics('2026-10-07', {
        'weight_kg': const JournalMetricValue(75),
      });
      await save([reading('r1', at, 71), reading('r2', at, 72)]);
      await save([reading('r1', at, 73)]);
      expect(await db.query('imported_weight'), hasLength(2));
      expect(
        (await db.query(
          'imported_weight',
          where: 'record_id = ?',
          whereArgs: ['r1'],
        )).single['kg'],
        73,
      );
      await save([], deleted: ['r1'], token: 'deleted');
      expect((await db.query('imported_weight')).single['record_id'], 'r2');
      expect(
        (await LocalDb.journalMetricsForDay('2026-10-07'))['weight_kg']!.value,
        75,
      );
      expect((await store.syncState())!['token'], 'deleted');
    },
  );

  test('failed transaction rolls back records and token together', () async {
    await save([reading('old', DateTime(2026, 10, 7), 71)], token: 'old-token');
    var calls = 0;
    await expectLater(
      save(
        [reading('new', DateTime(2026, 10, 8), 72)],
        token: 'new-token',
        canWrite: () => ++calls == 1,
      ),
      throwsStateError,
    );
    expect((await db.query('imported_weight')).single['record_id'], 'old');
    expect((await store.syncState())!['token'], 'old-token');
  });

  test('complete snapshot reconciles only its readable window', () async {
    final old = DateTime(2026, 8, 1).millisecondsSinceEpoch;
    final start = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    final end = DateTime(2026, 10, 8).millisecondsSinceEpoch;
    await save([
      reading('inaccessible', DateTime.fromMillisecondsSinceEpoch(old), 70),
      reading('deleted', DateTime(2026, 10, 7), 71),
    ]);
    await save(
      [reading('current', DateTime(2026, 10, 6), 72)],
      from: start,
      to: end,
    );
    expect(
      (await db.query('imported_weight')).map((r) => r['record_id']),
      unorderedEquals(['inaccessible', 'current']),
    );
  });

  test(
    'daily selection uses latest valid imported reading and manual priority',
    () async {
      await save([
        reading('morning', DateTime(2026, 10, 7, 7), 71),
        reading('evening', DateTime(2026, 10, 7, 20), 72),
        reading('next', DateTime(2026, 10, 8), 73),
      ]);
      var days = await store.byDay(since: DateTime(2026, 10, 1));
      expect(days['2026-10-07']!.id, 'evening');
      await LocalDb.putJournalMetrics('2026-10-07', {
        'weight_kg': const JournalMetricValue(74),
      });
      days = await store.byDay(since: DateTime(2026, 10, 1));
      expect(days['2026-10-07']!.kg, 74);
      expect(days['2026-10-07']!.manual, isTrue);
      expect(await db.query('imported_weight'), hasLength(3));
      expect(days.keys, ['2026-10-07', '2026-10-08']);
    },
  );

  test(
    'midnight and DST grouping follow local date rather than elapsed 24 hours',
    () {
      final rows = weightReadingsByDay([
        reading('before', DateTime(2026, 3, 28, 23, 59), 70),
        reading('after', DateTime(2026, 3, 29), 71),
        reading('later', DateTime(2026, 3, 29, 23, 59), 72),
        reading('fall', DateTime(2026, 10, 25, 2, 30), 73),
      ], []);
      expect(rows.keys, ['2026-03-28', '2026-03-29', '2026-10-25']);
      expect(rows['2026-03-29']!.id, 'later');
      final utc = DateTime.utc(2026, 3, 29, 23, 30);
      expect(reading('utc', utc, 71).day, dayLabelOf(utc.toLocal()));
    },
  );

  test('invalid or unattributed records abstain', () {
    final row = reading('r', DateTime(2026, 10, 7), 71).toRow();
    for (final kg in [double.nan, double.infinity, 0, -1]) {
      expect(WeightReading.fromRow({...row, 'kg': kg}), isNull);
    }
    expect(WeightReading.fromRow({...row, 'record_id': ''}), isNull);
    expect(WeightReading.fromRow({...row, 'source': ''}), isNull);
  });

  test(
    'backup restoration preserves manual/imported entries but never source token',
    () async {
      await save([
        reading('r1', DateTime(2026, 10, 7), 71),
      ], token: 'device-token');
      await LocalDb.putJournalMetrics('2026-10-07', {
        'weight_kg': const JournalMetricValue(74),
      });
      final backup = p.join(temp.path, 'backup.db');
      await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
      await File(db.path).copy(backup);
      await LocalDb.wipeAll();
      expect(await db.query('imported_weight'), isEmpty);
      await save([
        reading('local', DateTime(2026, 10, 6), 70),
      ], token: 'local-token');
      await LocalDb.importFromDbFile(backup);
      expect(
        (await db.query('imported_weight')).map((r) => r['record_id']),
        contains('r1'),
      );
      expect(
        (await store.byDay(since: DateTime(2026, 10, 1)))['2026-10-07']!.kg,
        74,
      );
      expect(await store.syncState(), isNull);
      expect(LocalDb.restoreTablesForTest, contains('imported_weight'));
      expect(LocalDb.salvageTablesForTest, contains('imported_weight'));
      await LocalDb.wipeAll();
      expect(await db.query('imported_weight'), isEmpty);
    },
  );

  test(
    'selected-day deletion removes imported readings on that local day',
    () async {
      await save([
        reading('one', DateTime(2026, 10, 7, 23, 59), 71),
        reading('two', DateTime(2026, 10, 8), 72),
      ]);
      await LocalDb.deleteDays({'2026-10-07'});
      expect((await db.query('imported_weight')).single['record_id'], 'two');
    },
  );
}
