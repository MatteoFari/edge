import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/weight_store.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/coach_action_presentation.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_presentation.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/weight_trend.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _it = lookupAppLocalizations(const Locale('it'));

Widget _host(Widget child, {LocaleController? locale, double scale = 1}) {
  final controller = locale ?? LocaleController.seed('it');
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<LocaleController>.value(value: controller),
      ChangeNotifierProvider<UnitsController>(
        create: (_) => UnitsController.seed(UnitSystem.metric),
      ),
    ],
    child: AnimatedBuilder(
      animation: controller,
      builder: (_, _) => MaterialApp(
        locale: controller.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: buildTheme(Brightness.light, style: InterfaceStyle.expressive),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(ClockFormatController.debugReset);

  setUpAll(() async {
    final files = Directory(
      'assets/fonts/Manrope',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'));
    for (final family in ['Manrope', '.SF Pro Text']) {
      final loader = FontLoader(family);
      for (final file in files) {
        loader.addFont(
          Future.value(ByteData.sublistView(file.readAsBytesSync())),
        );
      }
      await loader.load();
    }
  });

  test(
    'Italian covers every English key and preserves placeholder metadata',
    () {
      final en =
          jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
      final it =
          jsonDecode(File('lib/l10n/app_it.arb').readAsStringSync()) as Map;
      final keys = en.keys.where((k) => !(k as String).startsWith('@')).toSet();
      expect(keys.length, greaterThan(2700));
      expect(
        it.keys.where((k) => !(k as String).startsWith('@')).toSet(),
        keys,
      );
      expect(it['@@locale'], 'it');
      for (final key in keys) {
        expect(it[key], isNotEmpty, reason: '$key has a usable translation');
        expect(
          it['@$key'],
          en['@$key'],
          reason: '$key keeps its declared contract',
        );
      }
      expect(AppLocalizations.supportedLocales, contains(const Locale('it')));
      expect(_it.profileSourcesCount(1), contains('1'));
      expect(_it.profileSourcesCount(3), contains('3'));
      expect(_it.metricNeedNights(1), contains('1 notte'));
      expect(_it.metricNeedNights(3), contains('3 notti'));
      expect(
        _it.homeBriefingUnreadLabel('Titolo', 'Testo'),
        contains('Titolo'),
      );
    },
  );

  test(
    'native Coach confirmations translate every action without changing payloads',
    () {
      final cases = <String, (Map<String, dynamic>, List<String>)>{
        'log_journal': (
          {
            'date': '2026-10-07',
            'tags': ['late meal', 'my own tag'],
            'note': 'My words',
          },
          ['7 ottobre 2026', 'pasto tardivo', 'my own tag', 'My words'],
        ),
        'log_period': (
          {'date': '2026-10-07'},
          ['7 ottobre 2026', 'mestruazioni'],
        ),
        'start_workout': ({'type': 'running'}, ['Corsa']),
        'end_workout': ({}, ['Termina', 'allenamento']),
        'log_food': (
          {
            'label': 'My meal',
            'meal': 'breakfast',
            'date': '2026-10-07',
            'kcal': 425.75,
          },
          ['My meal', 'colazione', '7 ottobre 2026', '425,75 kcal'],
        ),
        'log_journal_fields': (
          {
            'date': '2026-10-07',
            'fields': {
              'water_ml': 500,
              'weight_kg': 72.456,
              'my_field': 'my value',
            },
          },
          ['Acqua (ml) 500', 'Peso (kg) 72,456', 'my_field my value'],
        ),
        'add_completed_workout': (
          {
            'type': 'running',
            'duration_min': 35.25,
            'start_time': '18:35',
            'date': '2026-10-07',
          },
          ['Corsa', '35,25', '18:35', '7 ottobre 2026'],
        ),
        'add_medication': (
          {
            'name': 'My medication',
            'time': '08:32',
            'weekdays': [1, 3, 7],
          },
          [
            'My medication',
            '08:32',
            'lun',
            'mer',
            'dom',
            'non verifica le interazioni',
          ],
        ),
        'mark_medication': (
          {'name': 'My medication', 'date': '2026-10-07', 'state': 'taken'},
          ['My medication', '7 ottobre 2026', 'assunta'],
        ),
        'set_step_goal': ({'goal': 9000}, ['9000']),
        'remember_preference': (
          {'text': 'My unchanged preference'},
          ['Original summary'],
        ),
      };
      for (final entry in cases.entries) {
        final args = entry.value.$1;
        final before = jsonEncode(args);
        final request = ActionRequest(
          tool: entry.key,
          title: 'Original title',
          summary: 'Original summary',
          args: args,
        );
        final copy = localizeCoachAction(request, _it);
        expect(copy.title, isNot('Original title'), reason: entry.key);
        for (final content in entry.value.$2) {
          expect(copy.summary, contains(content), reason: entry.key);
        }
        expect(jsonEncode(request.args), before);
        expect(request.title, 'Original title');
        expect(request.summary, 'Original summary');
        final english = localizeCoachAction(
          request,
          lookupAppLocalizations(const Locale('en')),
        );
        expect(english, (title: request.title, summary: request.summary));
      }
      final request = ActionRequest(
        tool: 'log_period',
        title: 'Log period',
        summary: 'Log a period start on 2026-10-07.',
        args: {},
      );
      expect(
        localizeCoachAction(request, _it).summary,
        contains('7 ottobre 2026'),
      );
      final unknown = ActionRequest(
        tool: 'future_action',
        title: 'User title',
        summary: 'User words',
        args: {'value': 72.5},
      );
      expect(localizeCoachAction(unknown, _it), (
        title: 'User title',
        summary: 'User words',
      ));
      final negativeField = ActionRequest(
        tool: 'log_journal_fields',
        title: 'Record fields',
        summary: 'Original',
        args: {
          'date': '2026-10-07',
          'fields': {'custom_temperature_delta': -0.125},
        },
      );
      expect(
        localizeCoachAction(negativeField, _it).summary,
        contains('custom_temperature_delta -0,125'),
      );
      final missingAmount = ActionRequest(
        tool: 'log_food',
        title: 'Log food',
        summary: 'Original',
        args: {'label': 'My words', 'meal': 'my meal'},
      );
      final missingCopy = localizeCoachAction(missingAmount, _it).summary;
      expect(missingCopy, contains('My words'));
      expect(missingCopy, contains('my meal'));
      expect(missingCopy, contains('oggi'));
      expect(missingCopy, isNot(contains('kcal')));
    },
  );

  test('Italian names, notes, units and dates preserve canonical data', () {
    expect(activityByName('Running')?.label(_it), 'Corsa');
    expect(exerciseByKey('bench_press')?.labelFor('it'), 'Panca piana');
    for (final exercise in exerciseLibrary) {
      expect(exercise.labelFor('it'), isNotEmpty);
    }
    final water = kJournalFields.firstWhere((f) => f.key == 'water_ml');
    expect(water.localizedLabel(_it), 'Acqua');
    expect(journalTagLabel('late meal', _it), 'pasto tardivo');
    expect(journalTagLabel('my own tag', _it), 'my own tag');
    expect(specOf('resting_hr', _it).title, 'Frequenza cardiaca a riposo');
    expect(specOf('steps', _it).method, isNot(contains('Counted, never')));
    expect(whyFromNote('need_input:name=weight_kg', l: _it), contains('peso'));
    expect(whyFromNote('need_input:name=unrecognized', l: _it), isNull);
    expect(whyFromNote('unknown_cause', l: _it), isNull);
    expect(
      localizedMetricReason(
        'Needs 2 more nights before recovery can score.',
        _it,
      ),
      contains('2 notti'),
    );
    expect(prettyDay('2026-10-07', _it), 'mercoledì, 7 ottobre');
    expect(dayNavLabel('2026-10-07', _it), contains('ottobre'));
    expect(displayNumber(72.4, _it, decimals: 1), '72,4');
    expect(
      UnitsController.seed(UnitSystem.imperial).localizedWeightLabel(_it),
      'Peso (lb)',
    );
  });

  test(
    'notifications localize copy without altering their firing identity',
    () async {
      final event = NotificationEvent(
        dedupeKey: '2026-10-07:alarm',
        category: NotifCategory.device,
        priority: NotifPriority.critical,
        title: 'Alarm',
        body: 'Your strap alarm just fired.',
        date: '2026-10-07',
        route: '/alarm',
        osId: 123,
      );
      final translated = localizeNotificationEvent(event, _it);
      expect(translated.title, 'Sveglia');
      expect(translated.body, contains('appena suonata'));
      expect(translated.dedupeKey, event.dedupeKey);
      expect(translated.category, event.category);
      expect(translated.priority, event.priority);
      expect(translated.route, event.route);
      expect(translated.date, event.date);
      expect(translated.osId, event.osId);
      expect(notificationBody('A dose is due.', _it), 'È ora di una dose.');
      expect(
        notificationBody('A user or model wrote this.', _it),
        'A user or model wrote this.',
      );
      final controller = LocaleController.seed(null);
      await controller.setCode('it');
      expect(
        (await LocaleController.presentationLocalizations()).localeName,
        'it',
      );
      expect((await LocaleController.bootstrap()).code, 'it');
      await controller.setCode(null);
      expect(
        (await SharedPreferences.getInstance()).containsKey('locale_override'),
        isFalse,
      );
      SharedPreferences.setMockInitialValues({
        'locale_override': 'unsupported',
      });
      expect((await LocaleController.bootstrap()).code, isNull);
    },
  );

  testWidgets(
    'language picker switches to Italiano and preserves system option',
    (t) async {
      t.view.physicalSize = const Size(390 * 3, 1000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final controller = LocaleController.seed('en');
      await t.pumpWidget(
        _host(
          const ProfileHomeView(stats: ProfileStats(sources: 0)),
          locale: controller,
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Language'));
      await t.pumpAndSettle();
      await t.tap(find.text('Italiano'));
      await t.pumpAndSettle();
      expect(controller.code, 'it');
      expect(find.text('Lingua'), findsOneWidget);
      expect(find.text('Profilo'), findsOneWidget);
      expect((await LocaleController.bootstrap()).code, 'it');
      await t.tap(find.text('Lingua'));
      await t.pumpAndSettle();
      await t.tap(find.text(_it.languageSystemDefault));
      await t.pumpAndSettle();
      expect(controller.locale, isNull);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('Home and baseline absence speak Italian at large text sizes', (
    t,
  ) async {
    t.view.physicalSize = const Size(390 * 3, 1500 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final semantics = t.ensureSemantics();
    await t.pumpWidget(
      _host(
        Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                const RingTrio(
                  d: HomeData(
                    readiness: Metric(value: 73),
                    sleepMin: Metric(value: 420),
                    strain: Metric(value: 12.4),
                  ),
                ),
                StatusCard.forMetric(
                  _it.homeNoRestingHr,
                  const Metric(note: 'need_baseline:have=2,need=5'),
                  l: _it,
                )!,
              ],
            ),
          ),
        ),
        scale: 2,
      ),
    );
    await t.pumpAndSettle();
    for (final text in [
      _it.homeRingRecovery,
      _it.homeRingSleep,
      _it.homeRingStrain,
      _it.homeNoRestingHr,
      _it.metricNeedNights(3),
    ]) {
      expect(
        find.textContaining(
          RegExp(
            '^${RegExp.escape(text)}'
            r'$',
            caseSensitive: false,
          ),
        ),
        findsWidgets,
      );
    }
    expect(find.bySemanticsLabel(RegExp('Recupero')), findsWidgets);
    expect(find.text('Need 3 more nights'), findsNothing);
    expect(t.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'weight row uses Italian date and decimal while retaining source',
    (t) async {
      final row = WeightReading(
        id: 'r1',
        time: DateTime(2026, 10, 7),
        kg: 72.4,
        source: 'My scale',
        sourceId: 'scale',
      );
      await t.pumpWidget(
        _host(
          Scaffold(
            body: WeightExploreRow(load: () async => {'2026-10-07': row}),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('72,4'), findsOneWidget);
      expect(find.textContaining('ott'), findsOneWidget);
      expect(find.textContaining('My scale'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
