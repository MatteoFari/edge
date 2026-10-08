import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav;
import 'package:openstrap_edge/ui2/ui2.dart';

const _measured = HomeData(
  readiness: Metric(value: 73),
  sleepMin: Metric(value: 431),
  sleepNeedMin: Metric(value: 487),
  strain: Metric(value: 12.4),
  rhr: Metric(value: 51),
  steps: Metric(value: 2432),
  calories: Metric(value: 350),
);

Widget _frame(
  Widget child, {
  InterfaceStyle style = InterfaceStyle.expressive,
  double scale = 1,
  Brightness brightness = Brightness.light,
  AppState? app,
  NavigatorObserver? observer,
  Locale locale = const Locale('en'),
  bool reduceMotion = false,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<ThemeController>(
      create: (_) => ThemeController.seed(
        AppThemeChoice.light,
        brightness,
        interfaceStyle: style,
      ),
    ),
    ChangeNotifierProvider<LocaleController>(
      create: (_) => LocaleController.seed(locale.languageCode),
    ),
    if (app != null) ChangeNotifierProvider<AppState>.value(value: app),
  ],
  child: MaterialApp(
    theme: buildTheme(brightness, style: style),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    navigatorObservers: [?observer],
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduceMotion,
      ),
      child: child!,
    ),
    home: Scaffold(body: child),
  ),
);

Widget _metrics(HomeData d) => SingleChildScrollView(
  padding: const EdgeInsets.all(S.x4),
  child: RingTrio(d: d),
);

T _painter<T extends CustomPainter>(WidgetTester t) =>
    t
            .widget<CustomPaint>(
              find.byWidgetPredicate((w) => w is CustomPaint && w.painter is T),
            )
            .painter!
        as T;

class _Repo extends LocalRepository {
  final bool fail;
  _Repo({this.fail = false});

  @override
  Future<Map<String, dynamic>> getToday() async {
    if (fail) throw StateError('read failed');
    return {
      'daily': {
        'readiness': {'value': 73},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<int> pendingActivityCount() async => 1;
  @override
  Future<List<String>> availableDays() async => [todayLabel()];
}

class _AlarmApp extends AppState {
  final DateTime? at;
  final AlarmArmState state;
  final List<AlarmScheduleEntry> schedule;
  int writes = 0;

  _AlarmApp({
    this.at,
    this.state = AlarmArmState.none,
    this.schedule = const [],
    bool fail = false,
  }) : super.forTesting() {
    repo = _Repo(fail: fail);
  }

  @override
  int? get alarmEpoch => at == null ? null : at!.millisecondsSinceEpoch ~/ 1000;
  @override
  bool get alarmConfirmed => state == AlarmArmState.confirmed;
  @override
  bool get alarmPending => state == AlarmArmState.pending;
  @override
  List<AlarmScheduleEntry> get alarmSchedule => schedule;
  @override
  Future<void> setAlarm(DateTime when) async => writes++;
  @override
  Future<void> disableAlarm() async => writes++;
}

class _Routes extends NavigatorObserver {
  final names = <String?>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}

class _HeaderApp extends AppState {
  bool syncing = false;
  bool analyzing = false;
  bool pending = false;
  String connection = 'connected';
  DateTime? frontier;
  int syncRequests = 0;

  _HeaderApp() : super.forTesting();

  @override
  Future<void> syncNow() async => syncRequests++;
  @override
  bool get syncingNow => syncing;
  @override
  bool get deriving => analyzing;
  @override
  bool get derivePending => pending;
  @override
  String get status => connection;
  @override
  DateTime? get lastRecordAt => frontier;
}

Widget _header({ValueChanged<String>? onDay}) => SingleChildScrollView(
  padding: const EdgeInsets.all(S.x4),
  child: ExpressiveHomeHeader(
    day: '2026-10-07',
    days: const ['2026-10-07', '2026-10-06', '2026-10-05'],
    onDay: onDay ?? (_) {},
  ),
);

void main() {
  setUpAll(() async {
    // Match Android's bundled face: Ahem's square glyphs hide tight-fit bugs.
    for (final family in ['.SF Pro Text', 'Manrope']) {
      final loader = FontLoader(family);
      loader.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-400.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-600.ttf'));
      await loader.load();
    }
  });
  setUp(() => ClockFormatController.seed(ClockFormat.h24));
  tearDown(ClockFormatController.debugReset);

  testWidgets('Expressive replaces the greeting with date and sync status', (
    t,
  ) async {
    final routes = _Routes();
    await t.pumpWidget(
      _frame(const HomeScreen(data: _measured, hour: 15), observer: routes),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('Good afternoon'), findsNothing);
    expect(find.byKey(const ValueKey('home-sync-status')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-day-picker')), findsOneWidget);
    expect(find.byType(DayNav), findsNothing);
    expect(find.text('No band data yet'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is Pressable && w.semanticLabel == 'No band data yet',
      ),
      findsOneWidget,
    );
    await t.tap(find.bySemanticsLabel('Profile and settings'));
    await t.pumpAndSettle();
    expect(routes.names.last, 'ProfileHome');
  });

  testWidgets('Original retains its existing greeting', (t) async {
    await t.pumpWidget(
      _frame(
        const HomeScreen(data: _measured, hour: 15),
        style: InterfaceStyle.original,
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Good afternoon'), findsOneWidget);
    expect(find.byType(ExpressiveHomeHeader), findsNothing);
  });

  testWidgets('sync pill follows real phases and never claims completion', (
    t,
  ) async {
    final app = _HeaderApp()..connection = 'disconnected';
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(_header(), app: app));
    await t.pumpAndSettle();
    expect(find.text('No band data yet'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is Pressable && w.semanticLabel == 'Offline. No band data yet',
      ),
      findsOneWidget,
    );

    app.connection = 'connecting';
    app.notifyListeners();
    await t.pump();
    expect(find.text('Connecting'), findsOneWidget);
    app.syncing = true;
    app.analyzing = true;
    app.frontier = DateTime(2026, 10, 7, 11, 6);
    app.notifyListeners();
    await t.pump();
    expect(find.text('Syncing'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    app.syncing = false;
    app.notifyListeners();
    await t.pump();
    expect(find.text('Processing'), findsOneWidget);
    app.analyzing = false;
    app.connection = 'connected';
    app.notifyListeners();
    await t.pumpAndSettle();
    expect(find.text('Synced through 11:06'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Pressable &&
            w.semanticLabel == 'Sync complete. Synced through 11:06',
      ),
      findsOneWidget,
    );
    expect(
      t.getSize(find.byKey(const ValueKey('home-sync-surface'))),
      const Size(S.tap, S.tap),
    );
    expect(find.text('Sync complete'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    app.connection = 'disconnected';
    app.notifyListeners();
    await t.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    expect(find.byIcon(LucideIcons.check), findsNothing);
    // Losing the link never changes the saved data frontier.
    expect(app.frontier, DateTime(2026, 10, 7, 11, 6));
  });

  testWidgets('sync circle morphs beside the smaller date and fixed settings', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 850);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(_header(), app: app));
    await t.pumpAndSettle();
    final status = find.byKey(const ValueKey('home-sync-surface'));
    final date = find.byKey(const ValueKey('home-day-picker'));
    final settings = find.byWidgetPredicate(
      (w) => w is Pressable && w.semanticLabel == 'Profile and settings',
    );
    final settingsBefore = t.getRect(settings);
    final dayBefore = t.getRect(date);
    expect(t.getSize(status), const Size(S.tap, S.tap));
    expect(t.getCenter(status).dy, closeTo(t.getCenter(date).dy, 1));
    expect(t.getCenter(settings).dy, closeTo(t.getCenter(date).dy, 1));
    expect(t.getRect(status).left, greaterThan(dayBefore.right));
    expect(find.byIcon(LucideIcons.check), findsOneWidget);

    app.syncing = true;
    app.notifyListeners();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final midWidth = t.getSize(status).width;
    expect(midWidth, greaterThan(S.tap));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Syncing'), findsOneWidget);
    expect(t.getRect(settings).left, closeTo(settingsBefore.left, .001));
    expect(t.getRect(settings).top, closeTo(settingsBefore.top, .001));
    expect(t.getRect(date).width, lessThan(dayBefore.width));
    final dayText = t.widget<Text>(
      find.byKey(const ValueKey('home-day-month')),
    );
    expect(dayText.style!.fontSize, F.head.fontSize);
    expect(dayText.data, isIn(['7 October', '7 Oct']));

    app.syncing = false;
    app.notifyListeners();
    await t.pump();
    expect(t.getSize(status).width, greaterThan(S.tap));
    await t.pumpAndSettle();
    expect(t.getSize(status), const Size(S.tap, S.tap));
    expect(t.getRect(settings).left, closeTo(settingsBefore.left, .001));
    expect(t.getRect(settings).top, closeTo(settingsBefore.top, .001));
    expect(t.takeException(), isNull);
  });

  testWidgets('syncing and processing stay on one line throughout the morph', (
    t,
  ) async {
    t.view.physicalSize = const Size(384, 850);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(_header(), app: app));
    await t.pumpAndSettle();
    final date = find.byKey(const ValueKey('home-day-picker'));
    final settings = find.byWidgetPredicate(
      (w) => w is Pressable && w.semanticLabel == 'Profile and settings',
    );
    final before = t.getRect(settings);
    for (final phase in ['Syncing', 'Processing']) {
      app.syncing = phase == 'Syncing';
      app.analyzing = phase == 'Processing';
      app.notifyListeners();
      await t.pump();
      for (var frame = 0; frame < 30; frame++) {
        await t.pump(const Duration(milliseconds: 16));
        final word = t.widget<Text>(find.text(phase));
        expect(word.maxLines, 1);
        expect(word.softWrap, isFalse);
        expect(
          t.renderObject<RenderParagraph>(find.text(phase)).didExceedMaxLines,
          isFalse,
          reason: '$phase must not be ellipsized with the real Android font',
        );
        final paragraph = t.renderObject<RenderParagraph>(find.text(phase));
        for (final glyphs in paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: phase.length),
        )) {
          expect(
            glyphs.right,
            lessThanOrEqualTo(paragraph.size.width + .5),
            reason: 'Every glyph must fit, even without an ellipsis',
          );
        }
        expect(
          t.getSize(find.text(phase)).height,
          lessThan(
            t.getSize(find.byKey(const ValueKey('home-sync-surface'))).height,
          ),
        );
        expect(t.getRect(settings).left, closeTo(before.left, .001));
        expect(t.getRect(settings).top, closeTo(before.top, .001));
        expect(t.getCenter(date).dy, closeTo(t.getCenter(settings).dy, 1));
        expect(t.takeException(), isNull);
      }
    }
    app.analyzing = false;
    app.notifyListeners();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-day-weekday')), findsOneWidget);
    expect(
      t
          .widget<Text>(find.byKey(const ValueKey('home-day-month')))
          .style!
          .fontSize,
      F.head.fontSize,
    );
  });

  testWidgets(
    'date width eases in both directions without wrapping on the phone',
    (t) async {
      t.view.physicalSize = const Size(384, 850);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
      addTearDown(app.dispose);
      await t.pumpWidget(_frame(_header(), app: app));
      await t.pumpAndSettle();
      final dateSize = find.byKey(const ValueKey('home-day-label-size'));
      final before = t.getSize(dateSize);
      final month = find.byKey(const ValueKey('home-day-month'));
      final originalMonth = t.element(month);
      final monthBefore = t.getTopLeft(month);
      app.syncing = true;
      app.notifyListeners();
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      final during = t.getSize(dateSize);
      final monthDuring = t.getTopLeft(month);
      await t.pump(const Duration(milliseconds: 550));
      final compact = t.getSize(dateSize);
      expect(during.width, lessThan(before.width));
      expect(during.width, greaterThan(compact.width));
      expect(during.height, before.height);
      expect(monthDuring.dx, lessThan(monthBefore.dx));
      expect(monthDuring.dx, greaterThan(t.getTopLeft(month).dx));
      expect(t.getTopLeft(month).dy, monthBefore.dy);
      expect(t.element(month), same(originalMonth));
      expect(
        t
            .widget<Opacity>(
              find.ancestor(
                of: find.byKey(const ValueKey('home-day-weekday')),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        0,
      );
      app.syncing = false;
      app.notifyListeners();
      await t.pump();
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 16));
        expect(t.getSize(dateSize).height, before.height);
        expect(t.widget<Text>(month).softWrap, isFalse);
      }
      await t.pumpAndSettle();
      expect(t.getSize(dateSize), before);
      expect(t.getTopLeft(month), monthBefore);
      expect(t.element(month), same(originalMonth));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'full status glyphs fit with Android fonts on narrow and scaled screens',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final app = _HeaderApp();
      addTearDown(app.dispose);
      app.device.batteryPct = 100;
      app.device.charging = false;
      for (final width in [320.0, 384.0]) {
        t.view.physicalSize = Size(width, 1000);
        for (final scale in [1.0, 2.0, 3.1]) {
          for (final locale in [
            const Locale('en'),
            const Locale('de'),
            const Locale('fr'),
          ]) {
            for (final phase in ['sync', 'processing', 'connecting', 'fault']) {
              app.syncing = phase == 'sync';
              app.analyzing = phase == 'processing';
              app.connection = phase == 'connecting'
                  ? 'connecting'
                  : 'disconnected';
              app.device.syncChunkQuarantined = phase == 'fault';
              await t.pumpWidget(
                _frame(
                  _header(),
                  app: app,
                  scale: scale,
                  locale: locale,
                  reduceMotion: true,
                ),
              );
              await t.pumpAndSettle();
              final control = find.byKey(const ValueKey('home-sync-status'));
              final text = find.descendant(
                of: control,
                matching: find.byType(Text),
              );
              final word = t.widget<Text>(text).data!;
              final paragraph = t.renderObject<RenderParagraph>(text);
              expect(paragraph.didExceedMaxLines, isFalse);
              // A wrapped line's trailing spaces can extend beyond its box;
              // check visible words rather than selecting that blank advance.
              for (final part in RegExp(r'\S+').allMatches(word)) {
                for (final box in paragraph.getBoxesForSelection(
                  TextSelection(baseOffset: part.start, extentOffset: part.end),
                )) {
                  expect(
                    box.right,
                    lessThanOrEqualTo(paragraph.size.width + .5),
                    reason: '$word at $width, $scale, $locale',
                  );
                }
              }
              final surface = t.getRect(
                find.byKey(const ValueKey('home-sync-surface')),
              );
              final bounds = t.getRect(text);
              expect(bounds.right, lessThanOrEqualTo(surface.right));
              expect(bounds.bottom, lessThanOrEqualTo(surface.bottom));
              expect(t.takeException(), isNull);
            }
          }
        }
      }
    },
  );

  testWidgets(
    'sync phase colors animate through saved, busy, error and no data',
    (t) async {
      final app = _HeaderApp();
      addTearDown(app.dispose);
      await t.pumpWidget(_frame(_header(), app: app));
      await t.pumpAndSettle();
      final fill = find.byKey(const ValueKey('home-sync-fill'));
      Color painted() =>
          (t
                      .widget<DecoratedBox>(
                        find.descendant(
                          of: fill,
                          matching: find.byType(DecoratedBox),
                        ),
                      )
                      .decoration
                  as BoxDecoration)
              .color!;
      final p = P.of(t.element(fill));
      Color expected(Color? accent) =>
          accent == null ? p.card2 : Color.alphaBlend(p.wash(accent), p.card2);
      expect(painted(), p.card2);
      for (final entry in [
        ('sync', C.blue),
        ('processing', C.purple),
        ('saved', C.green),
        ('fault', C.red),
        ('never', null),
      ]) {
        final previous = painted();
        app.syncing = entry.$1 == 'sync';
        app.analyzing = entry.$1 == 'processing';
        app.frontier = entry.$1 == 'never'
            ? null
            : DateTime(2026, 10, 7, 11, 6);
        app.device.syncChunkQuarantined = entry.$1 == 'fault';
        app.notifyListeners();
        await t.pump();
        expect(painted(), previous);
        await t.pump(const Duration(milliseconds: 90));
        expect(painted(), isNot(previous));
        expect(painted(), isNot(expected(entry.$2)));
        await t.pump(const Duration(milliseconds: 500));
        expect(painted(), expected(entry.$2));
        expect(t.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'sync faults stay visible beside the date without claiming success',
    (t) async {
      final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
      addTearDown(app.dispose);
      await t.pumpWidget(_frame(_header(), app: app));
      await t.pumpAndSettle();
      app.device.syncChunkQuarantined = true;
      app.notifyListeners();
      await t.pumpAndSettle();
      expect(find.text('Sync error'), findsOneWidget);
      expect(find.byIcon(LucideIcons.circleAlert), findsOneWidget);
      expect(find.byIcon(LucideIcons.check), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Tooltip &&
              (w.message ?? '').contains('One batch of recordings'),
        ),
        findsOneWidget,
      );
      app.device.syncChunkQuarantined = false;
      app.notifyListeners();
      await t.pumpAndSettle();
      expect(find.text('Sync error'), findsNothing);
      expect(
        t.getSize(find.byKey(const ValueKey('home-sync-surface'))),
        const Size(S.tap, S.tap),
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'header date picker still opens the existing restricted calendar',
    (t) async {
      String? selected;
      await t.pumpWidget(_frame(_header(onDay: (day) => selected = day)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-day-weekday')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-day-month')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('home-day-picker')));
      await t.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await t.tap(find.text('6'));
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(selected, '2026-10-06');
    },
  );

  testWidgets(
    'header fits narrow screens and large text, with reduced motion',
    (t) async {
      t.view.physicalSize = const Size(320, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final app = _HeaderApp()..syncing = true;
      addTearDown(app.dispose);
      for (final brightness in Brightness.values) {
        for (final locale in [
          const Locale('en'),
          const Locale('de'),
          const Locale('zh'),
        ]) {
          await t.pumpWidget(
            _frame(
              _header(),
              app: app,
              brightness: brightness,
              locale: locale,
              scale: 3.1,
              reduceMotion: true,
            ),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          for (final target in t.elementList(find.byType(Pressable))) {
            final rect = t.getRect(find.byWidget(target.widget));
            expect(rect.width, greaterThanOrEqualTo(S.tap));
            expect(rect.height, greaterThanOrEqualTo(S.tap));
          }
        }
      }
    },
  );

  testWidgets('battery stays in the row, collapses during sync and restores', (
    t,
  ) async {
    t.view.physicalSize = const Size(384, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
    app.device.batteryPct = 75;
    app.device.charging = false;
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(_header(), app: app));
    await t.pumpAndSettle();
    final battery = find.byKey(const ValueKey('home-battery-surface'));
    final sync = find.byKey(const ValueKey('home-sync-surface'));
    final date = find.byKey(const ValueKey('home-day-picker'));
    final label = find.byKey(const ValueKey('home-battery-label'));
    final fullWidth = t.getSize(battery).width;
    double opacity() => t
        .widget<AnimatedOpacity>(
          find.ancestor(of: label, matching: find.byType(AnimatedOpacity)),
        )
        .opacity;
    expect(fullWidth, greaterThan(S.tap));
    expect(opacity(), 1);
    final fontSize = t
        .widget<Text>(find.byKey(const ValueKey('home-day-month')))
        .style!
        .fontSize;
    final month = t.getTopLeft(find.byKey(const ValueKey('home-day-month')));
    for (final phase in ['sync', 'processing', 'error', 'offline']) {
      app.syncing = phase == 'sync';
      app.analyzing = phase == 'processing';
      app.device.syncChunkQuarantined = phase == 'error';
      app.connection = phase == 'offline' ? 'disconnected' : 'connected';
      app.notifyListeners();
      await t.pump();
      for (var frame = 0; frame < 35; frame++) {
        await t.pump(const Duration(milliseconds: 16));
        expect(t.takeException(), isNull);
        expect(t.getCenter(battery).dy, closeTo(t.getCenter(sync).dy, .001));
        expect(t.getCenter(date).dy, closeTo(t.getCenter(sync).dy, .001));
      }
      expect(t.getSize(battery), const Size(S.tap, S.tap));
      expect(opacity(), 0);
      expect(
        t
            .widget<Text>(find.byKey(const ValueKey('home-day-month')))
            .style!
            .fontSize,
        fontSize,
      );
      expect(
        t.getTopLeft(find.byKey(const ValueKey('home-day-month'))).dx,
        lessThan(month.dx),
      );
    }
    app.connection = 'connected';
    app.notifyListeners();
    await t.pumpAndSettle();
    expect(t.getSize(battery).width, fullWidth);
    expect(opacity(), 1);
    expect(t.getTopLeft(find.byKey(const ValueKey('home-day-month'))), month);
    expect(t.getSize(sync), const Size(S.tap, S.tap));
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
    final scroll = t.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('home-header-row-scroll')),
    );
    expect(
      t.getSize(find.byKey(const ValueKey('home-header-row'))).width,
      t.getSize(find.byWidget(scroll)).width,
    );
  });

  testWidgets(
    'battery uses real levels, charge state and theme-aware thresholds',
    (t) async {
      final app = _HeaderApp();
      addTearDown(app.dispose);
      for (final brightness in Brightness.values) {
        await t.pumpWidget(_frame(_header(), app: app, brightness: brightness));
        for (final entry in [
          (75.0, null),
          (20.0, null),
          (19.9, C.yellow),
          (10.0, C.yellow),
          (9.9, C.red),
          (0.0, C.red),
        ]) {
          app.device.batteryPct = entry.$1;
          app.device.charging = false;
          app.notifyListeners();
          await t.pumpAndSettle();
          final fill = find.byKey(const ValueKey('home-battery-fill'));
          final p = P.of(t.element(fill));
          final painted =
              (t
                          .widget<DecoratedBox>(
                            find.descendant(
                              of: fill,
                              matching: find.byType(DecoratedBox),
                            ),
                          )
                          .decoration
                      as BoxDecoration)
                  .color;
          expect(
            painted,
            entry.$2 == null
                ? p.card2
                : Color.alphaBlend(p.wash(entry.$2!), p.card2),
          );
          expect(find.text('${entry.$1.round()}%'), findsOneWidget);
        }
        app.device.charging = true;
        app.notifyListeners();
        await t.pumpAndSettle();
        expect(find.byIcon(LucideIcons.batteryCharging), findsOneWidget);
        expect(find.bySemanticsLabel('Battery. 0%. Charging'), findsOneWidget);
      }
    },
  );

  testWidgets('unknown battery never becomes zero and opens the band screen', (
    t,
  ) async {
    final app = _HeaderApp();
    addTearDown(app.dispose);
    final routes = _Routes();
    for (final invalid in [null, double.nan, -1.0, 101.0]) {
      app.device.batteryPct = invalid;
      await t.pumpWidget(_frame(_header(), app: app, observer: routes));
      app.notifyListeners();
      await t.pumpAndSettle();
      expect(find.text('0%'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Battery. Not reported since the last connection',
        ),
        findsOneWidget,
      );
    }
    app.device.batteryPct = 63;
    app.device.charging = null;
    app.notifyListeners();
    await t.pumpAndSettle();
    expect(find.text('63%'), findsOneWidget);
    expect(find.byIcon(LucideIcons.batteryCharging), findsNothing);
    await t.tap(find.byKey(const ValueKey('home-battery-status')));
    await t.pumpAndSettle();
    expect(routes.names.last, 'MyDevices');
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'successful sync settles gently while settings stays a bare icon',
    (t) async {
      final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
      addTearDown(app.dispose);
      await t.pumpWidget(_frame(_header(), app: app));
      await t.pumpAndSettle();
      final surface = find.byKey(const ValueKey('home-sync-surface'));
      final control = find.byKey(const ValueKey('home-sync-status'));
      final target = t.getRect(control);
      Color fill() =>
          (t
                      .widget<DecoratedBox>(
                        find.descendant(
                          of: find.byKey(const ValueKey('home-sync-fill')),
                          matching: find.byType(DecoratedBox),
                        ),
                      )
                      .decoration
                  as BoxDecoration)
              .color!;
      final initialColor = fill();
      expect(t.getSize(surface), const Size(S.tap, S.tap));
      await t.pump(Motion.statusSettle);
      await t.pump(const Duration(milliseconds: 90));
      expect(t.getSize(surface).width, lessThan(S.tap));
      expect(t.getSize(surface).width, greaterThan(S.x10 - S.x1));
      await t.pumpAndSettle();
      expect(t.getSize(surface), const Size(S.x10 - S.x1, S.x10 - S.x1));
      expect(fill(), isNot(initialColor));
      final p = P.of(t.element(surface));
      expect(fill(), Color.alphaBlend(p.wash(C.green, strength: .4), p.card2));
      expect(t.getRect(control), target);
      expect(find.byIcon(LucideIcons.check), findsOneWidget);
      final settings = find.byKey(const ValueKey('home-settings-icon'));
      expect(t.widget<Icon>(settings).size, S.navIcon);
      final settingsControl = find.ancestor(
        of: settings,
        matching: find.byType(Pressable),
      );
      expect(
        find.descendant(
          of: settingsControl,
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
      expect(t.getSize(settingsControl), const Size(S.tap, S.tap));
      app.syncing = true;
      app.notifyListeners();
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(t.getSize(surface).width, greaterThan(S.x10 - S.x1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('settle delay is cancelled by real state changes and disposal', (
    t,
  ) async {
    final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(_header(), app: app));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 3));
    app.connection = 'disconnected';
    app.notifyListeners();
    await t.pump();
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    final p = P.of(t.element(find.byKey(const ValueKey('home-sync-fill'))));
    expect(
      (t
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byKey(const ValueKey('home-sync-fill')),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration)
          .color,
      p.card2,
    );
    app.connection = 'connected';
    app.notifyListeners();
    await t.pumpAndSettle();
    expect(
      t.getSize(find.byKey(const ValueKey('home-sync-surface'))),
      const Size(S.tap, S.tap),
    );
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 6));
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'reduced motion keeps the settle delay and changes without animation',
    (t) async {
      final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
      addTearDown(app.dispose);
      await t.pumpWidget(_frame(_header(), app: app, reduceMotion: true));
      await t.pumpAndSettle();
      final surface = find.byKey(const ValueKey('home-sync-surface'));
      expect(t.getSize(surface), const Size(S.tap, S.tap));
      await t.pump(Motion.statusSettle);
      await t.pump();
      expect(t.getSize(surface), const Size(S.x10 - S.x1, S.x10 - S.x1));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('queued compute stays quiet until processing actually runs', (
    t,
  ) async {
    final app = _HeaderApp()
      ..frontier = DateTime(2026, 10, 7, 11, 6)
      ..pending = true;
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(_header(), app: app, reduceMotion: true));
    await t.pumpAndSettle();
    expect(find.text('Processing'), findsNothing);
    expect(find.byIcon(LucideIcons.check), findsOneWidget);

    app.analyzing = true;
    app.notifyListeners();
    await t.pumpAndSettle();
    expect(find.text('Processing'), findsOneWidget);

    app.analyzing = false;
    app.notifyListeners();
    await t.pumpAndSettle();
    expect(find.text('Processing'), findsNothing);
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
  });

  testWidgets('pull to refresh wakes a settled check and requests real sync', (
    t,
  ) async {
    final app = _HeaderApp()..frontier = DateTime(2026, 10, 7, 11, 6);
    addTearDown(app.dispose);
    await t.pumpWidget(_frame(const HomeScreen(data: _measured), app: app));
    await t.pumpAndSettle();
    final surface = find.byKey(const ValueKey('home-sync-surface'));
    await t.pump(Motion.statusSettle);
    await t.pumpAndSettle();
    expect(t.getSize(surface).width, S.x10 - S.x1);
    await t.drag(find.byType(ListView).first, const Offset(0, 400));
    await t.pumpAndSettle();
    expect(app.syncRequests, 1);
    expect(t.getSize(surface), const Size(S.tap, S.tap));
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
    await t.pump(Motion.statusSettle);
    await t.pumpAndSettle();
    expect(t.getSize(surface).width, S.x10 - S.x1);
    expect(t.takeException(), isNull);
  });

  testWidgets('Original keeps the existing trio and measured values', (
    t,
  ) async {
    await t.pumpWidget(
      _frame(_metrics(_measured), style: InterfaceStyle.original),
    );
    expect(find.byKey(const ValueKey('expressive-recovery')), findsNothing);
    expect(find.text('73'), findsOneWidget);
    expect(find.text('7h 11m'), findsOneWidget);
    expect(find.text('12.4'), findsOneWidget);
    final rings = t
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((w) => w.painter is Ring);
    expect(rings, hasLength(3));
  });

  testWidgets('Expressive uses the same exact readings and denominators', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(_frame(_metrics(_measured)));
    expect(find.text('73'), findsOneWidget);
    expect(find.text('7h 11m'), findsOneWidget);
    expect(find.text('of 8h 07m'), findsOneWidget);
    expect(find.text('12.4'), findsOneWidget);
    expect(find.text('of 21'), findsOneWidget);
    expect(_painter<ExpressiveRecoveryGauge>(t).fraction, .73);
    expect(
      _painter<ExpressiveSleepMeter>(t).fraction,
      closeTo(431 / 487, 1e-10),
    );
    expect(
      _painter<ExpressiveStrainSegments>(t).fraction,
      closeTo(12.4 / 21, 1e-10),
    );
    expect(find.bySemanticsLabel('Sleep. 7h 11m. of 8h 07m'), findsOneWidget);
    final metricPaints = find.descendant(
      of: find.byType(RingTrio),
      matching: find.byType(CustomPaint),
    );
    // Framework chrome may also use CustomPaint outside the metric group.
    expect(metricPaints, findsNWidgets(3));
    for (final paint in t.elementList(metricPaints)) {
      expect(paint.findAncestorWidgetOfExactType<RepaintBoundary>(), isNotNull);
    }
    semantics.dispose();
  });

  testWidgets('Sleep and Strain align even when an absence explanation wraps', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    for (final data in [
      _measured,
      const HomeData(
        sleepMin: Metric(note: 'The overnight readings have not arrived yet.'),
        strain: Metric(value: 12.4),
      ),
    ]) {
      await t.pumpWidget(_frame(_metrics(data)));
      final sleep = t.getRect(find.byKey(const ValueKey('expressive-sleep')));
      final strain = t.getRect(find.byKey(const ValueKey('expressive-strain')));
      expect(sleep.top, closeTo(strain.top, .001));
      expect(sleep.bottom, closeTo(strain.bottom, .001));
      expect(t.takeException(), isNull);
    }
  });

  testWidgets(
    'sleep without a computed need has an empty track and no invented target',
    (t) async {
      await t.pumpWidget(
        _frame(_metrics(const HomeData(sleepMin: Metric(value: 431)))),
      );
      expect(find.text('7h 11m'), findsOneWidget);
      expect(find.text('No target yet'), findsOneWidget);
      expect(_painter<ExpressiveSleepMeter>(t).fraction, isNull);
      expect(find.textContaining('8h 00m'), findsNothing);
    },
  );

  testWidgets(
    'absent values keep their reasons and calibration uses its real night count',
    (t) async {
      await t.pumpWidget(
        _frame(
          _metrics(
            const HomeData(
              readiness: Metric(note: 'need_baseline:have=2,need=9'),
              sleepMin: Metric(note: 'The night has not arrived.'),
              strain: Metric(note: 'No activity records arrived.'),
            ),
          ),
        ),
      );
      expect(find.text('Calibrating'), findsOneWidget);
      expect(find.text('2 of 9 nights'), findsOneWidget);
      final dashed = _painter<DashedRing>(t);
      expect(dashed.segments, 9);
      expect(dashed.v, closeTo(2 / 9, 1e-10));
      expect(_painter<ExpressiveSleepMeter>(t).fraction, isNull);
      expect(_painter<ExpressiveStrainSegments>(t).fraction, isNull);
      expect(find.text('No sleep'), findsOneWidget);
      expect(find.text('The night has not arrived.'), findsOneWidget);
      expect(find.text('No activity records arrived.'), findsOneWidget);
      expect(find.text('—'), findsNothing);
      expect(find.text('0'), findsNothing);
    },
  );

  testWidgets('all three metric cards preserve their detail navigation', (
    t,
  ) async {
    final routes = _Routes();
    await t.pumpWidget(
      _frame(const HomeScreen(data: _measured, hour: 9), observer: routes),
    );
    for (final entry in {
      'recovery': 'ReadinessDetail',
      'sleep': 'SleepDetail',
      'strain': 'DayStrainDetail',
    }.entries) {
      final card = find.byKey(ValueKey('expressive-${entry.key}'));
      await t.ensureVisible(card);
      await t.tap(card);
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('expanded-${entry.key}')), findsOneWidget);
      await t.tap(find.text('Full details'));
      await t.pumpAndSettle();
      expect(routes.names.last, entry.value);
      Navigator.of(
        t.element(find.byType(HomeScreen, skipOffstage: false)),
      ).pop();
      await t.pumpAndSettle();
      expect(find.byKey(ValueKey('expanded-${entry.key}')), findsOneWidget);
      await t.tap(
        find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == 'Close summary',
        ),
      );
      await t.pumpAndSettle();
    }
  });

  testWidgets(
    'the next alarm follows metrics, then activities, then At a glance',
    (t) async {
      t.view.physicalSize = const Size(390, 1800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final app = _AlarmApp();
      addTearDown(app.dispose);
      await t.pumpWidget(
        _frame(const HomeScreen(data: _measured, hour: 9), app: app),
      );
      await t.pumpAndSettle();
      final strain = t
          .getBottomLeft(find.byKey(const ValueKey('expressive-strain')))
          .dy;
      final alarm = t
          .getTopLeft(find.byKey(const ValueKey('home-next-alarm')))
          .dy;
      final activity = t.getTopLeft(find.text('Detected activities')).dy;
      final glance = t.getTopLeft(find.text('At a glance')).dy;
      expect(strain, lessThan(alarm));
      expect(alarm, lessThan(activity));
      expect(activity, lessThan(glance));
      final text = t.getRect(find.byKey(const ValueKey('home-alarm-text')));
      for (final key in ['home-alarm-icon', 'home-alarm-chevron']) {
        expect(
          t.getRect(find.byKey(ValueKey(key))).center.dy,
          closeTo(text.center.dy, .1),
        );
      }
      expect(app.writes, 0);
    },
  );

  testWidgets(
    'alarm card reads each current confirmation state without writes',
    (t) async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      for (final state in [
        AlarmArmState.pending,
        AlarmArmState.confirmed,
        AlarmArmState.unknown,
      ]) {
        final app = _AlarmApp(at: tomorrow, state: state);
        addTearDown(app.dispose);
        await t.pumpWidget(
          _frame(
            HomeScreen(key: ValueKey(state), data: _measured),
            app: app,
          ),
        );
        await t.ensureVisible(find.byKey(const ValueKey('home-next-alarm')));
        expect(find.text(AlarmScreenView.stateLabel(state)), findsOneWidget);
        expect(app.writes, 0);
      }
    },
  );

  testWidgets(
    'a past confirmed alarm stays past and a schedule alone stays unarmed',
    (t) async {
      final past = _AlarmApp(
        at: DateTime.now().subtract(const Duration(hours: 1)),
        state: AlarmArmState.confirmed,
      );
      addTearDown(past.dispose);
      await t.pumpWidget(_frame(const HomeScreen(data: _measured), app: past));
      await t.ensureVisible(find.byKey(const ValueKey('home-next-alarm')));
      expect(find.textContaining('In the past'), findsOneWidget);
      expect(find.text('Confirmed'), findsNothing);
      final scheduled = _AlarmApp(
        schedule: [
          AlarmScheduleEntry(
            weekday: DateTime.now().weekday % 7,
            hour: 7,
            minute: 15,
          ),
        ],
      );
      addTearDown(scheduled.dispose);
      await t.pumpWidget(
        _frame(const HomeScreen(data: _measured), app: scheduled),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('home-next-alarm')));
      expect(find.text('Weekly schedule'), findsOneWidget);
      final card = t.widget<Surface>(
        find.byKey(const ValueKey('home-next-alarm')),
      );
      expect(card.semanticLabel, contains('Weekly schedule'));
      expect(find.text('Not set'), findsOneWidget);
      expect(find.text('Confirmed'), findsNothing);
      expect(scheduled.writes, 0);
    },
  );

  testWidgets(
    'read failure retains the alarm card and its existing AlarmScreen route',
    (t) async {
      final app = _AlarmApp(fail: true);
      addTearDown(app.dispose);
      final routes = _Routes();
      await t.pumpWidget(
        _frame(const HomeScreen(), app: app, observer: routes),
      );
      await t.pumpAndSettle();
      expect(find.text('Today could not be read'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-next-alarm')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('home-next-alarm')));
      await t.pumpAndSettle();
      expect(routes.names.last, 'AlarmScreen');
      expect(find.byType(AlarmScreen), findsOneWidget);
      expect(app.writes, 0);
    },
  );

  testWidgets('metric cards fit 320 pt and 3.1x text in both themes', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    for (final brightness in Brightness.values) {
      for (final d in [
        _measured,
        const HomeData(readiness: Metric(note: 'need_baseline:have=2,need=9')),
      ]) {
        await t.pumpWidget(
          _frame(_metrics(d), scale: 3.1, brightness: brightness),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }
    }
  });
}
