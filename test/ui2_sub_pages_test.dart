import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Tabs extends StatefulWidget {
  const _Tabs();
  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  int index = 0, count = 4;
  void select(int i) => setState(() => index = i);
  void removeLast() => setState(() {
    count--;
    index = index.clamp(0, count - 1);
  });

  @override
  Widget build(BuildContext c) => Column(
    children: [
      SubTabs([for (var i = 0; i < count; i++) 'Page $i'], index, select),
      Expanded(
        child: SubPages(
          index: index,
          count: count,
          onChanged: select,
          builder: (c, i) => ListView(
            key: PageStorageKey('page-$i'),
            children: [
              TextField(key: ValueKey('draft-$i')),
              SizedBox(
                height: 80,
                child: ListView(
                  key: ValueKey('horizontal-$i'),
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var n = 0; n < 15; n++)
                      SizedBox(width: 100, child: Text('Tile $n')),
                  ],
                ),
              ),
              for (var n = 0; n < 30; n++)
                SizedBox(height: 80, child: Text('$i / $n')),
            ],
          ),
        ),
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester t, {
  TextDirection direction = TextDirection.ltr,
}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, style: InterfaceStyle.expressive),
      builder: (c, child) =>
          Directionality(textDirection: direction, child: child!),
      home: const Scaffold(body: _Tabs()),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _swipe(WidgetTester t, double dx) async {
  await t.drag(find.byType(PageView), Offset(dx, 0));
  await t.pumpAndSettle();
}

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('swipes, chip taps and bounds agree in $direction', (t) async {
      await _pump(t, direction: direction);
      final forward = direction == TextDirection.ltr ? -600.0 : 600.0;
      for (var i = 1; i < 4; i++) {
        await _swipe(t, forward);
        expect(t.widget<SubTabs>(find.byType(SubTabs)).index, i);
      }
      await _swipe(t, forward);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 3);
      await t.ensureVisible(find.text('Page 0'));
      await t.tap(find.text('Page 0'));
      await t.pumpAndSettle();
      expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 0);
      await _swipe(t, -forward);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 0);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('visited tabs retain drafts and their own vertical position', (
    t,
  ) async {
    await _pump(t);
    await t.enterText(find.byKey(const ValueKey('draft-0')), 'Keep this draft');
    t.testTextInput.hide();
    await t.drag(
      find.byKey(const PageStorageKey('page-0')),
      const Offset(0, -400),
    );
    await t.pumpAndSettle();
    final scroll = t
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const PageStorageKey('page-0')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    final before = scroll.pixels;
    await _swipe(t, -600);
    await _swipe(t, 600);
    expect(scroll.pixels, before);
    await t.drag(
      find.byKey(const PageStorageKey('page-0')),
      const Offset(0, 1000),
    );
    await t.pumpAndSettle();
    expect(
      t.widget<EditableText>(find.byType(EditableText).first).controller.text,
      'Keep this draft',
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('horizontal content and chip scrolling do not switch pages', (
    t,
  ) async {
    await _pump(t);
    await t.drag(
      find.byKey(const ValueKey('horizontal-0')),
      const Offset(-400, 0),
    );
    await t.pumpAndSettle();
    expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 0);
    await t.drag(find.byType(SubTabs), const Offset(-400, 0));
    await t.pumpAndSettle();
    expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 0);
  });

  testWidgets(
    'external requests and removing the selected optional tab stay in sync',
    (t) async {
      await _pump(t);
      final state = t.state<_TabsState>(find.byType(_Tabs));
      state.select(3);
      await t.pumpAndSettle();
      state.removeLast();
      await t.pumpAndSettle();
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 2);
      expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 2);
      state.select(0);
      state.select(1);
      await t.pumpAndSettle();
      expect(t.widget<PageView>(find.byType(PageView)).controller!.page, 1);
      await _swipe(t, 600);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 0);
      expect(t.takeException(), isNull);
    },
  );
}
