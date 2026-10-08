import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _end = '2026-10-28';
const _data = ReadinessData(
  day: _end,
  historyEnd: _end,
  readiness: Metric(value: 73),
  series: [null, null, 40.5, null, 61.2, 73],
);
final _chart = find.byKey(const ValueKey('recovery-history-scrubber'));
final _reading = find.byKey(const ValueKey('recovery-history-reading'));

Future<void> _open(
  WidgetTester t, {
  ReadinessData data = _data,
  double scale = 1,
  bool reduced = false,
  Brightness brightness = Brightness.light,
}) async {
  t.view.physicalSize = const Size(320, 780);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(brightness),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduced,
        ),
        child: child!,
      ),
      home: ReadinessDetail(data: data),
    ),
  );
  await t.pumpAndSettle();
  if (_chart.evaluate().isNotEmpty) {
    await t.ensureVisible(_chart);
    await t.pumpAndSettle();
  }
}

Offset _at(WidgetTester t, double position) {
  final box = t.getRect(_chart);
  return Offset(
    box.left + (box.width * position).clamp(1, box.width - 1),
    box.center.dy,
  );
}

void main() {
  testWidgets('tap and hold inspect calendar dates, scores and gaps', (
    t,
  ) async {
    await _open(t);
    expect(_reading, findsNothing);
    await t.tapAt(_at(t, 0));
    await t.pump();
    expect(t.widget<Text>(_reading).data, 'Sunday, 25 October, 40.5 /100');
    await t.tapAt(_at(t, 1 / 3));
    await t.pump();
    expect(t.widget<Text>(_reading).data, 'Monday, 26 October, no record');
    final hold = await t.startGesture(_at(t, 2 / 3));
    await t.pump(const Duration(milliseconds: 600));
    expect(t.widget<Text>(_reading).data, 'Tuesday, 27 October, 61.2 /100');
    await hold.moveTo(_at(t, 1));
    await t.pump();
    await hold.up();
    expect(t.widget<Text>(_reading).data, 'Wednesday, 28 October, 73 /100');
    final painter = t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<LineChart>()
        .single;
    expect(painter.selectedX, 1);
    expect(painter.axis!.min, 0);
    expect(painter.axis!.max, 100);
    expect(t.takeException(), isNull);
  });

  testWidgets('accessibility steps one calendar day, including gaps', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    await _open(t);
    final node = t.getSemantics(_chart);
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await t.pump();
    expect(t.getSemantics(_chart).value, 'Sunday, 25 October, 40.5 /100');
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await t.pump();
    expect(t.getSemantics(_chart).value, 'Monday, 26 October, no record');
    semantics.dispose();
  });

  testWidgets('a single scored day remains selectable', (t) async {
    await _open(
      t,
      data: const ReadinessData(
        day: _end,
        historyEnd: _end,
        series: [null, 67],
      ),
    );
    await t.tapAt(_at(t, .5));
    await t.pump();
    expect(t.widget<Text>(_reading).data, 'Wednesday, 28 October, 67 /100');
    expect(t.takeException(), isNull);
  });

  testWidgets('missing and non-finite scores do not create a chart', (t) async {
    await _open(
      t,
      data: const ReadinessData(
        day: _end,
        series: [null, double.nan, double.infinity],
      ),
    );
    expect(_chart, findsNothing);
    expect(find.text('No readiness history'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('selection stays readable at large text in $brightness', (
      t,
    ) async {
      await _open(t, scale: 2, reduced: true, brightness: brightness);
      await t.tapAt(_at(t, 1));
      await t.pumpAndSettle();
      await t.ensureVisible(_reading);
      await t.pumpAndSettle();
      expect(t.widget<Text>(_reading).data, 'Wednesday, 28 October, 73 /100');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('scrolling past the chart does not select a score', (t) async {
    await _open(t);
    await t.dragFrom(_at(t, .5), const Offset(0, -80));
    await t.pumpAndSettle();
    expect(_reading, findsNothing);
  });
}
