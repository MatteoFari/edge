import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory testDirectory;
  late PathProviderPlatform previousPaths;
  late LocalRepositoryImpl repo;
  late String previousDbName;
  final now = DateTime.now();
  final today = dayLabelOf(now);
  final onset =
      DateTime(now.year, now.month, now.day, 1).millisecondsSinceEpoch ~/ 1000;
  final offset = onset + 7 * 3600;
  String previousDay(int i) =>
      dayLabelOf(DateTime(now.year, now.month, now.day - i));

  Future<bool> result(
    String day, {
    int? revision,
    bool partial = false,
    double readiness = 72,
  }) => LocalDb.putDayResult(
    dayId: day,
    algoVersion: kAlgoVersion,
    finalized: true,
    partial: partial,
    sleepPlanOverrideRevision: revision,
    rhr: 54,
    rmssd: 48,
    readiness: readiness,
    series: {'readiness': readiness, 'rhr': 54, 'rmssd': 48},
    windowJson: '{}',
    payloadJson: jsonEncode({
      'date': day,
      'scalars': {'readiness': readiness, 'rhr': 54, 'rmssd': 48, 'nap_min': 0},
      'sleep': {
        'window': {
          'value': {'start_sec': onset, 'end_sec': offset, 'spt_sec': 7 * 3600},
        },
        'accounting': {
          'value': {'tst_sec': 7 * 3600},
        },
      },
    }),
  );

  Map<String, dynamic> plan(Map<String, dynamic> context) => {
    'algo_version': kAlgoVersion,
    'built_for_day': today,
    'built_at_epoch': now.millisecondsSinceEpoch ~/ 1000,
    'sleep_plan_context': context,
    'sleep_coach': {
      'need': {
        'value': {'need_sec': 8 * 3600},
      },
    },
    'sleep_debt': {
      'value': {'debt_hours': 1},
    },
    'load': {
      'value': {'ctl': 120},
    },
    'readiness_glassbox': {
      'drivers': ['preserved'],
    },
  };

  Future<void> storeCurrentPlan() async {
    final context = await LocalDb.sleepPlanSourceContext();
    expect(
      await LocalDb.putReviewedBaseline(
        'crossday',
        jsonEncode(plan(context)),
        context['review_revision'] as int,
        sleepPlanContext: context,
      ),
      isTrue,
    );
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    previousDbName = LocalDb.dbName;
    previousPaths = PathProviderPlatform.instance;
    testDirectory = await Directory.systemTemp.createTemp(
      'sleep_plan_context_',
    );
    PathProviderPlatform.instance = _Paths(testDirectory.path);
    LocalDb.dbName = p.join(
      testDirectory.path,
      'sleep_plan_context_regression.db',
    );
    db = await LocalDb.instance;
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
    for (var i = 2; i >= 0; i--) {
      expect(await result(previousDay(i)), isTrue);
    }
    await LocalDb.putBaseline('recovery_calibration', '{"fixed":72}');
    await LocalDb.putBaseline('movement_floor', '{"fixed":0.02}');
    await storeCurrentPlan();
  });
  tearDown(() async {
    DerivationEngine.debugRunning = false;
    await LocalDb.close();
    LocalDb.dbName = previousDbName;
    PathProviderPlatform.instance = previousPaths;
    await testDirectory.delete(recursive: true);
  });

  test(
    'raw-less old corrections stay saved without blocking unrelated plans or retrying forever',
    () async {
      final old = previousDay(10);
      await result(old);
      await LocalDb.putSleepOverride(
        dayId: old,
        onsetTs: onset - 10 * 86400,
        offsetTs: offset - 10 * 86400,
        source: 'manual',
      );
      final retained = await LocalDb.dayResult(old);
      final override = await LocalDb.getSleepOverride(old);
      final scalars = await db.query('metric_series');
      expect(await LocalDb.sleepPlanOverrideDaysWithRecordings(), isEmpty);
      expect(await repo.getInsights(), contains('sleep_plan_stale'));
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        true,
      );
      final insights = await repo.getInsights();
      expect(insights, isNot(contains('sleep_plan_stale')));
      expect(insights['sleep_planning']['excluded_days'], [old]);
      expect(await LocalDb.sleepPlanRefreshPending(), false);
      expect(await LocalDb.pendingSleepPlanOverrideDays(), {old});
      expect(await LocalDb.dayResult(old), retained);
      expect(await LocalDb.getSleepOverride(old), override);
      expect(await db.query('metric_series'), scalars);
      await LocalDb.close();
      db = await LocalDb.instance;
      final stored = await LocalDb.baseline('crossday');
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        true,
      );
      expect(await LocalDb.baseline('crossday'), stored);
      expect(await repo.getInsights(), isNot(contains('sleep_plan_stale')));
      expect(
        (await LocalDb.baseline('recovery_calibration'))!['payload_json'],
        '{"fixed":72}',
      );
      await LocalDb.putSleepOverride(
        dayId: old,
        onsetTs: onset - 10 * 86400 + 60,
        offsetTs: offset - 10 * 86400,
        source: 'manual',
      );
      expect(await repo.getInsights(), contains('sleep_plan_stale'));
    },
  );

  test(
    'same-day failed crossday refresh hides only the stale sleep plan; restart retries it',
    () async {
      final stored = (await LocalDb.baseline('crossday'))!['payload_json'];
      final seriesBefore = await db.query('metric_series');
      await result(today, readiness: 74);
      final acceptedSeries = await db.query('metric_series');
      expect(acceptedSeries, isNot(seriesBefore));
      await db.execute(
        "CREATE TRIGGER fail_plan BEFORE INSERT ON baselines WHEN NEW.key = 'crossday' BEGIN SELECT RAISE(FAIL, 'test rollup failure'); END",
      );
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        isFalse,
      );
      expect(await LocalDb.sleepPlanRefreshPending(), isTrue);
      expect((await LocalDb.baseline('crossday'))!['payload_json'], stored);
      final visible = await repo.getInsights();
      expect(visible, isNot(contains('sleep_coach')));
      expect(visible, isNot(contains('sleep_debt')));
      expect(visible['sleep_plan_stale']['kind'], 'plan_context');
      expect(visible['load'], {
        'value': {'ctl': 120},
      });
      expect(visible['readiness_glassbox'], {
        'drivers': ['preserved'],
      });
      expect((await repo.getDaySleepV2(today))['need_min'], isNull);
      expect(await db.query('metric_series'), acceptedSeries);
      expect(
        (await LocalDb.baseline('recovery_calibration'))!['payload_json'],
        '{"fixed":72}',
      );
      expect(
        (await LocalDb.baseline('movement_floor'))!['payload_json'],
        '{"fixed":0.02}',
      );
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(await LocalDb.sleepPlanRefreshPending(), isTrue);
      await db.execute('DROP TRIGGER fail_plan');
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        isTrue,
      );
      expect(await LocalDb.sleepPlanRefreshPending(), isFalse);
      final refreshed =
          jsonDecode(
                (await LocalDb.baseline('crossday'))!['payload_json'] as String,
              )
              as Map;
      expect(
        await LocalDb.sleepPlanContextCurrent(refreshed['sleep_plan_context']),
        isTrue,
      );
      expect(await repo.getInsights(), isNot(contains('sleep_plan_stale')));
      expect(await db.query('metric_series'), acceptedSeries);
      expect(
        (await LocalDb.baseline('recovery_calibration'))!['payload_json'],
        '{"fixed":72}',
      );
    },
  );

  test(
    'only restored recordings in a correction window make it eligible for retry',
    () async {
      final old = previousDay(10);
      final date = DateTime.parse(old);
      final oldOnset =
          DateTime(date.year, date.month, date.day, 1).millisecondsSinceEpoch ~/
          1000;
      await LocalDb.putSleepOverride(
        dayId: old,
        onsetTs: oldOnset,
        offsetTs: oldOnset + 7 * 3600,
        source: 'manual',
      );
      Future<void> recording(int ts) => db.insert('decoded_onehz', {
        'device_id': LocalDb.kPrimaryDeviceId,
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': ts,
        'hr': 55,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      });
      await recording(onset);
      expect(await LocalDb.sleepPlanOverrideDaysWithRecordings(), isEmpty);
      await recording(oldOnset);
      expect(await LocalDb.sleepPlanOverrideDaysWithRecordings(), {old});
      expect(await LocalDb.pendingSleepPlanOverrideDays(), {old});
    },
  );

  for (final deletion in [false, true]) {
    test(
      '${deletion ? 'delete' : 'set'} during an in-flight derivation rejects its day and scalar writes',
      () async {
        if (deletion) {
          await LocalDb.putSleepOverride(
            dayId: today,
            onsetTs: onset,
            offsetTs: offset,
            source: 'manual',
          );
          await result(
            today,
            revision: await LocalDb.sleepPlanOverrideRevision(),
          );
          await storeCurrentPlan();
        }
        final preparedRevision = await LocalDb.sleepPlanOverrideRevision();
        final releaseWorker = Completer<void>();
        final oldWorker = releaseWorker.future.then(
          (_) => result(today, revision: preparedRevision, readiness: 99),
        );
        if (deletion) {
          await LocalDb.deleteSleepOverride(today);
          expect(await LocalDb.getSleepOverride(today), isNull);
        } else {
          await LocalDb.putSleepOverride(
            dayId: today,
            onsetTs: onset + 600,
            offsetTs: offset,
            source: 'manual',
          );
        }
        expect(await LocalDb.pendingSleepPlanOverrideDays(), {today});
        final original = await LocalDb.dayResult(today);
        final scalars = await db.query('metric_series');
        releaseWorker.complete();
        expect(await oldWorker, isFalse);
        expect(await LocalDb.dayResult(today), original);
        expect(await db.query('metric_series'), scalars);
        expect(await LocalDb.pendingSleepPlanOverrideDays(), {today});
        expect(await repo.getInsights(), isNot(contains('sleep_coach')));
        await LocalDb.close();
        db = await LocalDb.instance;
        expect(await LocalDb.pendingSleepPlanOverrideDays(), {today});
        final currentRevision = await LocalDb.sleepPlanOverrideRevision();
        expect(currentRevision, greaterThan(preparedRevision));
        // A retained/import patch has no prepared provenance and cannot bless it.
        expect(await result(today), isFalse);
        expect(
          await result(today, revision: currentRevision, partial: true),
          isTrue,
        );
        expect(await LocalDb.pendingSleepPlanOverrideDays(), {today});
        expect(
          await result(today, revision: currentRevision, readiness: 75),
          isTrue,
        );
        expect(await LocalDb.pendingSleepPlanOverrideDays(), isEmpty);
        final corrected = await LocalDb.dayResult(today);
        expect(
          await result(today, revision: preparedRevision, readiness: 99),
          isFalse,
        );
        expect(await LocalDb.dayResult(today), corrected);
        expect(await LocalDb.pendingSleepPlanOverrideDays(), isEmpty);
        expect(await LocalDb.sleepPlanRefreshPending(), isTrue);
        expect(
          await DerivationEngine().refreshActivityReviews(const Profile()),
          isTrue,
        );
        expect(await LocalDb.sleepPlanRefreshPending(), isFalse);
        expect(await repo.getInsights(), isNot(contains('sleep_plan_stale')));
      },
    );
  }

  for (final change in [
    'review',
    'day',
    'override_set',
    'override_delete',
    'input',
  ]) {
    test(
      '$change rejects crossday publication from an older source snapshot',
      () async {
        await LocalDb.putReviewedBaseline(
          'crossday_input',
          '{}',
          await LocalDb.activityReviewRevision(),
        );
        final context = {
          ...await LocalDb.sleepPlanSourceContext(),
          'input_updated_at': (await LocalDb.baseline(
            'crossday_input',
          ))!['updated_at'],
        };
        final stored = (await LocalDb.baseline('crossday'))!['payload_json'];
        switch (change) {
          case 'review':
            await LocalDb.putNapEdit(
              dayId: today,
              startTs: offset + 3600,
              endTs: offset + 5400,
              source: 'manual',
            );
          case 'day':
            await result(today, readiness: 76);
          case 'override_set':
            await LocalDb.putSleepOverride(
              dayId: today,
              onsetTs: onset,
              offsetTs: offset,
              source: 'manual',
            );
          case 'override_delete':
            await LocalDb.deleteSleepOverride(today);
          case 'input':
            await LocalDb.putReviewedBaseline(
              'crossday_input',
              '{"changed":true}',
              await LocalDb.activityReviewRevision(),
            );
        }
        expect(await LocalDb.sleepPlanContextCurrent(context), isFalse);
        expect(
          await LocalDb.putReviewedBaseline(
            'crossday',
            jsonEncode(plan(context)),
            context['review_revision'] as int,
            sleepPlanContext: context,
          ),
          isFalse,
        );
        expect((await LocalDb.baseline('crossday'))!['payload_json'], stored);
        expect(await LocalDb.finishSleepPlanRefresh(context), isFalse);
      },
    );
  }

  test(
    'day rollover and metadata changes are rejected even without a revision write',
    () async {
      final context = await LocalDb.sleepPlanSourceContext();
      final yesterday = {...context, 'local_day': previousDay(1)};
      expect(
        await LocalDb.putReviewedBaseline(
          'crossday',
          '{}',
          context['review_revision'] as int,
          sleepPlanContext: yesterday,
        ),
        isFalse,
      );
      await db.update(
        'day_result',
        {'computed_at': 1},
        where: 'day_id = ?',
        whereArgs: [today],
      );
      expect(await LocalDb.sleepPlanContextCurrent(context), isFalse);
      expect(await repo.getInsights(), isNot(contains('sleep_coach')));
    },
  );

  test(
    'legacy same-day plans without a provable context abstain without hiding aggregates',
    () async {
      final legacy = plan(await LocalDb.sleepPlanSourceContext())
        ..remove('sleep_plan_context');
      await LocalDb.putBaseline('crossday', jsonEncode(legacy));
      final visible = await repo.getInsights();
      expect(visible, isNot(contains('sleep_coach')));
      expect(visible['load'], legacy['load']);
      expect(visible['readiness_glassbox'], legacy['readiness_glassbox']);
    },
  );

  test(
    'deletion tombstone and pending context are included in the existing backup storage',
    () async {
      await LocalDb.deleteSleepOverride(today);
      final directory = Directory.systemTemp.createTempSync(
        'sleep-plan-backup-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = p.join(directory.path, 'backup.db');
      await db.execute('VACUUM INTO ?', [path]);
      final backup = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final stored = (await backup.query(
          'baselines',
          where: 'key = ?',
          whereArgs: ['sleep_plan_context'],
        )).single;
        final state = jsonDecode(stored['payload_json'] as String) as Map;
        expect(
          (state['override_days'] as Map)[today],
          await LocalDb.sleepPlanOverrideRevision(),
        );
        expect((state['pending_overrides'] as Map).keys, contains(today));
        expect(state['refresh_pending'], isTrue);
      } finally {
        await backup.close();
      }
      final revision = await LocalDb.sleepPlanOverrideRevision();
      await LocalDb.wipeAll();
      await LocalDb.close();
      db = await LocalDb.instance;
      await LocalDb.importFromDbFile(path);
      expect(await LocalDb.getSleepOverride(today), isNull);
      expect(await LocalDb.sleepPlanOverrideRevision(), revision);
      expect(await LocalDb.pendingSleepPlanOverrideDays(), {today});
      expect(await LocalDb.sleepPlanRefreshPending(), isTrue);
      expect(await repo.getInsights(), isNot(contains('sleep_coach')));
    },
  );

  Future<void> seedLocalData() async {
    final batch = db.batch();
    for (var ts = onset; ts < offset + 3600; ts += 60) {
      batch.insert('decoded_onehz', {
        'device_id': LocalDb.kPrimaryDeviceId,
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': ts,
        'hr': 55,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      });
    }
    await batch.commit(noResult: true);
    await db.insert('device_coverage', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'signal': 'hr1Hz',
      'start_ts': onset,
      'end_ts': offset + 3600,
    });
  }

  test(
    'retry uses local decoded data to satisfy a pending correction without a pairing',
    () async {
      await seedLocalData();
      // This fixture has no RR/night physiology; keep the existing guard's
      // refusal of a poorer re-stage out of this fresh-day retry scenario.
      await db.delete('day_result', where: 'day_id = ?', whereArgs: [today]);
      await LocalDb.putSleepOverride(
        dayId: today,
        onsetTs: onset,
        offsetTs: offset,
        source: 'manual',
      );
      await LocalDb.close();
      db = await LocalDb.instance;
      final logs = <String>[];
      final refreshed = await DerivationEngine(
        log: logs.add,
      ).refreshActivityReviews(const Profile());
      expect(refreshed, isTrue, reason: logs.join('\n'));
      expect(await LocalDb.pendingSleepPlanOverrideDays(), isEmpty);
      expect(await LocalDb.sleepPlanRefreshPending(), isFalse);
      expect(await repo.getInsights(), isNot(contains('sleep_plan_stale')));
      expect(
        (await LocalDb.baseline('recovery_calibration'))!['payload_json'],
        '{"fixed":72}',
      );
    },
  );

  test(
    'a pending deletion is not finalized and survives a prune chosen before the edit',
    () async {
      await db.insert('decoded_onehz', {
        'device_id': LocalDb.kPrimaryDeviceId,
        'ts_ms': onset * 1000,
        'rec_ts': onset,
        'counter': 1,
      });
      final selectedCutoff = offset + 3600;
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), contains(today));
      await LocalDb.deleteSleepOverride(today);
      expect(
        await LocalDb.finalizedDayIds(kAlgoVersion),
        isNot(contains(today)),
      );
      await LocalDb.pruneDecodedBeforeRecTs(
        selectedCutoff,
        cursorName: 'test_prune',
      );
      expect((await db.query('decoded_onehz')).single['rec_ts'], onset);
      expect(await LocalDb.getCursorInt('test_prune'), onset);
    },
  );

  test(
    'an intentional rejected main sleep settles as an absent window rather than a failed skip',
    () async {
      await seedLocalData();
      await LocalDb.putSleepOverride(
        dayId: today,
        onsetTs: onset,
        offsetTs: offset,
        source: 'rejected',
      );
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        isTrue,
      );
      expect(await LocalDb.pendingSleepPlanOverrideDays(), isEmpty);
      expect(await LocalDb.sleepPlanRefreshPending(), isFalse);
      final row = (await LocalDb.dayResult(today))!;
      expect(row['skipped'], 0);
      expect(row['partial'], 0);
      expect((await repo.getDaySleepV2(today))['duration_min'], isNull);
    },
  );

  for (final deletion in [false, true]) {
    test(
      'a ${deletion ? 'deleted' : 'changed'} restored override row rejects a captured preparation and queues a durable retry',
      () async {
        await LocalDb.putSleepOverride(
          dayId: today,
          onsetTs: onset,
          offsetTs: offset,
          source: 'manual',
        );
        await result(
          today,
          revision: await LocalDb.sleepPlanOverrideRevision(),
        );
        final prepared = await LocalDb.sleepPlanPreparation(today);
        final original = await LocalDb.dayResult(today);
        // A restore writer does not call the editor setter. Verify the actual
        // input stamp as well as the editor's monotonic revision.
        if (deletion) {
          await db.delete(
            'sleep_override',
            where: 'day_id = ?',
            whereArgs: [today],
          );
        } else {
          await db.update(
            'sleep_override',
            {'onset_ts': onset + 600},
            where: 'day_id = ?',
            whereArgs: [today],
          );
        }
        expect(
          await LocalDb.putDayResult(
            dayId: today,
            algoVersion: kAlgoVersion,
            payloadJson: '{"scalars":{"readiness":99}}',
            windowJson: '{}',
            sleepPlanOverrideRevision: prepared.revision,
            sleepPlanOverrideStamp: prepared.overrideStamp,
          ),
          isFalse,
        );
        expect(await LocalDb.dayResult(today), original);
        expect(await LocalDb.pendingSleepPlanOverrideDays(), {today});
        await LocalDb.close();
        db = await LocalDb.instance;
        expect(await LocalDb.pendingSleepPlanOverrideDays(), {today});
      },
    );
  }

  test(
    'deleting a day consumes its correction job and prevents an older worker restoring that day',
    () async {
      await LocalDb.deleteSleepOverride(today);
      final prepared = await LocalDb.sleepPlanPreparation(today);
      await LocalDb.deleteDays({today});
      expect(await LocalDb.pendingSleepPlanOverrideDays(), isEmpty);
      expect(await result(today, revision: prepared.revision), isFalse);
      expect(await LocalDb.dayResult(today), isNull);
    },
  );

  test(
    'busy derivation stays queued; missing recordings publish an honest unknown plan',
    () async {
      await LocalDb.deleteSleepOverride(today);
      DerivationEngine.debugRunning = true;
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        isFalse,
      );
      DerivationEngine.debugRunning = false;
      expect(
        await DerivationEngine().refreshActivityReviews(const Profile()),
        isTrue,
      );
      expect(await LocalDb.pendingSleepPlanOverrideDays(), {today});
      expect(await LocalDb.sleepPlanRefreshPending(), false);
      final insights = await repo.getInsights();
      expect(insights, isNot(contains('sleep_plan_stale')));
      expect(insights['sleep_coach']['need']['value'], '—');
      expect(DerivationEngine().running, isFalse);
    },
  );
}
