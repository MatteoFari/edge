// WH-02 — the (cycle index, cycle day) assignment.
//
// `getCycle` numbers every derived day against the LAST logged start, so a
// night from two cycles ago came back as "cycle day 70" and nothing but the
// newest cycle could ever be drawn. These are the three cases that fix has to
// get right, and they are the only reason WH-02, WH-03 and WH-08 can talk
// about "the same day of a different cycle" at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/cycle_screen.dart';

CycleData _data(List<String> starts, Map<String, double> rhrByDate) =>
    CycleData(
      enabled: true,
      logs: [
        for (final s in starts) {'date': s, 'kind': 'start'},
      ],
      overlay: [
        for (final e in rhrByDate.entries)
          {'date': e.key, 'resting_hr': e.value},
      ],
    );

void main() {
  group('byCycleDay', () {
    test('a day is placed against the start that preceded it', () {
      final d = _data(
        ['2026-01-01', '2026-02-01', '2026-03-01'],
        {
          '2026-01-03': 50, // cycle 0, day 3
          '2026-02-03': 51, // cycle 1, day 3
          '2026-03-03': 52, // cycle 2, day 3
        },
      );
      final byDay = byCycleDay(d, 'resting_hr');
      // One entry for day 3, holding all three cycles — NOT day 3, day 34 and
      // day 62, which is what counting from the last start produced.
      expect(byDay.keys.toList(), [3]);
      expect(byDay[3]!.keys.toSet(), {0, 1, 2});
      expect(byDay[3]!.values.toList()..sort(), [50, 51, 52]);
    });

    test('a day before the first logged start is dropped, never numbered', () {
      final d = _data(['2026-02-01'], {'2026-01-15': 50, '2026-02-05': 51});
      final byDay = byCycleDay(d, 'resting_hr');
      expect(byDay.keys.toList(), [5]);
    });

    test('the open cycle keeps counting past the longest closed one', () {
      final d = _data(['2026-01-01', '2026-01-29'], {'2026-03-01': 50});
      // 2026-01-29 + 31 days. Nothing clamps it to a cycle length we have not
      // measured yet.
      expect(byCycleDay(d, 'resting_hr').keys.toList(), [32]);
    });

    test('a non-finite or missing value never becomes a point', () {
      final d = CycleData(
        enabled: true,
        logs: const [
          {'date': '2026-01-01', 'kind': 'start'},
        ],
        overlay: const [
          {'date': '2026-01-02', 'resting_hr': null},
          {'date': '2026-01-03', 'resting_hr': double.nan},
          {'date': '2026-01-04', 'resting_hr': 50.0},
        ],
      );
      expect(byCycleDay(d, 'resting_hr').keys.toList(), [4]);
    });
  });

  group('cycleGaps', () {
    test('consecutive gaps, oldest first — one fewer than the starts', () {
      final gaps = cycleGaps(
        startDates(_data(['2026-01-01', '2026-01-29', '2026-03-01'], const {})),
      );
      expect(gaps, [28, 31]);
    });

    test('a single logged start has no measured gap at all', () {
      expect(cycleGaps(startDates(_data(['2026-01-01'], const {}))), isEmpty);
    });

    test('starts logged out of order still difference in date order', () {
      final gaps = cycleGaps(
        startDates(_data(['2026-03-01', '2026-01-01', '2026-01-29'], const {})),
      );
      expect(gaps, [28, 31]);
    });
  });

  _mdc();

  _screen();
}

// ── WH-02 · the MDC gate ────────────────────────────────────────────────────
//
// The chart's whole visual claim is "this cycle day differs from that one".
// The only number that backs it is her own minimal detectable change, and the
// common case is that the swing across the drawn days is smaller than it.

void _mdc() {
  CycleData withRhr(List<double> values) => CycleData(
    enabled: true,
    logs: const [
      {'date': '2026-01-01', 'kind': 'start'},
    ],
    overlay: [
      for (var i = 0; i < values.length; i++)
        {
          'date': DateTime(
            2026,
            1,
            2,
          ).add(Duration(days: i)).toIso8601String().substring(0, 10),
          'resting_hr': values[i],
        },
    ],
  );

  group('cycleDayNoise', () {
    test('a series with no spread at all yields no MDC — never a zero '
        'threshold that would call every wobble a finding', () {
      expect(
        cycleDayNoise(withRhr(const [52, 52, 52, 52, 52]), 'resting_hr'),
        isNull,
      );
    });

    test('too few nights to estimate a spread yields no MDC', () {
      expect(cycleDayNoise(withRhr(const [52, 55]), 'resting_hr'), isNull);
    });

    test('a real spread yields an MDC well above it — 1.96·root-2·MAD', () {
      final n = cycleDayNoise(
        withRhr(const [50, 52, 54, 56, 58, 52, 54]),
        'resting_hr',
      );
      expect(n, isNotNull);
      expect(n!, greaterThan(2));
    });

    test('a key the overlay does not carry is absent, not zero', () {
      expect(cycleDayNoise(withRhr(const [50, 54, 58]), 'hrv_rmssd'), isNull);
    });
  });
}

// ── the screen the three items live on ──────────────────────────────────────

CycleData _threeCycles() {
  final start = DateTime(2026, 1, 1);
  final starts = [
    for (var i = 0; i < 4; i++) start.add(Duration(days: 28 * i)),
  ];
  String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return CycleData(
    enabled: true,
    cycleDay: 8,
    logs: [
      for (final s in starts) {'date': ymd(s), 'kind': 'start'},
    ],
    overlay: [
      for (var i = 0; i < 92; i++)
        {
          'date': ymd(start.add(Duration(days: i))),
          // Cheap deterministic wobble; the point is that every cycle day has
          // several cycles behind it, not what the numbers mean.
          'resting_hr': 52.0 + (i % 28) * 0.2 + (i ~/ 28),
          'hrv_rmssd': 60.0 - (i % 28) * 0.4 + (i ~/ 28),
          'cycle_day': (i % 28) + 1,
        },
    ],
  );
}

void _screen() {
  group('across your cycles', () {
    testWidgets('opens from the tab and builds with no store above it', (
      t,
    ) async {
      await t.pumpWidget(
        ChangeNotifierProvider(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.light, Brightness.light),
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: [CycleTab(data: _threeCycles())]),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Across your cycles'), findsOneWidget);
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();

      // All three land, and WH-08 asks before it draws anything.
      expect(find.text('By day of your cycle'), findsOneWidget);
      // WH-08 sits below the fold on a phone-sized viewport.
      await t.dragUntilVisible(
        find.text('Your cycle lengths against a published range'),
        find.byType(ListView).last,
        const Offset(0, -200),
      );
      await t.pumpAndSettle();
      expect(find.text('How long your cycles have been'), findsOneWidget);

      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .toList();

      // NEVER a bare dash, anywhere on it.
      expect(texts.where((s) => s.trim() == '\u2014'), isEmpty);

      // NO STAGE VOCABULARY. Not in a string, not in a label, not ever.
      final words = texts.join(' ').toLowerCase();
      for (final banned in const [
        'menopaus',
        'perimenopaus',
        'transition',
        'straw',
        'ovarian insufficiency',
      ]) {
        expect(words.contains(banned), isFalse, reason: 'said "$banned"');
      }

      // AND NO VERDICT on the lengths. Nothing tells her whether her own
      // cycles meet the criterion; the chart shows it and stops.
      for (final verdict in const [
        'irregular',
        'abnormal',
        'normal for you',
        'outside the range',
        'within the range',
      ]) {
        expect(words.contains(verdict), isFalse, reason: 'said "$verdict"');
      }
    });
  });
}
