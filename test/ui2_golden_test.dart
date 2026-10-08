// Goldens for the grammar.
//
// The repo had ZERO goldens across forty screens, which is the mechanical
// reason every visual fix regressed something else: nothing recorded what the
// components were supposed to look like, so "it looks right on my screen" was
// the whole acceptance test.
//
// Each component is captured in four states — light and dark, at 1.0× and
// 2.0× text scale. The 2.0× pass is not decoration: accessibility text sizes
// are where cards overflow, and a golden is the only cheap way to notice.
//
// Regenerate deliberately, never reflexively:
//     flutter test --update-goldens test/ui2_golden_test.dart
// and look at the diff. A golden updated without looking is a golden that
// records the bug.
//
// These were baked on Flutter 3.44.9 (the `flutter` on PATH). An older SDK
// anti-aliases hairlines differently and fails a handful of them on nothing
// but sub-pixel blend — that is an SDK mismatch, not a regression. The iOS
// build uses ~/flutter-sdks/flutter (3.41.6) for an unrelated reason; do not
// run goldens with it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The cases are the GALLERY's cases. One list, so the pictures in here and
// the screen a developer opens on a phone cannot describe two different
// design systems — and so a component added to one is added to both.
import 'package:openstrap_edge/ui2/profile/gallery.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// The golden is the component, not the page: capturing this boundary means a
/// PNG the size of the thing under test, and a diff that points at the card
/// that changed rather than at a screenshot of everything.
final _shot = GlobalKey();

Widget _frame(Widget child, Brightness b, double scale,
        {InterfaceStyle style = InterfaceStyle.original}) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b, style: style),
        home: Builder(
          builder: (c) => Scaffold(
            backgroundColor: P.of(c).bg,
            // Top-aligned, not centred: a component that grows past the
            // viewport at 2x text should be tall in the golden, not clipped
            // in the middle.
            // A scroll view, because that is what every real screen is: it
            // hands the component an unbounded height, so a card shrink-wraps
            // its content here exactly as it does in the app.
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(S.x4),
                child: RepaintBoundary(key: _shot, child: child),
              ),
            ),
          ),
        ),
      ),
    );

/// Load the bundled type so the goldens show words instead of the test
/// harness's block glyphs. A golden nobody can read is a golden nobody
/// reviews, and an unreviewed golden gets `--update-goldens`-ed over the top
/// of the bug it was supposed to catch.
Future<void> _loadType() async {
  final files = Directory('assets/fonts/Manrope')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'));
  // Registered under both names. `.SF Pro Text` does not exist off Apple
  // hardware, so on Android and in the test harness the type IS Manrope —
  // registering it under the primary name makes the goldens show what a
  // non-Apple user actually sees, rather than the harness's fallback blocks.
  for (final family in const ['Manrope', '.SF Pro Text']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(f
          .readAsBytes()
          .then((b) => ByteData.sublistView(Uint8List.fromList(b))));
    }
    await loader.load();
  }
}

/// The golden PNGs are NOT in the repo. They are machine-specific — two Flutter
/// SDKs disagree on antialiasing — and 27 MB of them was purged from history,
/// so this group can only pass on a machine that has them.
///
/// Skipped with a stated reason rather than filtered out by a CI flag: the run
/// then says out loud that nobody checked the pixels, which is the honest
/// report. Drop the images back into test/goldens/ and it runs again.
final Object _noGoldens = Directory('test/goldens').existsSync()
    ? false
    : 'golden images are not committed — run this suite locally';

void main() {
  // Photographed: the vocabulary. Swept for overflow and tap size below:
  // everything, painters included. A PNG is a file somebody has to review, and
  // an unreviewed golden records the bug — the sweeps cost nothing to add.
  final cases = goldenCases();
  final all = galleryCases();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadType();
  });

  for (final scale in const [1.0, 2.0]) {
    final tag = scale == 1.0 ? '1x' : '2x';
    for (final brightness in Brightness.values) {
      final theme = brightness.name;
      group('$theme · $tag text', () {
        cases.forEach((name, widget) {
          testWidgets(name, (tester) async {
            // Phone width, generous height — the width is what components are
            // designed against; the height only has to be enough that 2x text
            // is not artificially clipped.
            tester.view.physicalSize = const Size(390 * 3, 1800 * 3);
            tester.view.devicePixelRatio = 3;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(_frame(widget, brightness, scale));
            await tester.pumpAndSettle();

            await expectLater(
              find.byKey(_shot),
              matchesGoldenFile('goldens/${name}_${theme}_$tag.png'),
            );
          });
        });
      }, skip: _noGoldens);
    }
  }

  for (final style in InterfaceStyle.values) {
    testWidgets(
      '${style.name}: shell exposes four destinations and hides Nutrition',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light, style: style),
            home: AppShell(builder: (c, d) => const SizedBox.shrink()),
          ),
        );
        expect(visibleShellDomains, hasLength(4));
        expect(find.text(ShellDomain.nutrition.label), findsNothing);
        final targets = tester.widgetList<Pressable>(find.byType(Pressable));
        for (final d in visibleShellDomains) {
          expect(find.byIcon(d.icon), findsOneWidget);
          expect(
            targets.any((target) => target.semanticLabel == d.label),
            isTrue,
          );
          expect(
            find.text(d.label),
            style == InterfaceStyle.original || d == ShellDomain.home
                ? findsOneWidget
                : findsNothing,
          );
        }
      },
    );
  }

  testWidgets('every tap target in the shell clears 44 pt', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: AppShell(builder: (c, d) => const SizedBox.shrink()),
    ));
    for (final e in tester.widgetList<Pressable>(find.byType(Pressable))) {
      if (e.onTap == null) continue;
      final size = tester.getSize(find.byWidget(e));
      expect(size.height, greaterThanOrEqualTo(S.tap),
          reason: '${e.semanticLabel} is ${size.height} pt tall');
      expect(size.width, greaterThanOrEqualTo(S.tap),
          reason: '${e.semanticLabel} is ${size.width} pt wide');
    }
  });

  // ── the tiers the PNGs do not cover ────────────────────────────────────
  //
  // iOS reaches 3.1x with Larger Accessibility Sizes and Android about 2.6x
  // effective, so 2.0x is not the ceiling — but 174 more images per tier is
  // 174 more images nobody reviews, and an unreviewed golden records the bug.
  // These two sweeps run the SAME case list past the top of the range and
  // assert the two things a picture would only show if somebody looked.
  //
  // Both also cover 1.0x, because F-06 was a component clipped at 1.0x that
  // four goldens photographed and nobody noticed.
  group('past the golden ceiling', () {
    for (final style in InterfaceStyle.values) {
      for (final scale in const [1.0, 1.4, 2.0, 3.0, 3.1]) {
        testWidgets('${style.name}: nothing overflows at ${scale}x', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(390 * 3, 4000 * 3);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          final broke = <String>[];
          for (final e in all.entries) {
            final errors = <String>[];
            final previous = FlutterError.onError;
            FlutterError.onError = (d) => errors.add(d.exceptionAsString());
            await tester.pumpWidget(
              _frame(e.value, Brightness.light, scale, style: style),
            );
            await tester.pump();
            FlutterError.onError = previous;
            for (final err in errors) {
              if (err.contains('overflowed')) broke.add('${e.key}: $err');
            }
          }
          expect(
            broke,
            isEmpty,
            reason:
                'a card that overflows at an accessibility text size is a '
                'measurement pushed off the screen:\n${broke.join('\n')}',
          );
        });
      }

      testWidgets('${style.name}: every tap target in every case clears 44 pt', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390 * 3, 4000 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final small = <String>[];
        for (final e in all.entries) {
          await tester.pumpWidget(
            _frame(e.value, Brightness.light, 1.0, style: style),
          );
          await tester.pump();
          for (final w in tester.widgetList<Pressable>(
            find.byType(Pressable),
          )) {
            if (w.onTap == null) continue;
            final s = tester.getSize(find.byWidget(w));
            if (s.height < S.tap || s.width < S.tap) {
              small.add(
                '${e.key} · ${w.semanticLabel ?? 'unlabelled'} '
                'is ${s.width} × ${s.height}',
              );
            }
          }
        }
        expect(
          small,
          isEmpty,
          reason:
              'the 44 pt guarantee only held for the shell tabs, '
              'which is how seven sub-44 controls shipped:\n${small.join('\n')}',
        );
      });
    }
  });
}
