import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/med_store.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/live.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart';
import 'package:openstrap_edge/ui2/screens/wellness_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

// The home widget is kept stable while the MaterialApp theme changes. These
// checks exercise the real forms and session controls, rather than rebuilding
// new routes that would hide a lost draft.
Future<void> _pump(
  WidgetTester t,
  ValueNotifier<InterfaceStyle> style,
  Widget child, {
  AppState? app,
}) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ValueListenableBuilder<InterfaceStyle>(
      valueListenable: style,
      child: app == null
          ? child
          : ChangeNotifierProvider<AppState>.value(value: app, child: child),
      builder: (_, value, child) => MaterialApp(
        theme: buildTheme(Brightness.light, style: value),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(
            c,
          ).copyWith(disableAnimations: true, alwaysUse24HourFormat: true),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
  await t.pumpAndSettle();
}

ValueNotifier<InterfaceStyle> _style() {
  final style = ValueNotifier(InterfaceStyle.original);
  addTearDown(style.dispose);
  return style;
}

class _JournalRepo extends LocalRepository {
  Map<String, JournalMetricValue> metrics = {};
  String note = '';

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];

  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(
    String date,
  ) async => {...metrics};

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      [
        {'date': '2026-09-01', 'tags': <String>[], 'note': note},
      ];

  @override
  Future<void> postJournalMetrics(
    String date,
    Map<String, JournalMetricValue> values,
  ) async {
    metrics = {...values};
  }

  @override
  Future<void> postJournal(String date, List<String> tags, String value) async {
    note = value;
  }
}

class _ReviewRepo extends LocalRepository {
  final items = [
    for (final kind in ActivityKind.values)
      ActivitySuggestion(
        id: kind.name,
        kind: kind,
        startTs: 1787157000,
        endTs: 1787158800,
        revision: 0,
        details: const {'sport': 'running'},
      ),
  ];
  final decisions = <String>[];

  @override
  Future<List<ActivitySuggestion>> pendingActivities() async => [...items];

  @override
  Future<void> confirmActivity(
    ActivitySuggestion s, {
    int? startTs,
    int? endTs,
    String? workoutType,
  }) async {
    decisions.add('confirm:${s.id}');
    items.removeWhere((item) => item.id == s.id);
  }

  @override
  Future<void> discardActivity(ActivitySuggestion s) async {
    decisions.add('discard:${s.id}');
    items.removeWhere((item) => item.id == s.id);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'notify_auto_detect': false});
    ClockFormatController.seed(ClockFormat.h24);
    LiveDraft.clear();
  });
  tearDown(() {
    ClockFormatController.debugReset();
    LiveDraft.clear();
  });

  testWidgets('workout window and chosen activity survive a style switch', (
    t,
  ) async {
    final style = _style();
    await _pump(
      t,
      style,
      LogWorkout(
        now: DateTime(2026, 8, 20, 8),
        start: DateTime(2026, 8, 19, 23, 40),
        end: DateTime(2026, 8, 20, 0, 20),
        activity: activityByName('running'),
        spans: const [],
      ),
    );
    final form = t.state(find.byType(LogWorkout));
    await t.tap(find.text('Running'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Swim');
    await t.pumpAndSettle();

    style.value = InterfaceStyle.expressive;
    await t.pumpAndSettle();
    expect(
      t.widget<TextField>(find.byType(TextField)).controller?.text ??
          t.widget<EditableText>(find.byType(EditableText)).controller.text,
      'Swim',
    );
    await t.tap(find.text('Swimming'));
    await t.pumpAndSettle();

    expect(identical(t.state(find.byType(LogWorkout)), form), isTrue);
    expect(find.text('Swimming'), findsOneWidget);
    expect(find.text('23:40'), findsOneWidget);
    expect(find.text('00:20'), findsOneWidget);
    expect(find.text('40 min'), findsOneWidget);
    expect(find.text('the next morning'), findsOneWidget);
    expect(find.text('That window will not save'), findsNothing);

    style.value = InterfaceStyle.original;
    await t.pumpAndSettle();
    expect(find.text('Swimming'), findsOneWidget);
    expect(find.text('40 min'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('journal keeps typed note and mood and saves the same draft', (
    t,
  ) async {
    final style = _style();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _JournalRepo();
    app.repo = repo;
    await _pump(t, style, const JournalCompose(date: '2026-09-01'), app: app);
    await t.enterText(find.byType(TextField), 'A quiet day with a long walk.');
    await t.tap(find.bySemanticsLabel('Mood 4 of 5'));
    await t.pumpAndSettle();

    style.value = InterfaceStyle.expressive;
    await t.pumpAndSettle();
    expect(find.text('A quiet day with a long walk.'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Mood 4 of 5, selected. Activate to clear.'),
      findsOneWidget,
    );
    await t.tap(find.text('Save').first);
    await t.pumpAndSettle();
    expect(repo.note, 'A quiet day with a long walk.');
    expect(repo.metrics['mood']?.value, 4);
    expect(t.takeException(), isNull);
  });

  testWidgets('open medication schedule keeps edited days and its time', (
    t,
  ) async {
    final style = _style();
    MedSchedule? saved;
    await _pump(
      t,
      style,
      Scaffold(
        body: Builder(
          builder: (c) => BigButton(
            'Edit schedule',
            onTap: () async {
              saved = await pickMedSchedule(
                c,
                minuteOfDay: 9 * 60 + 20,
                days: const [1, 3],
              );
            },
          ),
        ),
      ),
    );
    await t.tap(find.text('Edit schedule'));
    await t.pumpAndSettle();
    await t.tap(find.text('Wed'));
    await t.pumpAndSettle();

    style.value = InterfaceStyle.expressive;
    await t.pumpAndSettle();
    expect(find.text('09:20'), findsOneWidget);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(saved?.minuteOfDay, 9 * 60 + 20);
    expect(saved?.days, [1]);
    expect(t.takeException(), isNull);
  });

  testWidgets('review decisions stay attached to their proposals', (t) async {
    final style = _style();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _ReviewRepo();
    app.repo = repo;
    await _pump(t, style, const DetectedActivitiesScreen(), app: app);
    final first = repo.items.first.id;
    final second = repo.items.last.id;
    style.value = InterfaceStyle.expressive;
    await t.pumpAndSettle();
    await t.tap(find.text('Confirm').first);
    await t.pumpAndSettle();
    expect(repo.decisions, ['confirm:$first']);
    expect(repo.items.single.id, second);
    style.value = InterfaceStyle.original;
    await t.pumpAndSettle();
    await t.tap(find.text('Discard'));
    await t.pumpAndSettle();
    expect(repo.decisions, ['confirm:$first', 'discard:$second']);
    expect(find.text('Nothing to review'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('paused strength session keeps sets and resume/finish work', (
    t,
  ) async {
    final style = _style();
    final a = activityByName('weight_training')!;
    final draft = LiveDraft.begin(a, weightKg: 72.4);
    draft.put('exercise_plan', ['bench_press']);
    ActivityResult? finished;
    await _pump(
      t,
      style,
      liveFor(
        a,
        weightKg: 72.4,
        host: ActivityHost(
          onFinish: (result) async {
            finished = result;
            return result;
          },
        ),
      ),
    );
    await t.tap(find.text('Log set'));
    await t.pump();
    await t.tap(find.bySemanticsLabel('Pause'));
    await t.pumpAndSettle();
    final shell = t.state<LiveShellState>(find.byType(LiveShell));
    final elapsed = shell.elapsed;

    style.value = InterfaceStyle.expressive;
    await t.pumpAndSettle();
    expect(identical(t.state(find.byType(LiveShell)), shell), isTrue);
    expect(identical(LiveDraft.current, draft), isTrue);
    expect(draft.pausedAt, isNotNull);
    expect(shell.elapsed, elapsed);
    await t.tap(find.bySemanticsLabel('Resume'));
    await t.pump();
    expect(draft.pausedAt, isNull);
    await t.tap(find.bySemanticsLabel('Finish session'));
    await t.pumpAndSettle();
    expect(finished?.strength.setCount, 1);
    expect(finished?.strength.sets.single.exerciseKey, 'bench_press');
    expect(LiveDraft.current, isNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('missing metric keeps the recorded reason in either style', (
    t,
  ) async {
    final style = _style();
    await _pump(
      t,
      style,
      const Scaffold(
        body: HealthScreen(
          data: HealthData(
            today: {
              'daily': {
                'resting_hr': {
                  'value': null,
                  'confidence': 0,
                  'note': 'need_input:name=nn_beats',
                },
              },
            },
          ),
        ),
      ),
    );
    const reason = 'Too few clean beat-to-beat intervals to work this out.';
    expect(find.text(reason), findsOneWidget);
    style.value = InterfaceStyle.expressive;
    await t.pumpAndSettle();
    expect(find.text(reason), findsOneWidget);
    expect(find.text('No resting heart rate'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
