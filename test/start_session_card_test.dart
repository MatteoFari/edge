import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ui2/screens/start_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

// The shared entry card is exercised at a phone width in its real scrolling
// parent. Large text must grow the card without losing the action or its copy.
void main() {
  const workout = StartCard(
    label: 'START A SESSION',
    count: 71,
    noun: 'activities',
    icon: LucideIcons.dumbbell,
    actionLabel: 'Choose activity',
    accent: C.domMove,
  );

  Future<void> pump(
    WidgetTester t, {
    double scale = 1,
    double width = 390,
    double pad = S.x4,
    InterfaceStyle style = InterfaceStyle.expressive,
    Brightness brightness = Brightness.light,
    ExpressivePalette palette = ExpressivePalette.edge,
    Widget card = workout,
  }) async {
    t.view.physicalSize = Size(width, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(brightness, style: style, palette: palette),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            padding: EdgeInsets.symmetric(horizontal: pad),
            children: [card, const Text('Next card')],
          ),
        ),
      ),
    );
  }

  testWidgets('count and action are readable without an illustration', (
    t,
  ) async {
    await pump(t);
    expect(find.text('71 activities'), findsOneWidget);
    expect(find.textContaining(r'$count'), findsNothing);
    expect(find.text('Pick one and go'), findsOneWidget);
    expect(find.text('Choose activity'), findsOneWidget);
    expect(find.byIcon(LucideIcons.dumbbell), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('the parent owns the shared card inset', (t) async {
    await pump(t);
    expect(t.getRect(find.byType(StartCard)).left, S.x4);
    expect(t.getSize(find.byType(StartCard)).width, 390 - S.x4 * 2);
    await pump(t, pad: 0);
    expect(t.getSize(find.byType(StartCard)).width, 390);
    expect(t.takeException(), isNull);
  });

  for (final style in InterfaceStyle.values) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0, 3.1]) {
        testWidgets(
          '${style.name}, ${brightness.name}: scrolling card at ${scale}x text',
          (t) async {
            await pump(t, style: style, brightness: brightness, scale: scale);
            expect(t.takeException(), isNull);
            final bounds = t.getRect(find.byType(StartCard));
            final play = t.getRect(find.byIcon(LucideIcons.play));
            expect(bounds.contains(play.topLeft), isTrue);
            expect(bounds.contains(play.bottomRight), isTrue);
            for (final copy in [
              'START A SESSION',
              '71 activities',
              'Pick one and go',
              'Choose activity',
            ]) {
              final text = t.widget<Text>(find.text(copy));
              expect(
                text.maxLines,
                isNull,
                reason: '$copy must be free to wrap',
              );
              expect(text.overflow, isNot(TextOverflow.ellipsis));
            }
            await t.scrollUntilVisible(find.text('Next card'), S.x16);
            expect(
              t.getTopLeft(find.text('Next card')).dy,
              greaterThanOrEqualTo(t.getRect(find.byType(StartCard)).bottom),
            );
          },
        );
      }
    }
  }

  for (final palette in ExpressivePalette.values) {
    for (final brightness in Brightness.values) {
      testWidgets('${palette.name}, ${brightness.name}: tonal palette roles', (
        t,
      ) async {
        await pump(t, palette: palette, brightness: brightness);
        final context = t.element(find.byType(StartCard));
        final p = P.of(context);
        expect(t.widget<Surface>(find.byType(Surface)).color, p.card2);
        expect(t.widget<Surface>(find.byType(Surface)).elevation, 0);
        final play = t.widget<Icon>(find.byIcon(LucideIcons.play));
        expect(play.color, p.inkOnFill);
        expect(
          P.contrast(p.fill(C.domMove), play.color!),
          greaterThanOrEqualTo(4.5),
        );
        expect(t.takeException(), isNull);
      });
    }
  }

  testWidgets('long localized copy grows on a narrow phone', (t) async {
    await pump(
      t,
      width: 320,
      scale: 3.1,
      card: const StartCard(
        label: 'EINE TRAININGSEINHEIT STARTEN',
        count: 71,
        noun: 'Aktivitäten',
        sub: 'Wähle eine Aktivität aus und starte deine Trainingseinheit',
        icon: LucideIcons.dumbbell,
        actionLabel: 'Aktivität auswählen',
        accent: C.domMove,
      ),
    );
    expect(t.takeException(), isNull);
    expect(find.text('Aktivität auswählen'), findsOneWidget);
  });

  testWidgets('the card and filled action share one accessible tap target', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    var starts = 0;
    await pump(
      t,
      card: StartCard(
        label: 'START A SESSION',
        count: 71,
        noun: 'activities',
        icon: LucideIcons.dumbbell,
        actionLabel: 'Choose activity',
        accent: C.domMove,
        onTap: () => starts++,
      ),
    );
    expect(find.byType(Pressable), findsOneWidget);
    expect(
      t.getSemantics(find.byType(Pressable)),
      matchesSemantics(
        label:
            'START A SESSION. 71 activities. Pick one and go. Choose activity',
        isButton: true,
        hasTapAction: true,
      ),
    );
    await t.tap(find.text('Choose activity'));
    await t.pump();
    expect(starts, 1);
    await t.tap(find.text('71 activities'));
    await t.pump();
    expect(starts, 2);
    expect(t.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('wellness uses its icon, count and recorded last session', (
    t,
  ) async {
    await pump(
      t,
      card: const StartCard(
        label: 'START A SITTING',
        count: 4,
        noun: 'exercises',
        sub: 'Last: 5 min',
        icon: LucideIcons.wind,
        actionLabel: 'Begin',
        accent: C.domMind,
      ),
    );
    expect(find.text('4 exercises'), findsOneWidget);
    expect(find.text('Last: 5 min'), findsOneWidget);
    expect(find.text('Begin'), findsOneWidget);
    expect(find.byIcon(LucideIcons.wind), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(t.takeException(), isNull);
  });
}
