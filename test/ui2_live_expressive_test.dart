import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/live.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _bike = activityByName('Indoor bike')!;
const _feed = LiveFeed(
  hr: 146,
  maxHr: 162,
  zone: 3,
  bandConnected: true,
  calories: 89,
  strain: 4.2,
  hrCurve: [110, 128, null, 146, 140],
  zoneMinutes: [1.2, 0.5, 2, 0, 0],
);

Widget _frame(
  Widget child, {
  double scale = 1,
  bool reduced = false,
  Brightness brightness = Brightness.dark,
}) => ChangeNotifierProvider(
  create: (_) => ThemeController.seed(
    AppThemeChoice.dark,
    brightness,
    interfaceStyle: InterfaceStyle.expressive,
  ),
  child: MaterialApp(
    theme: buildTheme(
      brightness,
      style: InterfaceStyle.expressive,
    ).copyWith(platform: TargetPlatform.android),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduced,
      ),
      child: child!,
    ),
    home: child,
  ),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final family in ['Manrope', '.SF Pro Text']) {
      final loader = FontLoader(family);
      loader.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-500.ttf'));
      await loader.load();
    }
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    LiveDraft.clear();
  });
  tearDown(LiveDraft.clear);

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.4, 2.0, 3.1]) {
      testWidgets('live layout fits 320px, ${brightness.name}, $scale text', (
        t,
      ) async {
        t.view.physicalSize = const Size(320, 820);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          _frame(
            LiveMeasured(_bike, feed: () => _feed),
            scale: scale,
            brightness: brightness,
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('Pause'), findsOneWidget);
        expect(find.text('Finish session'), findsOneWidget);
        expect(t.takeException(), isNull);
        for (final label in ['Pause', 'Finish session']) {
          final action = find.ancestor(
            of: find.text(label),
            matching: find.byType(Pressable),
          );
          final bounds = t.getRect(action);
          expect(bounds.width, greaterThanOrEqualTo(S.tap));
          expect(bounds.height, greaterThanOrEqualTo(S.tap));
          expect(bounds.bottom, lessThanOrEqualTo(820));
        }
        await t.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final arch in Arch.values) {
    testWidgets(
      '${arch.name} retains its inputs inside the expressive live shell',
      (t) async {
        t.view.physicalSize = const Size(390, 850);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final activity = allActivities.firstWhere((a) => archOf(a) == arch);
        await t.pumpWidget(
          _frame(liveFor(activity), scale: 2, reduced: arch == Arch.flow),
        );
        await t.pumpAndSettle();
        expect(find.text('Pause'), findsOneWidget);
        expect(find.text('Finish session'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('repeated Finish taps save once and leave the existing summary', (
    t,
  ) async {
    LiveDraft.begin(_bike);
    final save = Completer<ActivityResult>();
    ActivityResult? result;
    var calls = 0;
    await t.pumpWidget(
      _frame(
        LiveMeasured(
          _bike,
          feed: () => _feed,
          onFinish: (draft) {
            calls++;
            result = draft;
            return save.future;
          },
        ),
      ),
    );
    await t.tap(find.text('Finish session'));
    await t.pump();
    await t.tap(find.text('Finish session'));
    await t.pump();
    expect(calls, 1);
    save.complete(result!);
    await t.pumpAndSettle();
    expect(LiveDraft.current, isNull);
    expect(find.byType(ActivitySummary), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'the chart retains minute gaps and labels its actual time range',
    (t) async {
      await t.pumpWidget(_frame(LiveMeasured(_bike, feed: () => _feed)));
      await t.pumpAndSettle();
      final frame = t.widget<ChartFrame>(find.byType(ChartFrame).first);
      expect(frame.series, _feed.hrCurve);
      expect(frame.xLabels, ['00:00', '04:00']);
      final plot = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<LineChart>()
          .single;
      expect(plot.d, [110, 128, null, 146, 140]);
      expect(plot.axis, same(frame.yAxis));
      expect(find.byType(RepaintBoundary), findsWidgets);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing live readings stay absent while recorded history remains visible',
    (t) async {
      await t.pumpWidget(
        _frame(
          LiveMeasured(
            _bike,
            feed: () => const LiveFeed(hrCurve: [110, null, 120]),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('No heart rate'), findsOneWidget);
      expect(find.byType(ChartFrame), findsOneWidget);
      expect(find.text('0 bpm'), findsNothing);
      expect(find.byKey(const ValueKey('live-zone-card')), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('pause, minimize and return retain the clock and typed draft', (
    t,
  ) async {
    final draft = LiveDraft.begin(_bike);
    draft.put('user_note', 'Keep this');
    await t.pumpWidget(
      _frame(
        AppShell(
          builder: (_, _) => const Text('Home content'),
          banner: LiveSessionCard(
            _bike,
            elapsed: 85,
            onNavigate: (open) async {
              await open<void>(LiveMeasured(_bike, feed: () => _feed));
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final card = find.byKey(const ValueKey('live-session-card'));
    final nav = find.byKey(const ValueKey('expressive-navigation'));
    expect(t.getRect(card).left, closeTo(t.getRect(nav).left, .01));
    expect(t.getRect(card).right, closeTo(t.getRect(nav).right, .01));
    expect(t.getRect(card).bottom, lessThan(t.getRect(nav).top));
    await t.tap(find.text('Indoor bike'));
    await t.pump();
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 90));
    expect(find.byKey(const ValueKey('detail-morph-surface')), findsOneWidget);
    await t.pumpAndSettle();
    await t.tap(find.text('Pause'));
    await t.pumpAndSettle();
    expect(draft.pausedAt, isNotNull);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    final elapsed = draft.elapsedSec;
    await t.pump(const Duration(seconds: 3));
    expect(draft.elapsedSec, elapsed);
    await t.tap(find.bySemanticsLabel('Minimise'));
    await t.pumpAndSettle();
    expect(LiveDraft.current, same(draft));
    expect(draft.data['user_note'], 'Keep this');
    expect(card, findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion still opens the same live session', (t) async {
    final draft = LiveDraft.begin(_bike);
    await t.pumpWidget(
      _frame(
        AppShell(
          builder: (_, _) => const SizedBox.shrink(),
          banner: LiveSessionCard(
            _bike,
            elapsed: 85,
            onNavigate: (open) async {
              await open<void>(LiveMeasured(_bike, feed: () => _feed));
            },
          ),
        ),
        reduced: true,
      ),
    );
    await t.tap(find.text('Indoor bike'));
    await t.pumpAndSettle();
    expect(find.byType(LiveMeasured), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-morph-surface')), findsNothing);
    expect(LiveDraft.current, same(draft));
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a paused long-running session card remains readable at large text',
    (t) async {
      t.view.physicalSize = const Size(320, 820);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        _frame(
          AppShell(
            builder: (_, _) => const Text('Home content'),
            banner: LiveSessionCard(
              _bike,
              elapsed: 3925,
              paused: true,
              onNavigate: (_) async {},
            ),
          ),
          scale: 3.1,
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Paused'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Indoor bike, 1:05:25, Paused')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
}
