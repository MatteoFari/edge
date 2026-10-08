import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'workout_history_range_test.db';
  });
  setUp(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  test(
    'history includes old stored sessions and excludes its upper boundary',
    () async {
      final repo = LocalRepositoryImpl(getProfileMap: () => null);
      final old =
          DateTime.now()
              .subtract(const Duration(days: 400))
              .millisecondsSinceEpoch ~/
          1000;
      for (final (id, start) in [('old', old), ('boundary', old + 3600)]) {
        await LocalDb.putSession({
          'id': id,
          'start_ts': start,
          'end_ts': start + 600,
          'type': 'run',
          'status': 'done',
          'source': 'manual',
          'duration_min': 10,
          'created_at': start,
        });
      }
      expect((await repo.getWorkouts())['workouts'], isEmpty);
      final history = await repo.getWorkoutHistory(
        fromTs: old,
        untilTs: old + 3600,
      );
      expect((history['workouts'] as List).map((w) => w['id']), ['old']);
      expect((history['workouts'] as List).single['avg_hr'], isNull);
      expect(
        (await repo.getWorkoutHistory(fromTs: old, untilTs: old))['workouts'],
        isEmpty,
      );
    },
  );

  test('all-time imported history is not capped at 200 rows', () async {
    await LocalDb.putImportedWorkouts([
      for (var i = 0; i < 206; i++)
        {
          'uuid': 'import-$i',
          'start_ts': 1000 + i * 60,
          'end_ts': 1060 + i * 60,
          'kind': 'RUNNING',
          'source': 'Test recorder',
        },
    ]);
    expect(await LocalDb.importedWorkouts(), hasLength(200));
    final all = await LocalDb.importedWorkouts(
      limit: null,
      sinceTs: 1000,
      untilTs: 1000 + 206 * 60,
    );
    expect(all, hasLength(206));
    expect(all.last['uuid'], 'import-0');
    final selected = await LocalDb.importedWorkouts(
      limit: null,
      sinceTs: 1000 + 60,
      untilTs: 1000 + 3 * 60,
    );
    expect(selected.map((w) => w['uuid']), ['import-2', 'import-1']);
  });

  test('local-midnight bounds include the full 25-hour DST day', () async {
    final start = DateTime(2026, 10, 25);
    final until = DateTime(2026, 10, 26);
    final fromTs = start.millisecondsSinceEpoch ~/ 1000;
    final untilTs = until.millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putImportedWorkouts([
      {
        'uuid': 'last-hour',
        'start_ts': untilTs - 600,
        'end_ts': untilTs - 300,
        'kind': 'WALKING',
        'source': 'Test recorder',
      },
      {
        'uuid': 'next-day',
        'start_ts': untilTs,
        'end_ts': untilTs + 300,
        'kind': 'WALKING',
        'source': 'Test recorder',
      },
    ]);
    final selected = await LocalDb.importedWorkouts(
      limit: null,
      sinceTs: fromTs,
      untilTs: untilTs,
    );
    expect(selected.map((w) => w['uuid']), ['last-hour']);
    if (start.timeZoneName == 'CEST') {
      expect(until.difference(start), const Duration(hours: 25));
    }
  });
}
