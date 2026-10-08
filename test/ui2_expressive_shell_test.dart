import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _frame(
  Widget home, {
  InterfaceStyle style = InterfaceStyle.expressive,
  Locale locale = const Locale('en'),
  double scale = 1,
  bool reduceMotion = false,
  double bottomInset = 0,
  TextDirection? direction,
}) => MaterialApp(
  theme: buildTheme(Brightness.light, style: style),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (c, child) => MediaQuery(
    data: MediaQuery.of(c).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduceMotion,
      padding: MediaQuery.of(c).padding.copyWith(bottom: bottomInset),
    ),
    child: direction == null
        ? child!
        : Directionality(textDirection: direction, child: child!),
  ),
  home: home,
);

class _CounterPage extends StatefulWidget {
  final ShellDomain domain;
  final Map<ShellDomain, int> mounts;
  const _CounterPage(this.domain, this.mounts);

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int count = 0;

  @override
  void initState() {
    super.initState();
    widget.mounts.update(widget.domain, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext c) => Center(
    child: Pressable(
      onTap: () => setState(() => count++),
      semanticLabel: 'Count ${widget.domain.name}',
      child: Text('${widget.domain.name}: $count'),
    ),
  );
}

Finder get _navigation => find.byKey(const ValueKey('expressive-navigation'));

Finder _tabTarget(ShellDomain domain) => find.ancestor(
  of: find.byKey(ValueKey('expressive-tab-${domain.name}')),
  matching: find.byType(Pressable),
);

void _expectBoundedNavigation(WidgetTester t) {
  final inner = t.getRect(_navigation).deflate(S.x1);
  final targets = t
      .widgetList<Pressable>(
        find.descendant(of: _navigation, matching: find.byType(Pressable)),
      )
      .toList();
  expect(targets, hasLength(4));
  final rects = [for (final target in targets) t.getRect(find.byWidget(target))]
    ..sort((a, b) => a.left.compareTo(b.left));
  var totalWidth = 0.0;
  for (var i = 0; i < rects.length; i++) {
    final rect = rects[i];
    expect(rect.width, greaterThanOrEqualTo(S.tap - .001));
    expect(rect.height, greaterThanOrEqualTo(S.tap - .001));
    expect(rect.left, greaterThanOrEqualTo(inner.left - .001));
    expect(rect.right, lessThanOrEqualTo(inner.right + .001));
    if (i > 0) expect(rect.left, closeTo(rects[i - 1].right, .001));
    totalWidth += rect.width;
  }
  expect(totalWidth, closeTo(inner.width, .001));
  final capsule = t.getRect(
    find.byKey(const ValueKey('expressive-selected-capsule')),
  );
  expect(capsule.left, greaterThanOrEqualTo(inner.left - .001));
  expect(capsule.right, lessThanOrEqualTo(inner.right + .001));
  expect(capsule.top, greaterThanOrEqualTo(inner.top - .001));
  expect(capsule.bottom, lessThanOrEqualTo(inner.bottom + .001));
  expect(capsule.width, greaterThanOrEqualTo(S.tap - .001));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Android uses bundled Manrope for F.over. Real glyph advances make the
    // default-size no-truncation assertion meaningful instead of testing Ahem.
    for (final family in ['.SF Pro Text', 'Manrope']) {
      final loader = FontLoader(family);
      loader.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-500.ttf'));
      await loader.load();
    }
  });

  test('hiding Nutrition preserves stored domain indices', () {
    expect(ShellDomain.values, [
      ShellDomain.home,
      ShellDomain.health,
      ShellDomain.nutrition,
      ShellDomain.workout,
      ShellDomain.wellness,
    ]);
    expect(ShellDomain.nutrition.index, 2);
    expect(ShellDomain.workout.index, 3);
    expect(ShellDomain.wellness.index, 4);
    expect(visibleShellDomains, [
      ShellDomain.home,
      ShellDomain.health,
      ShellDomain.workout,
      ShellDomain.wellness,
    ]);
  });

  for (final style in InterfaceStyle.values) {
    testWidgets('${style.name}: a saved Nutrition tab opens Home safely', (
      t,
    ) async {
      final mounts = <ShellDomain, int>{};
      await t.pumpWidget(
        _frame(
          AppShell(
            initial: ShellDomain.nutrition,
            builder: (c, d) => _CounterPage(d, mounts),
          ),
          style: style,
        ),
      );
      await t.pumpAndSettle();
      expect(mounts, {ShellDomain.home: 1});
      expect(find.text('home: 0'), findsOneWidget);
      expect(find.text('Nutrition'), findsNothing);
      expect(t.widget<IndexedStack>(find.byType(IndexedStack)).index, 0);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets(
    'Original shows four tabs with its existing icon-only highlights',
    (t) async {
      await t.pumpWidget(
        _frame(
          AppShell(builder: (c, d) => const SizedBox.shrink()),
          style: InterfaceStyle.original,
        ),
      );
      expect(find.byKey(const ValueKey('expressive-navigation')), findsNothing);
      expect(visibleShellDomains, hasLength(4));
      expect(find.text('Nutrition'), findsNothing);
      for (final d in visibleShellDomains) {
        expect(find.text(d.label), findsOneWidget);
        expect(t.widget<Icon>(find.byIcon(d.icon)).size, 20);
      }
      final highlights = t
          .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
          .toList();
      expect(highlights, hasLength(4));
      expect(highlights.first.child, isA<Icon>());
    },
  );

  testWidgets('Expressive floats over content with a compact raised capsule', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      _frame(AppShell(builder: (c, d) => const SizedBox.expand())),
    );
    expect(t.widget<Scaffold>(find.byType(Scaffold)).extendBody, isTrue);
    final content = t.getRect(find.byType(IndexedStack));
    final nav = t.getRect(_navigation);
    expect(content.bottom, greaterThan(nav.bottom));
    expect(nav.width, closeTo(390 - S.x12 * 2, .001));
    expect(nav.center.dx, closeTo(390 / 2, .001));
    final decoration =
        t.widget<Container>(_navigation).decoration! as BoxDecoration;
    expect(decoration.boxShadow, isNotEmpty);
    _expectBoundedNavigation(t);
  });

  testWidgets(
    'floating navigation clears the final action and workout banner',
    (t) async {
      t.view.physicalSize = const Size(390, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      for (final banner in [false, true]) {
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpWidget(
          _frame(
            AppShell(
              banner: banner
                  ? const SizedBox(height: S.x10, child: Text('Active workout'))
                  : null,
              builder: (c, d) => Builder(
                builder: (c) => ListView(
                  padding: shellScrollPadding(
                    c,
                    const EdgeInsets.only(bottom: S.x16),
                  ),
                  children: [
                    const SizedBox(height: 1200),
                    Pressable(onTap: () {}, child: const Text('Last action')),
                  ],
                ),
              ),
            ),
            scale: 3.1,
            bottomInset: S.x8,
          ),
        );
        await t.drag(find.byType(ListView), const Offset(0, -1800));
        await t.pumpAndSettle();
        final target = find.ancestor(
          of: find.text('Last action'),
          matching: find.byType(Pressable),
        );
        final nav = t.getRect(_navigation);
        expect(t.getRect(target).bottom, lessThan(nav.top));
        if (banner) {
          expect(
            t.getRect(find.text('Active workout')).bottom,
            lessThan(nav.top),
          );
        }
        expect(t.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'Original keeps all four visible tabs lazy and preserves their state',
    (t) async {
      final mounts = <ShellDomain, int>{};
      await t.pumpWidget(
        _frame(
          AppShell(builder: (c, d) => _CounterPage(d, mounts)),
          style: InterfaceStyle.original,
        ),
      );
      expect(mounts, {ShellDomain.home: 1});
      await t.tap(find.text('home: 0'));
      await t.pumpAndSettle();
      for (final d in visibleShellDomains.skip(1)) {
        await t.tap(find.text(d.label));
        await t.pumpAndSettle();
        expect(find.text('${d.name}: 0'), findsOneWidget);
      }
      expect(mounts, {for (final d in visibleShellDomains) d: 1});
      await t.tap(find.text('Home'));
      await t.pumpAndSettle();
      expect(find.text('home: 1'), findsOneWidget);
      expect(find.text('Nutrition'), findsNothing);
    },
  );

  testWidgets(
    'all four capsules select lazily and retain visited screen state',
    (t) async {
      final semantics = t.ensureSemantics();
      try {
        final mounts = <ShellDomain, int>{};
        final selected = <ShellDomain>[];
        await t.pumpWidget(
          _frame(
            AppShell(
              builder: (c, d) => _CounterPage(d, mounts),
              onSelect: selected.add,
            ),
          ),
        );
        expect(mounts, {ShellDomain.home: 1});
        // The button's own label is merged with its visible counter text.
        await t.tap(find.bySemanticsLabel(RegExp(r'^Count home(?:\n|$)')));
        await t.pump();

        expect(find.text('Nutrition'), findsNothing);
        expect(
          find.byKey(const ValueKey('expressive-tab-nutrition')),
          findsNothing,
        );
        for (final d in visibleShellDomains.skip(1)) {
          final tab = find.byKey(ValueKey('expressive-tab-${d.name}'));
          await t.tap(_tabTarget(d));
          await t.pumpAndSettle();
          expect(find.text('${d.name}: 0'), findsOneWidget);
          final capsule = t.getRect(
            find.byKey(const ValueKey('expressive-selected-capsule')),
          );
          final icon = t.getRect(
            find.descendant(of: tab, matching: find.byIcon(d.icon)),
          );
          final label = t.getRect(
            find.descendant(of: tab, matching: find.text(d.label)),
          );
          expect(capsule.contains(icon.topLeft), isTrue);
          expect(capsule.contains(icon.bottomRight), isTrue);
          expect(capsule.contains(label.topLeft), isTrue);
          expect(capsule.contains(label.bottomRight), isTrue);
          expect(icon.center.dy, closeTo(label.center.dy, .001));
          expect(icon.right, lessThanOrEqualTo(label.left));
          final navigationLabels = find.descendant(
            of: _navigation,
            matching: find.byType(Text),
          );
          expect(navigationLabels, findsOneWidget);
          expect(t.widget<Text>(navigationLabels).data, d.label);
          expect(t.widget<Icon>(find.byIcon(d.icon)).size, S.navIcon);
          for (final other in visibleShellDomains.where(
            (other) => other != d,
          )) {
            expect(t.widget<Icon>(find.byIcon(other.icon)).size, S.x6);
          }
        }
        expect(mounts, {for (final d in visibleShellDomains) d: 1});
        await t.tap(_tabTarget(ShellDomain.home));
        await t.pumpAndSettle();
        expect(find.text('home: 1'), findsOneWidget);
        await t.tap(_tabTarget(ShellDomain.home));
        await t.pumpAndSettle();
        expect(selected.where((d) => d == ShellDomain.home), hasLength(2));
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'normal caption keeps the pill compact and idle targets evenly spaced',
    (t) async {
      t.view.physicalSize = const Size(390, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        _frame(AppShell(builder: (c, d) => const SizedBox.shrink())),
      );
      for (final selected in visibleShellDomains) {
        await t.tap(_tabTarget(selected));
        await t.pumpAndSettle();
        _expectBoundedNavigation(t);
        final inner = t.getRect(_navigation).deflate(S.x1);
        final capsule = t.getRect(
          find.byKey(const ValueKey('expressive-selected-capsule')),
        );
        final icon = t.getRect(find.byIcon(selected.icon));
        final caption = find.descendant(
          of: _navigation,
          matching: find.byType(Text),
        );
        final label = t.getRect(caption);
        expect(
          t.renderObject<RenderParagraph>(caption).didExceedMaxLines,
          isFalse,
        );
        expect(
          capsule.width,
          closeTo(icon.width + S.x1 + label.width + S.x4, 1),
        );
        expect(capsule.width, lessThan(inner.width / 2));
        expect(icon.left - capsule.left, closeTo(S.x2, 1));
        expect(capsule.right - label.right, closeTo(S.x2, 1));
        final idleWidth = (inner.width - capsule.width) / 3;
        for (final idle in visibleShellDomains.where((d) => d != selected)) {
          final target = t.getRect(_tabTarget(idle));
          expect(target.width, closeTo(idleWidth, .001));
          expect(
            t.getRect(find.byIcon(idle.icon)).center.dx,
            closeTo(target.center.dx, .001),
          );
        }
      }
    },
  );

  testWidgets(
    '320 pt navigation keeps four targets and one scaled caption in all locales',
    (t) async {
      final semantics = t.ensureSemantics();
      t.view.physicalSize = const Size(320, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      try {
        for (final scale in [1.0, 2.0, 3.1]) {
          for (final locale in AppLocalizations.supportedLocales) {
            await t.pumpWidget(
              _frame(
                AppShell(builder: (c, d) => const SizedBox.shrink()),
                locale: locale,
                scale: scale,
              ),
            );
            await t.pumpAndSettle();
            final c = t.element(find.byType(AppShell));
            expect(find.text(ShellDomain.nutrition.title(c)), findsNothing);
            for (final selected in visibleShellDomains) {
              await t.tap(_tabTarget(selected));
              await t.pumpAndSettle();
              expect(t.takeException(), isNull, reason: '$locale at $scale');
              _expectBoundedNavigation(t);
              final labels = find.descendant(
                of: _navigation,
                matching: find.byType(Text),
              );
              expect(labels, findsOneWidget);
              final label = t.widget<Text>(labels);
              expect(label.data, selected.title(c));
              expect(label.style!.fontSize, F.over.fontSize);
              expect(label.maxLines, 1);
              expect(label.softWrap, isFalse);
              expect(label.overflow, TextOverflow.ellipsis);
              final lineHeight =
                  scale * label.style!.fontSize! * label.style!.height!;
              expect(
                t.getSize(labels).height,
                lessThanOrEqualTo(lineHeight + 1),
              );
              if (scale == 1) {
                expect(
                  t.renderObject<RenderParagraph>(labels).didExceedMaxLines,
                  isFalse,
                  reason: '$locale: ${label.data} should fit at default size',
                );
              }
              for (final d in visibleShellDomains) {
                final target = find.descendant(
                  of: _navigation,
                  matching: find.byWidgetPredicate(
                    (w) => w is Pressable && w.semanticLabel == d.title(c),
                  ),
                );
                expect(target, findsOneWidget);
                final node = t.getSemantics(target);
                expect(node.label, d.title(c));
                expect(node.flagsCollection.isButton, isTrue);
                expect(
                  node.flagsCollection.isSelected,
                  d == selected ? Tristate.isTrue : Tristate.isFalse,
                );
                expect(
                  find.descendant(
                    of: _navigation,
                    matching: find.byWidgetPredicate(
                      (w) => w is Tooltip && w.message == d.title(c),
                    ),
                  ),
                  findsOneWidget,
                );
              }
            }
          }
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('rapid spring transitions stay bounded in LTR and RTL', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    for (final direction in TextDirection.values) {
      await t.pumpWidget(const SizedBox.shrink());
      final mounts = <ShellDomain, int>{};
      await t.pumpWidget(
        _frame(
          AppShell(builder: (c, d) => _CounterPage(d, mounts)),
          locale: const Locale('de'),
          scale: 3.1,
          direction: direction,
        ),
      );
      for (final d in [
        ShellDomain.wellness,
        ShellDomain.health,
        ShellDomain.workout,
        ShellDomain.home,
        ShellDomain.wellness,
      ]) {
        await t.tap(_tabTarget(d));
        await t.pump();
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 16));
          expect(t.takeException(), isNull);
          _expectBoundedNavigation(t);
          final label = t.widget<Text>(
            find.descendant(of: _navigation, matching: find.byType(Text)),
          );
          expect(label.data, d.title(t.element(find.byType(AppShell))));
          expect(label.maxLines, 1);
          expect(label.softWrap, isFalse);
        }
      }
      // Check the overshoot and settling frames too, after the last interruption.
      for (var i = 0; i < 35; i++) {
        await t.pump(const Duration(milliseconds: 16));
        expect(t.takeException(), isNull);
        _expectBoundedNavigation(t);
      }
      await t.pumpAndSettle();
      expect(mounts, {for (final d in visibleShellDomains) d: 1});
      final capsule = t.getRect(
        find.byKey(const ValueKey('expressive-selected-capsule')),
      );
      expect(
        capsule,
        t.getRect(find.byKey(const ValueKey('expressive-tab-wellness'))),
      );
      final home = t.getRect(find.byKey(const ValueKey('expressive-tab-home')));
      expect(
        direction == TextDirection.rtl
            ? home.left > capsule.left
            : home.left < capsule.left,
        isTrue,
      );
    }
  });

  testWidgets(
    'unchanged parent rebuilds do not restart a navigation transition',
    (t) async {
      final ticks = ValueNotifier<int>(0);
      addTearDown(ticks.dispose);
      await t.pumpWidget(
        _frame(
          ValueListenableBuilder<int>(
            valueListenable: ticks,
            builder: (c, _, child) =>
                AppShell(builder: (c, d) => const SizedBox.shrink()),
          ),
        ),
      );
      await t.tap(_tabTarget(ShellDomain.wellness));
      await t.pump();
      for (var i = 0; i < 40; i++) {
        ticks.value++;
        await t.pump(const Duration(milliseconds: 16));
      }
      final capsule = t.getRect(
        find.byKey(const ValueKey('expressive-selected-capsule')),
      );
      final target = t.getRect(_tabTarget(ShellDomain.wellness));
      expect(capsule.left, closeTo(target.left, .001));
      expect(capsule.width, closeTo(target.width, .001));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion places the capsule at its final destination immediately',
    (t) async {
      await t.pumpWidget(
        _frame(
          AppShell(builder: (c, d) => const SizedBox.shrink()),
          reduceMotion: true,
        ),
      );
      await t.tap(_tabTarget(ShellDomain.wellness));
      await t.pump();
      expect(
        t
            .widget<TweenAnimationBuilder<List<double>>>(
              find.byType(TweenAnimationBuilder<List<double>>),
            )
            .duration,
        Duration.zero,
      );
      final capsule = t.getRect(
        find.byKey(const ValueKey('expressive-selected-capsule')),
      );
      final tab = t.getRect(
        find.byKey(const ValueKey('expressive-tab-wellness')),
      );
      expect(capsule, tab);
    },
  );
}
