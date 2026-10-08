import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  late LocalRepositoryImpl repo;
  late String previousDbName;
  late Map<String, dynamic> planContext;
  final now = DateTime.now();
  final today = dayLabelOf(now);
  String dayOffset(int offset) =>
      dayLabelOf(DateTime(now.year, now.month, now.day + offset));

  Map<String, dynamic> artifact(String builtFor) => {
    'algo_version': kAlgoVersion,
    'built_for_day': builtFor,
    'built_at_epoch': now.millisecondsSinceEpoch ~/ 1000,
    'sleep_plan_context': planContext,
    'sleep_coach': {
      'need': {
        'value': {'need_sec': 8 * 3600},
        'confidence': 0.6,
        'tier': 'ESTIMATE',
      },
      'nap_credit_min': 30,
      'strain_bonus_min': 15,
    },
    'sleep_debt': {
      'value': {'debt_hours': 1},
    },
    'readiness_glassbox': {
      'drivers': ['retained aggregate'],
    },
    'load': {
      'value': {'ctl': 120},
    },
  };

  Future<void> storePlan(String builtFor) =>
      LocalDb.putBaseline('crossday', jsonEncode(artifact(builtFor)));

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    previousDbName = LocalDb.dbName;
    LocalDb.dbName = 'sleep_plan_freshness_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    await LocalDb.instance;
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      finalized: true,
      payloadJson: jsonEncode({
        'date': today,
        'sleep': {
          'window': {
            'value': {'spt_sec': 7 * 3600},
          },
          'accounting': {
            'value': {'tst_sec': 7 * 3600},
          },
        },
      }),
      windowJson: '{}',
    );
    planContext = await LocalDb.sleepPlanSourceContext();
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    LocalDb.dbName = previousDbName;
  });

  test(
    'current plan keeps its calculation context and all adjustments',
    () async {
      await storePlan(today);
      expect(await repo.getInsights(), artifact(today));
      // A current NEXT-sleep plan is not this completed night's target.
      expect((await repo.getDaySleepV2(today))['need_min'], isNull);
    },
  );

  for (final offset in [-1, -7, 1]) {
    test(
      'plan from day offset $offset is withheld across both read seams',
      () async {
        final builtFor = dayOffset(offset);
        await storePlan(builtFor);
        final insights = await repo.getInsights();
        expect(insights, isNot(contains('sleep_coach')));
        expect(insights, isNot(contains('sleep_debt')));
        expect(insights['sleep_plan_stale'], {
          'kind': 'plan_day',
          'built_for_day': builtFor,
          'current_day': today,
        });
        // Other cross-day families retain their existing age policy.
        expect(
          insights['readiness_glassbox'],
          artifact(builtFor)['readiness_glassbox'],
        );
        expect(insights['load'], artifact(builtFor)['load']);
        final night = await repo.getDaySleepV2(today);
        expect(night['duration_min'], 420);
        expect(night['need_min'], isNull);
        expect(night, isNot(contains('debt_min')));
        // The durable artifact is preserved; the read gate does not rewrite it.
        final stored = await LocalDb.baseline('crossday');
        expect(
          jsonDecode(stored!['payload_json'] as String),
          artifact(builtFor),
        );
      },
    );
  }

  test(
    'a refresh for today makes the plan visible without a restart',
    () async {
      await storePlan(dayOffset(-1));
      expect(await repo.getInsights(), isNot(contains('sleep_coach')));
      await storePlan(today);
      expect(await repo.getInsights(), artifact(today));
      expect((await repo.getDaySleep(today))['need_min'], isNull);
    },
  );

  test('the general artifact gate still rejects an old algorithm', () async {
    await LocalDb.putBaseline(
      'crossday',
      jsonEncode({...artifact(today), 'algo_version': kAlgoVersion - 1}),
    );
    expect(await repo.getInsights(), {
      'stale': {'kind': 'algo_version', 'algo_version': kAlgoVersion - 1},
    });
    expect((await repo.getDaySleepV2(today))['need_min'], isNull);
  });
}
