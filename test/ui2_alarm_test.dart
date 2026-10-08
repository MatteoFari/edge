// The band alarm screen's one piece of real logic left in the screen itself:
// the mapping that decides what it is allowed to claim about confirmation.
// (The single next-occurrence picker — and its `nextAt` arithmetic — is gone;
// the weekly schedule in state/alarm_schedule.dart is now the only thing that
// arms the band, and its occurrence math is tested there, with no widget tree
// needed.)
//
// The screen is otherwise a rendering of AppState, and its layout is covered
// by the profile goldens.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _weekdaysAlarm = [
  for (var day = 0; day < 5; day++)
    AlarmScheduleEntry(weekday: day, hour: 7, minute: 30),
];

Future<void> _pumpSchedule(
  WidgetTester t, {
  List<AlarmScheduleEntry>? schedule,
  Future<void> Function(List<AlarmScheduleEntry>)? onSave,
  double scale = 1,
  Locale locale = const Locale('en'),
  InterfaceStyle style = InterfaceStyle.expressive,
  Brightness brightness = Brightness.light,
  double height = 2400,
  ThemeController? controller,
}) async {
  t.view.physicalSize = Size(390 * 3, height * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final theme =
      controller ??
      ThemeController.seed(
        brightness == Brightness.light
            ? AppThemeChoice.light
            : AppThemeChoice.dark,
        brightness,
        interfaceStyle: style,
        palette: ExpressivePalette.electricViolet,
      );
  if (controller == null) addTearDown(theme.dispose);
  await t.pumpWidget(
    ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: AnimatedBuilder(
        animation: theme,
        builder: (_, _) => MaterialApp(
          theme: buildTheme(
            theme.effective,
            style: theme.interfaceStyle,
            palette: theme.palette,
          ),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: AlarmScreenView(
            connected: true,
            schedule: fillDefaultAlarmSchedule(schedule ?? _weekdaysAlarm),
            onSaveScheduleEntries: onSave,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _openWeekdays(WidgetTester t) async {
  await t.tap(find.text('Weekdays'));
  await t.pumpAndSettle();
  expect(find.text('Wake schedule'), findsOneWidget);
}

Future<void> _changeTime(WidgetTester t) async {
  await t.tap(find.text('07:30'));
  await t.pumpAndSettle();
  expect(find.byType(TimePickerDialog), findsOneWidget);
  await t.enterText(find.byType(TextField).at(0), '08');
  await t.enterText(find.byType(TextField).at(1), '45');
  await t.tap(find.text('OK'));
  await t.pumpAndSettle();
}

void main() {
  group('wake schedule draft', () {
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    testWidgets('time, repeat, enable and smart wake edits wait for Save', (
      t,
    ) async {
      final updates = <List<AlarmScheduleEntry>>[];
      await _pumpSchedule(t, onSave: (entries) async => updates.add(entries));
      await _openWeekdays(t);
      await _changeTime(t);
      await t.tap(find.text('Weekends'));
      await t.tap(find.text('Alarm on for selected days'));
      await t.tap(find.text('Off'));
      await t.pumpAndSettle();
      await t.tap(find.text('30 min early'));
      await t.pumpAndSettle();
      expect(updates, isEmpty);
      expect(find.text('08:45'), findsOneWidget);
      expect(find.textContaining('While the app is connected'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(updates, isEmpty);
      await _openWeekdays(t);
      expect(find.text('07:30'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('Save commits the group once and preserves unrelated days', (
      t,
    ) async {
      final updates = <List<AlarmScheduleEntry>>[];
      await _pumpSchedule(
        t,
        schedule: [
          ..._weekdaysAlarm,
          const AlarmScheduleEntry(weekday: 6, hour: 9, minute: 10),
        ],
        onSave: (entries) async => updates.add(entries),
      );
      await _openWeekdays(t);
      await _changeTime(t);
      await t.tap(find.text('Wed'));
      await t.tap(find.text('Sat'));
      expect(updates, isEmpty);
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(updates, hasLength(1));
      expect(updates.single.map((entry) => entry.weekday), [0, 1, 2, 3, 4, 5]);
      expect(
        updates.single[2],
        const AlarmScheduleEntry(
          weekday: 2,
          hour: defaultAlarmHour,
          minute: defaultAlarmMinute,
          enabled: false,
          configured: false,
        ),
      );
      expect(
        updates.single
            .where((entry) => entry.enabled)
            .every((entry) => entry.hour == 8 && entry.minute == 45),
        isTrue,
      );
      expect(find.text('Wake schedule'), findsNothing);
      expect(find.text('Wake schedule saved'), findsOneWidget);
    });

    testWidgets('days assigned to another alarm cannot be overwritten', (
      t,
    ) async {
      List<AlarmScheduleEntry>? saved;
      await _pumpSchedule(
        t,
        schedule: [
          ..._weekdaysAlarm,
          const AlarmScheduleEntry(weekday: 6, hour: 9, minute: 10),
        ],
        onSave: (entries) async => saved = entries,
      );
      await _openWeekdays(t);
      await t.tap(find.text('Every day'));
      await t.tap(find.text('Weekends'));
      await t.tap(find.text('Sun'));
      await t.pumpAndSettle();
      expect(
        find.text('Days used by another alarm are unavailable.'),
        findsOneWidget,
      );
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(saved, _weekdaysAlarm);
    });

    testWidgets('disabled default-time alarms stay editable after reload', (
      t,
    ) async {
      var stored = [const AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0)];
      await _pumpSchedule(
        t,
        schedule: stored,
        onSave: (entries) async => stored = entries,
      );
      await t.tap(find.text('Mon'));
      await t.pumpAndSettle();
      await t.tap(find.text('Alarm on for selected days'));
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(stored.single.enabled, isFalse);
      expect(stored.single.configured, isTrue);

      stored = [
        for (final entry in stored)
          AlarmScheduleEntry.fromRow({
            'weekday': entry.weekday,
            'hour': entry.hour,
            'minute': entry.minute,
            'enabled': entry.enabled ? 1 : 0,
            'configured': entry.configured ? 1 : 0,
            'smart_window_minutes': entry.smartWindowMinutes,
          }),
      ];
      await _pumpSchedule(
        t,
        schedule: stored,
        onSave: (entries) async => stored = entries,
      );
      expect(find.text('Mon'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      await t.tap(find.text('Mon'));
      await t.pumpAndSettle();
      await t.tap(find.text('Alarm on for selected days'));
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(stored.single.enabled, isTrue);
      expect(stored.single.configured, isTrue);
    });

    testWidgets('another group cannot claim a disabled default-time alarm', (
      t,
    ) async {
      List<AlarmScheduleEntry>? saved;
      await _pumpSchedule(
        t,
        schedule: const [
          AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0, enabled: false),
          AlarmScheduleEntry(weekday: 1, hour: 8, minute: 15),
        ],
        onSave: (entries) async => saved = entries,
      );
      await t.tap(find.text('Tue'));
      await t.pumpAndSettle();
      final monday = t.widget<Semantics>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'Monday',
        ),
      );
      expect(monday.properties.enabled, isFalse);
      await t.tap(find.text('Mon'));
      await t.tap(find.text('Every day'));
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(saved, const [
        AlarmScheduleEntry(weekday: 1, hour: 8, minute: 15),
      ]);
    });

    testWidgets('Delete affects only the saved group, including after drafts', (
      t,
    ) async {
      List<AlarmScheduleEntry>? deleted;
      await _pumpSchedule(
        t,
        schedule: [
          ..._weekdaysAlarm,
          const AlarmScheduleEntry(weekday: 6, hour: 9, minute: 10),
        ],
        onSave: (entries) async => deleted = entries,
      );
      await _openWeekdays(t);
      await t.tap(find.text('Sat'));
      await _changeTime(t);
      expect(deleted, isNull);
      await t.tap(find.text('Delete alarm'));
      await t.pumpAndSettle();
      expect(deleted?.map((day) => day.weekday), [0, 1, 2, 3, 4]);
      expect(
        deleted?.every(
          (day) =>
              !day.enabled &&
              !day.configured &&
              day.hour == defaultAlarmHour &&
              day.minute == defaultAlarmMinute &&
              day.smartWindowMinutes == 0,
        ),
        isTrue,
      );
    });

    testWidgets('save failure retains the draft and clears the busy state', (
      t,
    ) async {
      var calls = 0;
      final pending = Completer<void>();
      await _pumpSchedule(
        t,
        onSave: (entries) async {
          calls++;
          if (calls == 1) throw Exception('Could not save the schedule.');
          await pending.future;
        },
      );
      await _openWeekdays(t);
      await _changeTime(t);
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(find.text('Could not save the schedule.'), findsOneWidget);
      expect(find.text('08:45'), findsOneWidget);
      await t.tap(find.text('Save changes'));
      await t.pump();
      expect(find.text('Saving…'), findsOneWidget);
      await t.tap(find.text('Saving…'));
      await t.tap(find.text('Cancel'));
      await t.pump();
      expect(calls, 2);
      expect(find.text('Wake schedule'), findsOneWidget);
      pending.complete();
      await t.pumpAndSettle();
      expect(find.text('Wake schedule'), findsNothing);
    });

    testWidgets('a stale schedule keeps the draft and asks to reopen', (
      t,
    ) async {
      var calls = 0;
      await _pumpSchedule(
        t,
        onSave: (entries) async {
          calls++;
          throw StateError('The alarm schedule changed while editing.');
        },
      );
      await _openWeekdays(t);
      await _changeTime(t);
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(find.textContaining('Reopen the editor'), findsOneWidget);
      expect(find.text('08:45'), findsOneWidget);
      expect(calls, 1);
    });

    testWidgets('an empty day selection cannot save', (t) async {
      var saved = false;
      await _pumpSchedule(t, onSave: (_) async => saved = true);
      await _openWeekdays(t);
      for (final day in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']) {
        await t.tap(find.text(day));
      }
      await t.pump();
      expect(find.text('Select at least one day.'), findsOneWidget);
      await t.tap(find.text('Save changes'));
      expect(saved, isFalse);
    });

    testWidgets(
      'new alarm cancellation and Back leave the schedule untouched',
      (t) async {
        var saved = false;
        await _pumpSchedule(t, schedule: [], onSave: (_) async => saved = true);
        await t.tap(find.text('Set an alarm'));
        await t.pumpAndSettle();
        expect(find.text('Delete alarm'), findsNothing);
        await t.tap(find.text('Weekends'));
        await t.tap(
          find.byWidgetPredicate(
            (widget) => widget is Pressable && widget.semanticLabel == 'Back',
          ),
        );
        await t.pumpAndSettle();
        expect(saved, isFalse);
        expect(find.text('No alarm is set'), findsOneWidget);
      },
    );

    for (final format in [ClockFormat.h12, ClockFormat.h24]) {
      testWidgets('wake time and picker respect ${format.name}', (t) async {
        ClockFormatController.seed(format);
        await _pumpSchedule(t, onSave: (_) async {});
        await _openWeekdays(t);
        final text = format == ClockFormat.h12 ? '7:30 AM' : '07:30';
        expect(find.text(text), findsOneWidget);
        await t.tap(find.text(text));
        await t.pumpAndSettle();
        final picker = t.widget<MediaQuery>(
          find
              .ancestor(
                of: find.byType(TimePickerDialog),
                matching: find.byType(MediaQuery),
              )
              .first,
        );
        expect(picker.data.alwaysUse24HourFormat, format == ClockFormat.h24);
      });
    }

    for (final style in InterfaceStyle.values) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'editor fits ${style.name}/${brightness.name} at large text',
          (t) async {
            await _pumpSchedule(
              t,
              onSave: (_) async {},
              scale: 3.1,
              style: style,
              brightness: brightness,
              height: 844,
            );
            await _openWeekdays(t);
            await t.scrollUntilVisible(
              find.text('Save changes'),
              300,
              scrollable: find.byType(Scrollable).last,
            );
            expect(t.takeException(), isNull);
            await t.scrollUntilVisible(
              find.text('Delete alarm'),
              300,
              scrollable: find.byType(Scrollable).last,
            );
            expect(t.takeException(), isNull);
          },
        );
      }
    }
  });

  group('what the screen may claim', () {
    test('an unconfirmed alarm never says it will fire', () {
      // The band confirms separately (event 56) and might never do so; after a
      // relaunch there is no live confirmation at all, only the epoch on disk.
      for (final s in [AlarmArmState.unknown, AlarmArmState.pending]) {
        final view = AlarmScreenView(state: s, armedAt: DateTime(2026, 8, 22));
        expect(AlarmScreenView.stateLabel(s), isNot(contains('Confirmed')));
        expect(view.state, s);
      }
      expect(
        AlarmScreenView.stateLabel(AlarmArmState.confirmed),
        contains('Confirmed'),
      );
    });
  });

  group('wake schedule appearance', () {
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    testWidgets('the draft survives live interface and palette changes', (
      t,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final theme = ThemeController.seed(
        AppThemeChoice.light,
        Brightness.light,
      );
      addTearDown(theme.dispose);
      List<AlarmScheduleEntry>? saved;
      await _pumpSchedule(
        t,
        controller: theme,
        onSave: (entries) async => saved = entries,
      );
      await _openWeekdays(t);
      await _changeTime(t);
      await t.tap(find.text('Sat'));
      await theme.setInterfaceStyle(InterfaceStyle.expressive);
      await theme.setPalette(ExpressivePalette.warmAmber);
      await theme.setChoice(AppThemeChoice.dark);
      await t.pumpAndSettle();
      expect(find.text('08:45'), findsOneWidget);
      expect(saved, isNull);
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(saved?.map((entry) => entry.weekday), [0, 1, 2, 3, 4, 5]);
      expect(
        saved?.every((entry) => entry.hour == 8 && entry.minute == 45),
        isTrue,
      );
    });

    testWidgets('weekday chips expose selection and unavailable days', (
      t,
    ) async {
      await _pumpSchedule(
        t,
        schedule: [
          ..._weekdaysAlarm,
          const AlarmScheduleEntry(weekday: 6, hour: 9, minute: 10),
        ],
        onSave: (_) async {},
      );
      await _openWeekdays(t);
      Semantics day(String label) => t.widget<Semantics>(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == label,
        ),
      );
      expect(day('Monday').properties.selected, isTrue);
      expect(day('Saturday').properties.selected, isFalse);
      expect(day('Sunday').properties.enabled, isFalse);
      for (final control in find.byType(Pressable).evaluate()) {
        final size = t.getSize(find.byElementPredicate((e) => e == control));
        expect(size.width, greaterThanOrEqualTo(S.tap));
        expect(size.height, greaterThanOrEqualTo(S.tap));
      }
    });

    for (final locale in ['de', 'es', 'fr', 'hi', 'zh']) {
      testWidgets('localized editor fits $locale at large text', (t) async {
        final l = await AppLocalizations.delegate.load(Locale(locale));
        await _pumpSchedule(
          t,
          onSave: (_) async {},
          locale: Locale(locale),
          scale: 3.1,
          height: 844,
        );
        await t.tap(find.text(l.alarmWeekdays));
        await t.pumpAndSettle();
        await t.scrollUntilVisible(
          find.text(l.alarmSaveChanges),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        expect(t.takeException(), isNull);
      });
    }
  });

  group('a fired alarm', () {
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    Future<void> pump(WidgetTester t, DateTime now) => t.pumpWidget(
      MaterialApp(
        home: AlarmScreenView(firedAt: DateTime(2026, 8, 22, 6, 30), now: now),
      ),
    );

    testWidgets('says it fired for the rest of that day', (t) async {
      // the next alarm is armed the moment this one fires, so without this
      // the row just swaps times and a real fire reads like a fault
      await pump(t, DateTime(2026, 8, 22, 9));
      expect(find.text('Fired at 06:30'), findsOneWidget);
    });

    testWidgets('and not the day after', (t) async {
      await pump(t, DateTime(2026, 8, 23, 9));
      expect(find.textContaining('Fired at'), findsNothing);
    });
  });

  group('the home door', () {
    // The time follows the user's clock format; pin the 24-hour one.
    setUp(() => ClockFormatController.seed(ClockFormat.h24));
    tearDown(ClockFormatController.debugReset);

    // A fixed clock: whether the alarm is still ahead is relative to now.
    Future<void> pump(
      WidgetTester t,
      DateTime? at,
      AlarmArmState s, {
      DateTime? now,
    }) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) =>
                alarmDoor(c, at, s, now: now ?? DateTime(2026, 8, 21, 22)),
          ),
        ),
      ),
    );

    testWidgets('no alarm offers to set one', (t) async {
      await pump(t, null, AlarmArmState.none);
      expect(find.text('Set an alarm'), findsOneWidget);
    });

    testWidgets('an armed alarm shows its day, time and real state', (t) async {
      // 2026-08-22 is a Saturday.
      await pump(t, DateTime(2026, 8, 22, 7, 30), AlarmArmState.unknown);
      expect(find.text('Sat 07:30 · Not confirmed'), findsOneWidget);
    });

    testWidgets('a spent alarm says so instead of passing as the next one', (
      t,
    ) async {
      // Fired (or missed) while the link was down: the epoch is still saved.
      await pump(
        t,
        DateTime(2026, 8, 22, 7, 30),
        AlarmArmState.confirmed,
        now: DateTime(2026, 8, 22, 9),
      );
      expect(find.textContaining('Confirmed'), findsNothing);
      expect(find.textContaining('Sat 07:30 · In the past'), findsOneWidget);
    });
  });
}
