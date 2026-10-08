import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _day = '2026-08-12';
final _start = localDayStartSec(_day)!;

DayGraph _graph({bool gap = false}) => dayGraph({
  'date': _day,
  'day_start': _start,
  'hr': [
    for (var minute = 0; minute < 1440; minute++)
      if (!gap || minute < 600 || minute >= 840)
        {'t': _start + minute * 60, 'v': minute == 720 ? 88 : 60 + minute % 20},
  ],
});

Widget _frame(
  DayGraph graph, {
  bool reduced = false,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) => ChangeNotifierProvider(
  create: (_) => ThemeController.seed(
    brightness == Brightness.dark ? AppThemeChoice.dark : AppThemeChoice.light,
    brightness,
    interfaceStyle: InterfaceStyle.expressive,
  ),
  child: MaterialApp(
    theme: buildTheme(
      brightness,
      style: InterfaceStyle.expressive,
    ).copyWith(platform: TargetPlatform.android),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(
        disableAnimations: reduced,
        textScaler: TextScaler.linear(scale),
      ),
      child: child!,
    ),
    home: Builder(
      builder: (c) => Scaffold(
        body: ListView(
          children: [?dayGraphCard(c, graph, day: _day)],
        ),
      ),
    ),
  ),
);

Finder _scrubber([bool expanded = false]) => find.byKey(
  ValueKey(expanded ? 'day-hr-detail-scrubber' : 'day-hr-scrubber'),
);
Finder _pan() => find.byKey(const ValueKey('day-hr-detail-pan'));
Finder _reading() => find.byKey(const ValueKey('day-hr-reading'));

Offset _at(WidgetTester t, int minute, {bool expanded = false}) {
  final rect = t.getRect(_scrubber(expanded));
  return Offset(rect.left + rect.width * minute / 1439, rect.center.dy);
}

Future<void> _size(WidgetTester t, {double height = 900}) async {
  t.view.physicalSize = Size(390, height);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Future<void> _expand(WidgetTester t) async {
  await t.ensureVisible(find.byKey(const ValueKey('day-hr-expand')));
  await t.tap(find.byKey(const ValueKey('day-hr-expand')));
  await t.pump();
  await t.pumpAndSettle();
}

void main() {
  setUp(() => ClockFormatController.seed(ClockFormat.h24));
  tearDown(ClockFormatController.debugReset);

  test(
    'an explicit day without a bundle never acquires another day\'s graph',
    () {
      expect(dayForTimeline(['2026-08-11'], want: _day), _day);
      expect(dayForTimeline(const [], want: _day), _day);
      expect(dayForTimeline(['2026-08-11'], prefer: _day), '2026-08-11');
      expect(dayForTimeline([_day, '2026-08-11']), _day);
      expect(dayForTimeline(const []), isNull);
    },
  );
  test('touch stays on an unavailable minute instead of crossing a gap', () {
    final g = _graph(gap: true);
    final slot = g.slotAt(720 / 1439);
    expect(slot, 720);
    expect(g.readingAt(slot), isNull);
    expect(g.timeAt(slot), _start + 720 * 60);
    expect(g.nextReading(slot, -1), 599);
    expect(g.nextReading(slot, 1), 840);
    expect(g.nextReading(null, 1), 0);
    expect(g.nextReading(1439, 1), isNull);
    expect(g.nextReading(0, -1), isNull);
  });

  test('invalid HR and records just before midnight are never selectable', () {
    final g = dayGraph({
      'date': _day,
      'day_start': _start,
      'hr': [
        {'t': _start - 1, 'v': 99},
        {'t': _start + 60, 'v': double.nan},
        {'t': _start + 120, 'v': double.infinity},
        {'t': _start + 180, 'v': 0},
        {'t': _start + 245, 'v': 72},
      ],
    });
    expect(g.nextReading(null, 1), 4);
    expect(g.timeAt(4), _start + 245);
    expect(g.readingAt(0), isNull);
    expect(g.readingAt(1), isNull);
    expect(g.readingAt(2), isNull);
    expect(g.readingAt(3), isNull);
    expect(g.readingAt(-1), isNull);
    expect(g.readingAt(1440), isNull);
  });

  for (final hours in [23, 25]) {
    test('$hours-hour DST day retains its last sample and local clock', () {
      DateTime? found;
      for (
        var d = DateTime(2026, 1, 1);
        d.year == 2026;
        d = DateTime(d.year, d.month, d.day + 1)
      ) {
        if (DateTime(d.year, d.month, d.day + 1).difference(d).inHours ==
            hours) {
          found = d;
          break;
        }
      }
      if (found == null) {
        markTestSkipped('No $hours-hour DST day in this process timezone');
        return;
      }
      final day = dayLabelOf(found);
      final start = localDayStartSec(day)!;
      final end = localDayEndSec(day)!;
      final last = end - 60;
      final g = dayGraph({
        'date': day,
        'day_start': start,
        'hr': [
          {'t': start, 'v': 61},
          {'t': last, 'v': 79},
          {'t': end, 'v': 101},
        ],
      });
      expect(g.slots, hours * 60);
      expect(g.slotAt(1), hours * 60 - 1);
      expect(g.readingAt(g.slotAt(1)), 79);
      expect(g.timeAt(g.slotAt(1)), last);
      final local = DateTime.fromMillisecondsSinceEpoch(
        g.timeAt(g.slotAt(1))! * 1000,
      );
      expect(dayLabelOf(local), day);
      expect((local.hour, local.minute), (23, 59));
      expect(g.readingAt(60), isNull);
    });
  }

  testWidgets('tap reports minute average with local time and gaps abstain', (
    t,
  ) async {
    await _size(t);
    await t.pumpWidget(_frame(_graph()));
    await t.pumpAndSettle();
    await t.tapAt(_at(t, 720));
    await t.pumpAndSettle();
    expect(
      t.widget<Text>(_reading()).data,
      '88 bpm at 12:00 · Average for this minute',
    );

    await t.pumpWidget(_frame(_graph(gap: true)));
    await t.pumpAndSettle();
    expect(
      _reading(),
      findsNothing,
    ); // A replacement day/source clears selection.
    await t.tapAt(_at(t, 720));
    await t.pumpAndSettle();
    expect(
      t.widget<Text>(_reading()).data,
      '12:00 · No heart-rate reading in this minute',
    );
  });

  testWidgets('holding follows measured points without panning', (t) async {
    await _size(t);
    await t.pumpWidget(_frame(_graph()));
    await t.pumpAndSettle();
    final gesture = await t.startGesture(_at(t, 720));
    await t.pump(const Duration(milliseconds: 600));
    expect(t.widget<Text>(_reading()).data, contains('88 bpm at 12:00'));
    await gesture.moveTo(_at(t, 780));
    await t.pump();
    expect(t.widget<Text>(_reading()).data, contains('60 bpm at 13:00'));
    await gesture.up();
    await t.pumpAndSettle();
  });

  testWidgets('expansion keeps selected day/point and uses the shared morph', (
    t,
  ) async {
    await _size(t);
    final semantics = t.ensureSemantics();
    await t.pumpWidget(_frame(_graph()));
    await t.pumpAndSettle();
    final expand = find.byKey(const ValueKey('day-hr-expand'));
    expect(find.bySemanticsLabel('Expand graph'), findsOneWidget);
    expect(t.getRect(expand).bottom, lessThan(t.getRect(_scrubber()).top));
    expect(
      t.getRect(expand).center.dx,
      greaterThan(t.getRect(_scrubber()).center.dx),
    );
    expect(find.bySemanticsLabel('Previous reading'), findsNothing);
    expect(find.bySemanticsLabel('Next reading'), findsNothing);
    await t.tapAt(_at(t, 720));
    await t.pumpAndSettle();
    final compactHeight = t.getSize(_scrubber()).height;
    await t.tap(find.byKey(const ValueKey('day-hr-expand')));
    await t.pump();
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('detail-morph-surface')), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.text('Wednesday, 12 August'), findsOneWidget);
    expect(t.widget<Text>(_reading()).data, contains('88 bpm at 12:00'));
    expect(t.getSize(_scrubber(true)).height, greaterThan(compactHeight));
    final controller = t.widget<SingleChildScrollView>(_pan()).controller!;
    final before = controller.offset;
    final gesture = await t.startGesture(_at(t, 720, expanded: true));
    await t.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(_at(t, 780, expanded: true));
    await t.pump();
    expect(t.widget<Text>(_reading()).data, contains('60 bpm at 13:00'));
    expect(controller.offset, before);
    await gesture.up();
    await t.pumpAndSettle();
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(t.widget<Text>(_reading()).data, contains('88 bpm at 12:00'));
    semantics.dispose();
  });

  testWidgets(
    'zoomed swipes pan, taps inspect, and Full day resets the range',
    (t) async {
      await _size(t);
      await t.pumpWidget(_frame(_graph(), reduced: true));
      await t.pumpAndSettle();
      await _expand(t);
      final pan = t.widget<SingleChildScrollView>(_pan());
      final controller = pan.controller!;
      expect(controller.position.maxScrollExtent, greaterThan(0));
      expect(
        t.widget<ChartFrame>(find.byType(ChartFrame)).series.length,
        lessThan(1440),
      ); // Spoken summary follows the visible time range.
      expect(find.byKey(const ValueKey('detail-morph-surface')), findsNothing);
      final before = controller.offset;
      await t.dragFrom(t.getRect(_pan()).center, const Offset(-120, 0));
      await t.pumpAndSettle();
      expect(controller.offset, greaterThan(before));
      expect(
        _reading(),
        findsNothing,
      ); // A normal swipe moves, it does not select.

      await t.tapAt(t.getRect(_pan()).center);
      await t.pumpAndSettle();
      expect(t.widget<Text>(_reading()).data, contains('bpm at'));
      final width = t.getSize(_scrubber(true)).width;
      await t.tap(find.byKey(const ValueKey('day-hr-zoom-in')));
      await t.pumpAndSettle();
      expect(t.getSize(_scrubber(true)).width, closeTo(width * 2, .1));
      await t.tap(find.text('Full day'));
      await t.pumpAndSettle();
      expect(controller.position.maxScrollExtent, 0);
      expect(find.text('Midnight'), findsNWidgets(2));
      expect(find.text('Noon'), findsOneWidget);
    },
  );

  testWidgets(
    'screen-reader minute steps remain accessible without arrow buttons',
    (t) async {
      await _size(t);
      final semantics = t.ensureSemantics();
      await t.pumpWidget(_frame(_graph(gap: true), reduced: true));
      await t.pumpAndSettle();
      final node = t.getSemantics(_scrubber());
      t.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.increase,
          viewId: t.view.viewId,
          nodeId: node.id,
        ),
      );
      await t.pump();
      expect(t.widget<Text>(_reading()).data, contains('60 bpm at 00:00'));
      t.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.increase,
          viewId: t.view.viewId,
          nodeId: node.id,
        ),
      );
      await t.pump();
      expect(t.widget<Text>(_reading()).data, contains('61 bpm at 00:01'));
      t.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.increase,
          viewId: t.view.viewId,
          nodeId: node.id,
        ),
      );
      await t.pump();
      expect(t.widget<Text>(_reading()).data, contains('62 bpm at 00:02'));
      t.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.decrease,
          viewId: t.view.viewId,
          nodeId: node.id,
        ),
      );
      await t.pump();
      expect(t.widget<Text>(_reading()).data, contains('61 bpm at 00:01'));
      semantics.dispose();
    },
  );

  testWidgets(
    'expanded controls and readout fit large text and dark palettes',
    (t) async {
      await _size(t, height: 2200);
      await t.pumpWidget(
        _frame(
          _graph(gap: true),
          scale: 3.1,
          reduced: true,
          brightness: Brightness.dark,
        ),
      );
      await t.pumpAndSettle();
      await _expand(t);
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const ValueKey('day-hr-zoom-in')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
}
