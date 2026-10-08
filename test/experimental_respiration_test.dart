import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/data/respiratory_display.dart';

void main() {
  test(
    'experimental derivation preserves every standard scalar and readiness input',
    () {
      const onset = 1791244800;
      final rr = <double>[], ts = <double>[];
      var t = 0.0;
      while (t < 7200) {
        ts.add((onset + t) * 1000);
        rr.add(1360 + 50 * math.cos(2 * math.pi * 12.5 * t / 60));
        t += 60 / (44 + 4 * math.sin(2 * math.pi * t / 90));
      }
      final base = DayBundleInput(
        date: '2026-10-06',
        experimentalRespiration: false,
        dayTsSec: [],
        dayHr: [],
        sleepTsSec: [],
        sleepHr: [],
        sleepRrTsMs: ts,
        sleepRrMs: rr,
        sleepSkinTemp: [],
        sleepJson: {'tst_sec': 7200, 'in_bed_sec': 7200, 'confidence': 0.5},
        hypnoStages: [],
        sleepOnsetSec: onset,
        sleepOffsetSec: onset + 7200,
        profile: {},
        lnRmssdHistory: [3.8, 3.9, 4.0, 4.1, 3.7],
        rhrHistory: [50, 52, 53, 49, 51],
        respHistory: [12, 13, 14, 15, 12.5],
      ).toJson();
      final standard = deriveDayBundle(base);
      final experimental = deriveDayBundle({
        ...base,
        'experimental_respiration': true,
      });
      final scalars = Map<String, dynamic>.from(experimental['scalars'] as Map);
      expect(scalars.remove('resp_rate_experimental'), closeTo(12.5, 0.1));
      expect(scalars, standard['scalars']);
      expect(experimental['baselines'], standard['baselines']);
      expect(
        (experimental['clinical'] as Map)['readiness_composite'],
        (standard['clinical'] as Map)['readiness_composite'],
      );
      expect(
        (standard['respiration'] as Map).containsKey('experimental'),
        false,
      );
      final display = respiratoryDisplayMetric(experimental)!;
      expect(display['label'], 'Breathing rate');
      expect(display['chart_key'], 'resp_rate_experimental');
      expect(display['value'], closeTo(12.5, 0.1));
      expect(display['experimental'], true);
      expect(display['confidence'], 0.25);
      expect(display.containsKey('note'), false);
      expect(
        ((experimental['respiration'] as Map)['experimental'] as Map)['note'],
        contains('confidence is uncalibrated'),
      );
      expect(experimentalRespiratoryCurve(experimental), isNotEmpty);
      expect(() => jsonEncode(experimental), returnsNormally);
    },
  );
  test(
    'experimental absence cannot fall back to a different standard metric',
    () {
      final result = respiratoryDisplayMetric({
        'scalars': {'resp_rate': 14.2, 'resp_rate_experimental': null},
        'respiration': {
          'experimental': {
            'value': '—',
            'confidence': 0,
            'note': 'Insufficient sleep evidence.',
          },
        },
      })!;
      expect(result['value'], isNull);
      expect(result['confidence'], 0);
      expect(result['note'], 'Insufficient sleep evidence.');
      expect(result['experimental'], true);
    },
  );
  test('old/imported bundles retain their original respiratory values', () {
    final result = respiratoryDisplayMetric({
      'scalars': {'resp_rate': 14.23},
      'respiration': {
        'rsa': {'confidence': 0.7},
      },
    })!;
    expect(result['value'], 14.2);
    expect(result['experimental'], false);
    expect(result['chart_key'], 'resp_rate');
    expect(result.containsKey('label'), false);
  });
  test(
    'missing/withheld/nightly-invalid data never plots a breathing curve',
    () {
      expect(respiratoryDisplayMetric({}), isNull);
      expect(experimentalRespiratoryCurve({}), isEmpty);
      expect(
        experimentalRespiratoryCurve({
          'respiration': {
            'experimental': {
              'value': {
                'brpm': null,
                'windows': [
                  {'brpm': 12.5, 'start_sec': 150, 'end_sec': 450},
                ],
              },
            },
          },
        }),
        isEmpty,
      );
      final curve = experimentalRespiratoryCurve({
        'respiration': {
          'experimental': {
            'value': {
              'brpm': 12.5,
              'windows': [
                {'brpm': 12.5, 'start_sec': 150, 'end_sec': 450},
                {'brpm': null, 'start_sec': 300, 'end_sec': 600},
              ],
            },
          },
        },
      });
      expect(curve, [
        {'t': 300, 'v': 12.5},
      ]);
    },
  );
}
