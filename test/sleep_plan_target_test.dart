import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_plan_reference.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String oldName;
  late Directory testDirectory;
  late PathProviderPlatform previousPaths;
  late Database db;
  late int now;
  late String today;
  late String tomorrow;
  late String previousDay;
  late Map<String, dynamic> context;
  Map<String, dynamic> plan(int hours) => {
    'algo_version': kAlgoVersion,
    'built_for_day': today,
    'built_at_epoch': now - 1,
    'sleep_plan_context': context,
    'sleep_planning': {
      'reference': {'reference_sec': 28800, 'from_day': 1, 'through_day': 28,
        'nights': 28, 'source': 'observed_longer_sleep', 'validated': false},
    },
    'sleep_coach': {
      'reference_night_day': previousDay,
      'reference_night_onset_sec': now - 10 * 3600,
      'reference_night_wake_sec': now - 2 * 3600,
      'target_day': today,
      'need': {
        'value': {'need_sec': hours * 3600},
        'confidence': 0.6,
      },
    },
  };
  Future<bool> publish(int hours, {Map<String, dynamic>? source}) =>
      LocalDb.putReviewedBaseline(
        'crossday',
        jsonEncode(plan(hours)),
        context['review_revision'] as int,
        sleepPlanContext: source ?? context,
      );
  Future<List<Map<String, Object?>>> targets() =>
      db.query('baselines', where: 'key LIKE ?', whereArgs: ['sleep_target:%']);
  Map<String, dynamic> night(Map<String, dynamic>? reference) => {
    'date': today,
    'sleep_plan_reference': reference,
    'sleep_plan_complete': true,
    'data_edge_sec': now,
    'sleep': {
      'window': {
        'value': {
          'onset_ms': (now - 10 * 3600) * 1000,
          'offset_ms': (now - 2 * 3600) * 1000,
          'spt_sec': 8 * 3600,
        },
      },
      'accounting': {
        'value': {
          'tst_sec': 4 * 3600,
          'in_bed_sec': 8 * 3600,
          'observed_in_bed_sec': 8 * 3600,
        },
      },
    },
  };
  Map<String, dynamic> reference() => {
    'model': 'observed_sleep_target_v1',
    'need_sec': 8 * 3600,
    'built_at_epoch': now - 12 * 3600,
    'committed_at_epoch': now - 12 * 3600,
    'source_day': today,
    'target_day': today,
  };

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    oldName = LocalDb.dbName;
    previousPaths = PathProviderPlatform.instance;
    testDirectory = await Directory.systemTemp.createTemp('sleep_plan_target_');
    PathProviderPlatform.instance = _Paths(testDirectory.path);
    LocalDb.dbName = p.join(testDirectory.path, 'sleep_plan_target_test.db');
    db = await LocalDb.instance;
    now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    today = todayLabel();
    tomorrow = dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch(localDayEndSec(today)! * 1000),
    );
    final current = DateTime.fromMillisecondsSinceEpoch(
      localDayStartSec(today)! * 1000,
    );
    previousDay = dayLabelOf(
      DateTime(current.year, current.month, current.day - 1),
    );
    context = await LocalDb.sleepPlanSourceContext();
  });
  tearDown(() async {
    await LocalDb.close();
    LocalDb.dbName = oldName;
    PathProviderPlatform.instance = previousPaths;
    await testDirectory.delete(recursive: true);
  });

  test(
    'publication saves a prospective target; late plans cannot score an older night',
    () async {
      expect(await publish(8), true);
      expect(
        (await LocalDb.sleepTargetBefore(
          now + 120,
          nightDay: today,
        ))!['need_sec'],
        8 * 3600,
      );
      expect(
        await LocalDb.sleepTargetBefore(now - 120, nightDay: today),
        isNull,
      );
    },
  );
  test('concurrent retries do not accumulate duplicate snapshots', () async {
    expect(
      await Future.wait([publish(8), publish(8), publish(8)]),
      everyElement(true),
    );
    expect(await targets(), hasLength(1));
  });
  test(
    'newest-first backfill cannot reuse another canonical night target',
    () async {
      await publish(8);
      // The later night arrives first while neither result has been published.
      final laterOnset = now + 24 * 3600;
      expect(
        await LocalDb.sleepTargetBefore(laterOnset, nightDay: tomorrow),
        isNull,
      );
      expect(
        await LocalDb.sleepTargetBefore(now + 120, nightDay: today),
        isNotNull,
      );
      expect(
        await LocalDb.sleepTargetBefore(laterOnset, nightDay: tomorrow),
        isNull,
      );
    },
  );
  test(
    'identical numbers for a new canonical owner create its own target',
    () async {
      await publish(8);
      final next = plan(8);
      (next['sleep_coach'] as Map).addAll(<String, Object>{
        'reference_night_day': today,
        'target_day': tomorrow,
        'reference_night_onset_sec': now - 9 * 3600,
        'reference_night_wake_sec': now - 3600,
      });
      await LocalDb.putReviewedBaseline(
        'crossday',
        jsonEncode(next),
        context['review_revision'] as int,
        sleepPlanContext: context,
      );
      expect(await targets(), hasLength(2));
      expect(
        await LocalDb.sleepTargetBefore(now + 120, nightDay: tomorrow),
        isNotNull,
      );
      expect(
        await LocalDb.sleepTargetBefore(now + 120, nightDay: today),
        isNotNull,
      );
      // Day deletion also removes a target filed by the previous calendar day.
      await LocalDb.deleteDays({tomorrow});
      expect(await targets(), hasLength(1));
    },
  );
  test('stale revision cannot publish a target', () async {
    final stale = {...context, 'source_revision': -1};
    expect(await publish(8, source: stale), false);
    expect(await targets(), isEmpty);
    expect(await LocalDb.baseline('crossday'), isNull);
  });
  test(
    'pending sleep corrections cannot establish a prospective target',
    () async {
      await LocalDb.putSleepOverride(
        dayId: today,
        onsetTs: now - 1000,
        offsetTs: now - 500,
        source: 'manual',
      );
      context = await LocalDb.sleepPlanSourceContext();
      expect(await publish(8), true);
      expect(await targets(), isEmpty);
    },
  );
  test(
    'unknown or future source target is not filled with a default',
    () async {
      final invalid = plan(8);
      (invalid['sleep_coach'] as Map)['need'] = {'value': '—'};
      expect(
        await LocalDb.putReviewedBaseline(
          'crossday',
          jsonEncode(invalid),
          context['review_revision'] as int,
          sleepPlanContext: context,
        ),
        true,
      );
      expect(await targets(), isEmpty);
      final future = {...plan(8), 'built_at_epoch': now + 3600};
      await LocalDb.putReviewedBaseline(
        'crossday',
        jsonEncode(future),
        context['review_revision'] as int,
        sleepPlanContext: context,
      );
      expect(await targets(), isEmpty);
    },
  );
  test(
    'night target stays fixed after next plan changes and raw expires',
    () async {
      await LocalDb.putBaseline('recovery_calibration', '{"fixed":72}');
      await LocalDb.putDayResult(
        dayId: today,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode(night(reference())),
        windowJson: '{}',
        finalized: true,
      );
      context = await LocalDb.sleepPlanSourceContext();
      await publish(9);
      final repo = LocalRepositoryImpl(getProfileMap: () => const {});
      final first = await repo.getDaySleepV2(today);
      expect(first['duration_min'], 240);
      expect(first['need_min'], 480);
      expect(first['target_shortfall_min'], 240);
      expect(first['debt_min'], isNull);
      await LocalDb.close();
      db = await LocalDb.instance;
      expect((await repo.getDaySleepV2(today))['need_min'], 480);
      expect(
        (await LocalDb.baseline('recovery_calibration'))!['payload_json'],
        '{"fixed":72}',
      );
    },
  );
  test('incomplete capture has no numeric shortfall', () async {
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        ...night(reference()),
        'sleep_plan_complete': false,
      }),
      windowJson: '{}',
    );
    final result = await LocalRepositoryImpl(
      getProfileMap: () => const {},
    ).getDaySleepV2(today);
    expect(result['duration_min'], 240);
    expect(result['target_shortfall_min'], isNull);
  });
  test('legacy nights never borrow the current plan', () async {
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(night(null)),
      windowJson: '{}',
    );
    context = await LocalDb.sleepPlanSourceContext();
    await publish(8);
    final result = await LocalRepositoryImpl(
      getProfileMap: () => const {},
    ).getDaySleepV2(today);
    expect(result['need_min'], isNull);
    expect(result['target_shortfall_min'], isNull);
  });
  test(
    'targets and calibration survive backup restore; deletion removes targets',
    () async {
      await publish(8);
      await LocalDb.putBaseline('recovery_calibration', '{"fixed":72}');
      final directory = await Directory.systemTemp.createTemp(
        'sleep-target-backup-',
      );
      final backup = p.join(directory.path, 'backup.db');
      try {
        await db.execute('VACUUM INTO ?', [backup]);
        await LocalDb.wipeAll();
        await LocalDb.close();
        db = await LocalDb.instance;
        await LocalDb.importFromDbFile(backup);
        final restoredPlan = jsonDecode(
            (await LocalDb.baseline('crossday'))!['payload_json'] as String) as Map;
        expect((restoredPlan['sleep_planning'] as Map)['reference'],
            (plan(8)['sleep_planning'] as Map)['reference']);
        expect(
          (await LocalDb.sleepTargetBefore(
            now + 120,
            nightDay: today,
          ))!['need_sec'],
          8 * 3600,
        );
        expect(
          (await LocalDb.baseline('recovery_calibration'))!['payload_json'],
          '{"fixed":72}',
        );
        await LocalDb.deleteDays({today});
        expect(await targets(), isEmpty);
        expect(
          (await LocalDb.baseline('recovery_calibration'))!['payload_json'],
          '{"fixed":72}',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'quality admission distinguishes missing data from a genuinely short night',
    () {
      final complete = night(reference());
      expect(sleepPlanNightComplete(complete, partial: false), true);
      expect(sleepPlanNightComplete(complete, partial: true), false);
      final thin = night(reference());
      thin['sleep']['accounting']['value']['observed_in_bed_sec'] = 3600;
      expect(sleepPlanNightComplete(thin, partial: false), false);
      thin['sleep']['accounting']['value']['observed_in_bed_sec'] = (7.2 * 3600)
          .round();
      expect(sleepPlanNightComplete(thin, partial: false), false);
      final unsettled = {...complete, 'data_edge_sec': now - 2 * 3600};
      expect(sleepPlanNightComplete(unsettled, partial: false), false);
      final unknown = night(reference());
      (unknown['sleep']['accounting']['value'] as Map).remove(
        'observed_in_bed_sec',
      );
      expect(sleepPlanNightComplete(unknown, partial: false), false);
    },
  );
  test(
    'midnight and DST do not alter the absolute ordering of target and onset',
    () {
      for (final onset in [
        DateTime.utc(2026, 3, 29, 0, 30),
        DateTime.utc(2026, 10, 25, 1, 30),
      ]) {
        final sec = onset.millisecondsSinceEpoch ~/ 1000;
        final ref = {
          'model': 'observed_sleep_target_v1',
          'need_sec': 8 * 3600,
          'built_at_epoch': sec - 2 * 3600,
          'committed_at_epoch': sec - 2 * 3600,
          'target_day': dayLabelOf(onset),
        };
        expect(
          sleepPlanReference(ref, sec, nightDay: dayLabelOf(onset)),
          isNotNull,
        );
        expect(
          sleepPlanReference(
            {...ref, 'committed_at_epoch': sec + 1},
            sec,
            nightDay: dayLabelOf(onset),
          ),
          isNull,
        );
        expect(sleepPlanReference(ref, sec, nightDay: '2026-01-01'), isNull);
      }
    },
  );
}
