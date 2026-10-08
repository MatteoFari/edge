import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/sleep_plan_reference.dart';

List<Map<String, dynamic>> _history({bool shortLast = true}) => [
  for (var i = 0; i < 50; i++)
    {
      'date': dayLabelOf(DateTime(2026, 9, i + 1)),
      'sleep_complete': true,
      'sleep_episode_settled': true,
      'tst_min': shortLast && i == 49 ? 240.0 : 480.0,
      'nap_min': 0.0,
      'strain': 0.0,
      'efficiency': 95.0,
      'onset_sec': DateTime(2026, 9, i, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_sec': DateTime(2026, 9, i + 1, 7).millisecondsSinceEpoch ~/ 1000,
      if (i == 49) 'is_today': true,
    },
];

Map<String, dynamic> _bundle({int gap = 3}) => {
  'date': '2026-10-08',
  'data_edge_sec': 108000,
  'sleep': {
    'window': {
      'value': {'onset_ms': 72000000, 'offset_ms': 86400000},
    },
    'accounting': {
      'value': {
        'tst_sec': 14000,
        'in_bed_sec': 14400,
        'observed_in_bed_sec': 14400 - gap,
      },
    },
  },
};

void main() {
  test(
    'an old pending correction is excluded without blocking a recent plan',
    () {
      final data = _history();
      final old = data[38]['date'] as String;
      final before = jsonEncode(data);
      final out = buildCrossDayBundle(
        data,
        {},
        sleepPlanningExcludedDays: {old},
      );
      final planning = out['sleep_planning'] as Map;
      final result = (planning['result'] as Map)['value'] as Map;
      expect(planning['excluded_days'], [old]);
      expect(result['need_sec'], 9 * 3600);
      expect(result['recent_shortfall_sec'], 4 * 3600);
      expect(jsonEncode(data), before);
      expect(
        sleepPlanOverridesHandled({
          'pending_overrides': [
            [old, 2],
          ],
        }, planning),
        true,
      );
      expect(
        sleepPlanOverridesHandled({
          'pending_overrides': [
            [old, 2],
          ],
        }, {}),
        false,
      );
    },
  );
  test(
    'a pending recent correction remains unknown rather than zero shortfall',
    () {
      final data = _history();
      for (final index in [47, 49]) {
        final out = buildCrossDayBundle(
          data,
          {},
          sleepPlanningExcludedDays: {data[index]['date'] as String},
        );
        final result =
            ((out['sleep_planning'] as Map)['result'] as Map)['value'] as Map;
        expect(result['need_sec'], isNull);
        expect(result['recent_shortfall_sec'], isNull);
        expect(result['missing_days'], greaterThan(0));
        expect(result['latest_shortfall_sec'], index == 49 ? isNull : 4 * 3600);
      }
    },
  );
  test('unresolved corrections cannot contribute to an anchored reference', () {
    final data = _history();
    final anchor =
        (buildCrossDayBundle(data, {})['sleep_planning'] as Map)['reference'];
    final out = buildCrossDayBundle(
      data,
      {},
      sleepPlanningAnchor: anchor,
      sleepPlanningExcludedDays: {
        for (final d in data.take(8)) d['date'] as String,
      },
    );
    expect((out['sleep_planning'] as Map)['reference'], isNull);
    expect(
      ((out['sleep_planning'] as Map)['result'] as Map)['value']['need_sec'],
      isNull,
    );
  });
  test(
    'three missing seconds admit recorded sleep without filling those gaps',
    () {
      final b = _bundle();
      final before = jsonEncode(b);
      expect(sleepPlanNightComplete(b, partial: false), true);
      expect(jsonEncode(b), before);
      expect(sleepPlanNightComplete(_bundle(gap: 31), partial: false), false);
      expect(sleepPlanNightComplete(b, partial: true), false);
      b['data_edge_sec'] = 86401;
      expect(sleepPlanNightComplete(b, partial: false), false);
    },
  );
  test('substantial or unknown recording gaps cannot establish shortfall', () {
    final b = _bundle(gap: 3600);
    expect(sleepPlanNightComplete(b, partial: false), false);
    (b['sleep']['accounting']['value'] as Map).remove('observed_in_bed_sec');
    expect(sleepPlanNightComplete(b, partial: false), false);
  });
  test(
    'retained native accounting and reported imports keep their provenance',
    () {
      final b = _bundle()..remove('data_edge_sec');
      final row = {
        'day_id': '2026-10-08',
        'partial': 0,
        'finalized': 1,
        'algo_version': 97,
      };
      var record = DerivationEngine.crossDayInputRecord(
        row,
        b,
        today: '2026-10-09',
        imported: {},
      );
      expect(record!['sleep_complete'], true);
      (b['sleep']['accounting']['value'] as Map).remove('observed_in_bed_sec');
      b.addAll({'imported': true, 'source': 'whoop_export'});
      record = DerivationEngine.crossDayInputRecord(
        row,
        b,
        today: '2026-10-09',
        imported: {'2026-10-08'},
      );
      expect(record!['sleep_complete'], false);
      expect(record['reported_sleep'], true);
      expect(record['planning_tst_sec'], 14000);
    },
  );
  test(
    'a short last night changes shortfall independently of historical medians',
    () {
      final data = _history();
      final out = buildCrossDayBundle(data, {});
      final planning = out['sleep_planning'] as Map;
      final result = (planning['result'] as Map)['value'] as Map;
      expect((planning['reference'] as Map)['validated'], false);
      expect(result['latest_shortfall_sec'], 4 * 3600);
      expect(result['recent_shortfall_sec'], 4 * 3600);
      expect(result['shortfall_adjustment_sec'], 3600);
      expect(result['need_sec'], 9 * 3600);
      expect((out['sleep_debt'] as Map)['confidence'], lessThanOrEqualTo(.2));
      expect(jsonEncode(buildCrossDayBundle(data, {})), jsonEncode(out));
    },
  );
  test(
    'a missing date keeps latest shortfall but withholds totals and need',
    () {
      final data = _history()..removeAt(47);
      final out = buildCrossDayBundle(data, {});
      final result =
          ((out['sleep_planning'] as Map)['result'] as Map)['value'] as Map;
      expect(result['latest_shortfall_sec'], 4 * 3600);
      expect(result['recent_shortfall_sec'], isNull);
      expect(result['need_sec'], isNull);
      expect((out['sleep_debt'] as Map)['value'], '—');
      expect((out['sleep_debt'] as Map)['confidence'], 0);
    },
  );
  test('partial current night cannot borrow yesterday or a vendor score', () {
    final data = _history();
    data.last['sleep_complete'] = false;
    final out = buildCrossDayBundle(data, {});
    final result =
        ((out['sleep_planning'] as Map)['result'] as Map)['value'] as Map;
    expect(result['latest_shortfall_sec'], isNull);
    expect(result['need_sec'], isNull);
  });
  test(
    'reference stays anchored after recent short nights and survives JSON',
    () {
      final data = _history(shortLast: false);
      final initial = buildCrossDayBundle(data, {});
      final anchor = jsonDecode(
        jsonEncode((initial['sleep_planning'] as Map)['reference']),
      );
      for (final d in data.skip(43)) {
        d['tst_min'] = 240.0;
      }
      final out = buildCrossDayBundle(data, {}, sleepPlanningAnchor: anchor);
      expect((out['sleep_planning'] as Map)['reference'], anchor);
      expect(
        (out['sleep_coach'] as Map)['performance'],
        (initial['sleep_coach'] as Map)['performance'],
      );
    },
  );
  test(
    'civil dates across DST retain seven slots rather than elapsed 24h blocks',
    () {
      final data = _history();
      for (var i = 0; i < data.length; i++) {
        data[i]['date'] = dayLabelOf(DateTime(2026, 2, 20 + i));
      }
      final out = buildCrossDayBundle(data, {});
      final result =
          ((out['sleep_planning'] as Map)['result'] as Map)['value'] as Map;
      expect(result['missing_days'], 0);
      expect(result['latest_shortfall_sec'], 4 * 3600);
    },
  );
  test(
    'old reference corrections use retained days without changing other history',
    () {
      final original = _history();
      final first = buildCrossDayBundle(original, {});
      final anchor = (first['sleep_planning'] as Map)['reference'];
      final recent = original.skip(28).toList();
      final correctedAnchor = [
        for (final d in original.take(28)) {...d, 'tst_min': 540.0},
      ];
      final corrected = buildCrossDayBundle(
        recent,
        {},
        sleepPlanningAnchor: anchor,
        sleepPlanningAnchorDays: correctedAnchor,
      );
      expect(
        ((corrected['sleep_planning'] as Map)['reference']
            as Map)['reference_sec'],
        9 * 3600,
      );
      expect((corrected['recent'] as List).length, recent.length);
      final deleted = buildCrossDayBundle(
        recent,
        {},
        sleepPlanningAnchor: anchor,
        sleepPlanningAnchorDays: [
          for (final d in original.take(28))
            {'date': d['date'], 'sleep_complete': false},
        ],
      );
      expect((deleted['sleep_planning'] as Map)['reference'], isNull);
    },
  );
}
