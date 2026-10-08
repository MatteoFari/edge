import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/ai_briefing.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart' show kCoachAccent;
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Repo extends LocalRepository {}

class _FailingGenerationRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async =>
      throw StateError('The saved metrics could not be read');
}

class _Configured extends CoachConfig {
  @override
  bool get configured => true;
}

int _identity = 0;
Briefing _briefing({
  String one = 'You recovered well. Keep your usual pace today.',
  BriefingPeriod? period,
  String? day,
  String? breakdown,
  Map<String, dynamic> inputs = const {'readiness': 73},
}) => Briefing(
  day: day ?? todayLabel(),
  period: period ?? currentBriefingPeriod(DateTime.now()),
  oneLiner: one,
  breakdownMd:
      breakdown ??
      (one.isEmpty ? '' : 'Your saved recovery and sleep summary.'),
  generatedAtMs: ++_identity,
  inputs: inputs,
);

HomeData _home() => HomeData(
  dayId: todayLabel(),
  readiness: const Metric(value: 73),
  sleepMin: const Metric(value: 431),
  sleepNeedMin: const Metric(value: 487),
  strain: const Metric(value: 12.4),
  rhr: const Metric(value: 51),
  steps: const Metric(value: 2432),
  calories: const Metric(value: 350),
);

const _entry = ValueKey('home-ai-briefing');
const _surface = ValueKey('home-ai-briefing-surface');

Widget _frame(
  Widget child, {
  required AppState app,
  required CoachConfig config,
  Brightness brightness = Brightness.light,
  InterfaceStyle style = InterfaceStyle.expressive,
  double scale = 1,
  bool reduced = true,
  Locale locale = const Locale('en'),
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<AppState>.value(value: app),
    ChangeNotifierProvider<CoachConfig>.value(value: config),
    ChangeNotifierProvider<ThemeController>(
      create: (_) => ThemeController.seed(
        brightness == Brightness.light
            ? AppThemeChoice.light
            : AppThemeChoice.dark,
        brightness,
        interfaceStyle: style,
      ),
    ),
  ],
  child: MaterialApp(
    locale: locale,
    theme: buildTheme(brightness, style: style),
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
  late AppState app;
  late CoachConfig config;

  setUpAll(() async {
    for (final family in ['.SF Pro Text', 'Manrope']) {
      final loader = FontLoader(family);
      loader.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-400.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-600.ttf'));
      await loader.load();
    }
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
    app = AppState.forTesting()..repo = _Repo();
    config = _Configured();
  });

  tearDown(() {
    app.dispose();
    config.dispose();
  });

  Future<void> mount(
    WidgetTester t,
    Widget child, {
    Brightness brightness = Brightness.light,
    InterfaceStyle style = InterfaceStyle.expressive,
    double scale = 1,
    bool reduced = true,
    Locale locale = const Locale('en'),
  }) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      _frame(
        child,
        app: app,
        config: config,
        brightness: brightness,
        style: style,
        scale: scale,
        reduced: reduced,
        locale: locale,
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('Home has one unread door immediately below the metrics', (
    t,
  ) async {
    final b = _briefing();
    BriefingStore.write(b);
    final semantics = t.ensureSemantics();
    await mount(t, Scaffold(body: HomeScreen(data: _home(), hour: 9)));

    expect(find.byKey(_entry), findsOneWidget);
    final logo = t.widget<SvgPicture>(
      find.descendant(
        of: find.byKey(_entry),
        matching: find.byType(SvgPicture),
      ),
    );
    expect(
      (logo.bytesLoader as SvgAssetLoader).assetName,
      kEdgeMarkAsset,
      reason: 'Briefing must use the same application mark as Coach.',
    );
    expect(find.text('New'), findsOneWidget);
    expect(
      BriefingStore.isRead(b),
      isFalse,
      reason: 'Seeing the Home preview must not consume unread content.',
    );
    final metrics = t.getRect(find.byType(RingTrio));
    final entry = t.getRect(find.byKey(_entry));
    expect(entry.top - metrics.bottom, closeTo(S.x3, .1));
    final text = t.getRect(find.byKey(const ValueKey('home-briefing-text')));
    for (final key in ['home-briefing-icon', 'home-briefing-chevron']) {
      expect(
        t.getRect(find.byKey(ValueKey(key))).center.dy,
        closeTo(text.center.dy, .1),
      );
    }
    final node = t.getSemantics(find.byKey(_entry));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(node.label, contains('New'));
    expect(node.label, contains(b.oneLiner));
    semantics.dispose();
  });

  testWidgets(
    'briefing visibility updates every Home state without consuming it',
    (t) async {
      final b = _briefing();
      BriefingStore.write(b);
      for (final data in <HomeData?>[_home(), const HomeData(), null]) {
        await app.setHomeAiBriefingEnabled(true);
        await mount(
          t,
          Scaffold(
            body: HomeScreen(key: UniqueKey(), data: data),
          ),
        );
        expect(find.byKey(_entry), findsOneWidget);

        await app.setHomeAiBriefingEnabled(false);
        await t.pumpAndSettle();
        expect(find.byKey(_entry), findsNothing);
        expect(BriefingStore.read(b.period, day: b.day)?.id, b.id);
        expect(BriefingStore.isRead(b), isFalse);

        await app.setHomeAiBriefingEnabled(true);
        await t.pumpAndSettle();
        expect(find.byKey(_entry), findsOneWidget);
        expect(find.text('New'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'opening successful content marks read and keeps the door usable',
    (t) async {
      final b = _briefing();
      BriefingStore.write(b);
      await mount(t, Scaffold(body: HomeScreen(data: _home())), reduced: false);
      await t.ensureVisible(find.byKey(_entry));
      await t.tap(find.byKey(_entry));
      await t.pump();
      await t.pump(const Duration(milliseconds: 40));
      expect(
        BriefingStore.isRead(b),
        isFalse,
        reason: 'A route still opening has not displayed the briefing yet.',
      );
      await t.pumpAndSettle();
      expect(find.byType(AiBriefingScreen), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is GptMarkdown && w.data == b.breakdownMd,
        ),
        findsOneWidget,
      );
      expect(BriefingStore.isRead(b), isTrue);

      Navigator.of(t.element(find.byType(AiBriefingScreen))).pop();
      await t.pumpAndSettle();
      expect(find.text('New'), findsNothing);
      final card = t.widget<Pressable>(find.byKey(_entry));
      expect(card.onTap, isNotNull);
      final p = P.of(t.element(find.byKey(_entry)));
      final surface = t.widget<AnimatedContainer>(find.byKey(_surface));
      expect((surface.decoration! as BoxDecoration).color, p.card);
      await t.tap(find.byKey(_entry));
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is GptMarkdown && w.data == b.breakdownMd,
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('pending and failed reads stay unread; successful retry reads', (
    t,
  ) async {
    final b = _briefing(period: BriefingPeriod.morning);
    BriefingStore.write(b);
    final pending = Completer<Briefing?>();
    var attempts = 0;
    await mount(
      t,
      AiBriefingScreen(
        period: b.period,
        loadBriefing: (_, {day}) {
          attempts++;
          return attempts == 1 ? pending.future : b;
        },
      ),
    );
    expect(find.text('Opening briefing…'), findsOneWidget);
    expect(BriefingStore.isRead(b), isFalse);
    pending.completeError(StateError('Saved content unavailable'));
    await t.pumpAndSettle();
    expect(
      find.text('The saved briefing could not be opened. Try again.'),
      findsOneWidget,
    );
    expect(BriefingStore.isRead(b), isFalse);
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) => w is GptMarkdown && w.data == b.breakdownMd,
      ),
      findsOneWidget,
    );
    expect(BriefingStore.isRead(b), isTrue);
  });

  testWidgets('leaving a pending read never consumes the briefing', (t) async {
    final b = _briefing();
    BriefingStore.write(b);
    final pending = Completer<Briefing?>();
    await mount(
      t,
      AiBriefingScreen(
        period: b.period,
        loadBriefing: (_, {day}) => pending.future,
      ),
    );
    await t.pumpWidget(const SizedBox.shrink());
    pending.complete(b);
    await t.pumpAndSettle();
    expect(BriefingStore.isRead(b), isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'content loaded behind another route stays unread until revealed',
    (t) async {
      final b = _briefing();
      BriefingStore.write(b);
      final pending = Completer<Briefing?>();
      await mount(
        t,
        AiBriefingScreen(
          period: b.period,
          loadBriefing: (_, {day}) => pending.future,
        ),
      );
      final navigator = Navigator.of(t.element(find.byType(AiBriefingScreen)));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Another page')),
          ),
        ),
      );
      await t.pumpAndSettle();
      pending.complete(b);
      await t.pumpAndSettle();
      expect(BriefingStore.isRead(b), isFalse);
      navigator.pop();
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is GptMarkdown && w.data == b.breakdownMd,
        ),
        findsOneWidget,
      );
      expect(BriefingStore.isRead(b), isTrue);
    },
  );

  testWidgets('blank content is an empty state and remains unread', (t) async {
    final b = _briefing(one: '');
    BriefingStore.write(b);
    await mount(t, AiBriefingScreen(period: b.period));
    expect(find.text('Nothing written for today'), findsOneWidget);
    expect(find.text('Write one now'), findsOneWidget);
    expect(BriefingStore.isRead(b), isFalse);
  });

  testWidgets('failed generation cannot consume an existing saved briefing', (
    t,
  ) async {
    final b = _briefing(period: BriefingPeriod.morning);
    BriefingStore.write(b);
    app.repo = _FailingGenerationRepo();
    await mount(
      t,
      AiBriefingScreen(period: b.period, loadBriefing: (_, {day}) => null),
    );
    await t.tap(find.text('Write one now'));
    await t.pumpAndSettle();
    expect(find.text('That did not go through'), findsOneWidget);
    expect(
      find.text('Write one now'),
      findsOneWidget,
      reason: 'The busy latch must clear after failure.',
    );
    expect(BriefingStore.isRead(b), isFalse);
  });

  testWidgets('a newly generated briefing restores unread emphasis', (t) async {
    final older = _briefing();
    BriefingStore.write(older);
    await BriefingStore.markRead(older);
    await mount(t, Scaffold(body: HomeScreen(data: _home())));
    expect(find.text('New'), findsNothing);
    final newer = _briefing(one: 'A fresh briefing is ready.');
    BriefingStore.write(newer);
    app.briefingUpdated();
    await t.pumpAndSettle();
    expect(find.text('New'), findsOneWidget);
    expect(find.text(newer.oneLiner), findsOneWidget);
    expect(BriefingStore.isRead(newer), isFalse);
    expect(BriefingStore.isRead(older), isTrue);
  });

  testWidgets('a saved past briefing opens its own day and keeps the status', (
    t,
  ) async {
    final b = _briefing(day: '2026-09-23');
    BriefingStore.write(b);
    await mount(t, AiBriefingScreen(period: b.period, day: b.day));
    expect(
      find.byWidgetPredicate(
        (w) => w is GptMarkdown && w.data == b.breakdownMd,
      ),
      findsOneWidget,
    );
    final l = AppLocalizations.of(t.element(find.byType(AiBriefingScreen)))!;
    expect(find.text(l.aiBriefingForDay(prettyDay(b.day, l))), findsOneWidget);
    expect(find.text('Write it again'), findsNothing);
    expect(BriefingStore.isRead(b), isTrue);
  });

  testWidgets(
    'saved content stays readable after model configuration is removed',
    (t) async {
      config.dispose();
      config = CoachConfig();
      final b = _briefing();
      BriefingStore.write(b);
      await mount(t, AiBriefingScreen(period: b.period));
      expect(
        find.byWidgetPredicate(
          (w) => w is GptMarkdown && w.data == b.breakdownMd,
        ),
        findsOneWidget,
      );
      expect(find.text('Choose a model'), findsOneWidget);
      expect(BriefingStore.isRead(b), isTrue);
    },
  );

  for (final brightness in Brightness.values) {
    for (final style in InterfaceStyle.values) {
      testWidgets(
        'unread/read card is accessible at 3.1× in $brightness $style',
        (t) async {
          final b = _briefing();
          BriefingStore.write(b);
          final semantics = t.ensureSemantics();
          await mount(
            t,
            Scaffold(body: HomeScreen(data: _home())),
            brightness: brightness,
            style: style,
            scale: 3.1,
          );
          await t.scrollUntilVisible(
            find.byKey(_entry),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          expect(t.takeException(), isNull);
          final before = t.getSemantics(find.byKey(_entry));
          expect(
            before.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
          );
          final target = t.getSize(find.byKey(_entry));
          expect(target.width, greaterThanOrEqualTo(S.tap));
          expect(target.height, greaterThanOrEqualTo(S.tap));
          expect(await BriefingStore.markRead(b), isTrue);
          app.briefingUpdated();
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(find.text('New'), findsNothing);
          final after = t.getSemantics(find.byKey(_entry));
          expect(
            after.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
          );
          expect(after.flagsCollection.isButton, isTrue);
          expect(after.label, isNot(contains('New')));
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('Italian heading and New label reflow at 3.1× with real fonts', (
    t,
  ) async {
    final b = _briefing();
    BriefingStore.write(b);
    await mount(
      t,
      Scaffold(body: HomeScreen(data: _home())),
      brightness: Brightness.dark,
      scale: 3.1,
      locale: const Locale('it'),
    );
    await t.scrollUntilVisible(
      find.byKey(_entry),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final l = AppLocalizations.of(t.element(find.byKey(_entry)))!;
    final heading = find.text(l.homeBriefingTitle);
    expect(
      t.getSize(heading).height,
      lessThanOrEqualTo(F.head.fontSize! * F.head.height! * 3.1 * 2 + 1),
      reason: 'The New label must not squeeze a title into narrow fragments.',
    );
    expect(find.text(l.homeBriefingNew), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('briefing renders Markdown and keeps regeneration compact', (
    t,
  ) async {
    final b = _briefing(
      breakdown:
          '**Recovery** looks steady.\n\n'
          '## Today\n\n- Keep your usual pace.\n- Leave room for sleep.',
    );
    await mount(
      t,
      AiBriefingScreen(period: b.period, loadBriefing: (_, {day}) => b),
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is GptMarkdown && w.data == b.breakdownMd,
      ),
      findsOneWidget,
    );
    expect(find.text(b.breakdownMd), findsNothing);
    final action = find.byKey(const ValueKey('briefing-action'));
    expect(t.getSize(action).width, lessThan(260));
    expect(t.getSize(action).height, greaterThanOrEqualTo(S.tap));
    expect(find.byType(BigButton), findsNothing);
    expect(find.text('Write it again'), findsOneWidget);
    expect(find.text('Readiness'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('saved Markdown never downloads remote images', (t) async {
    const url = 'https://example.com/tracking.png';
    final b = _briefing(breakdown: 'A saved note.\n\n![Chart]($url)');
    await mount(
      t,
      AiBriefingScreen(period: b.period, loadBriefing: (_, {day}) => b),
    );
    expect(find.text(url), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'payload starts collapsed and reveals every exact input on demand',
    (t) async {
      final b = _briefing(
        inputs: {
          'readiness': 73,
          'missing': null,
          'nights': [431, 450],
        },
      );
      final semantics = t.ensureSemantics();
      await mount(
        t,
        AiBriefingScreen(period: b.period, loadBriefing: (_, {day}) => b),
      );
      final toggle = find.byKey(const ValueKey('briefing-payload-toggle'));
      expect(find.text('What was sent'), findsOneWidget);
      expect(find.text('Readiness'), findsNothing);
      expect(
        t.getSemantics(toggle).flagsCollection.isExpanded.toBoolOrNull(),
        isFalse,
      );
      await t.tap(toggle);
      await t.pumpAndSettle();
      expect(
        t.getSemantics(toggle).flagsCollection.isExpanded.toBoolOrNull(),
        isTrue,
      );
      for (final value in [
        'Readiness',
        '73',
        'Missing',
        'null',
        'Nights',
        '431, 450',
      ]) {
        expect(find.text(value), findsOneWidget);
      }
      await t.tap(toggle);
      await t.pumpAndSettle();
      expect(find.text('Readiness'), findsNothing);
      expect(find.textContaining('These numbers'), findsNothing);
      expect(
        t.getSemantics(toggle).flagsCollection.isExpanded.toBoolOrNull(),
        isFalse,
      );
      semantics.dispose();
    },
  );

  testWidgets('switching briefings collapses the previous payload', (t) async {
    final first = _briefing(day: '2026-09-23');
    final second = _briefing(day: '2026-09-24', inputs: {'readiness': 62});
    FutureOr<Briefing?> load(BriefingPeriod _, {String? day}) =>
        day == first.day ? first : second;
    await mount(
      t,
      AiBriefingScreen(
        period: first.period,
        day: first.day,
        loadBriefing: load,
      ),
    );
    await t.tap(find.byKey(const ValueKey('briefing-payload-toggle')));
    await t.pumpAndSettle();
    expect(find.text('73'), findsOneWidget);
    await mount(
      t,
      AiBriefingScreen(
        period: second.period,
        day: second.day,
        loadBriefing: load,
      ),
    );
    expect(find.text('Readiness'), findsNothing);
    await t.tap(find.byKey(const ValueKey('briefing-payload-toggle')));
    await t.pumpAndSettle();
    expect(find.text('62'), findsOneWidget);
    expect(find.text('73'), findsNothing);
  });

  testWidgets('disclosure animates without layout errors in both directions', (
    t,
  ) async {
    final b = _briefing();
    await mount(
      t,
      AiBriefingScreen(period: b.period, loadBriefing: (_, {day}) => b),
      reduced: false,
    );
    final toggle = find.byKey(const ValueKey('briefing-payload-toggle'));
    for (var i = 0; i < 2; i++) {
      await t.tap(toggle);
      await t.pump();
      await t.pump(Motion.fast);
      expect(t.takeException(), isNull);
      await t.pumpAndSettle();
    }
    expect(find.text('Readiness'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('detail and disclosure reflow at large text in $brightness', (
      t,
    ) async {
      final b = _briefing(
        breakdown: '**Recovery** looks steady.\n\nKeep your usual pace today.',
        inputs: {'resting_heart_rate': 51, 'sleep_minutes': 431},
      );
      await mount(
        t,
        AiBriefingScreen(period: b.period, loadBriefing: (_, {day}) => b),
        scale: 3.1,
        brightness: brightness,
      );
      final toggle = find.byKey(const ValueKey('briefing-payload-toggle'));
      await t.scrollUntilVisible(toggle, 300);
      await t.tap(toggle);
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('431'), 300);
      expect(find.text('Resting heart rate'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.ensureVisible(toggle);
      await t.tap(toggle);
      await t.pumpAndSettle();
      expect(find.text('431'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  for (final reduced in [false, true]) {
    testWidgets('read palette uses the motion gate (reduced=$reduced)', (
      t,
    ) async {
      final b = _briefing();
      BriefingStore.write(b);
      await mount(
        t,
        Scaffold(body: HomeScreen(data: _home())),
        reduced: reduced,
      );
      final p = P.of(t.element(find.byKey(_entry)));
      final tinted = Color.alphaBlend(p.wash(kCoachAccent), p.card);
      final before = t.widget<AnimatedContainer>(find.byKey(_surface));
      expect((before.decoration! as BoxDecoration).color, tinted);
      expect(before.duration, reduced ? Duration.zero : Motion.slow);
      await BriefingStore.markRead(b);
      app.briefingUpdated();
      await t.pump();
      final after = t.widget<AnimatedContainer>(find.byKey(_surface));
      expect((after.decoration! as BoxDecoration).color, p.card);
      expect(after.duration, reduced ? Duration.zero : Motion.slow);
      await t.pumpAndSettle();
      expect(find.text('New'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }
}
