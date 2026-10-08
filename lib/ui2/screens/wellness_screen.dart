// Wellness — softer than Health, same system.
//
// Health tells you what your body did. Wellness is where you tell it back, and
// where the app explains itself. Four sub-tabs: Today, Habits,
// Medication, Cycle. Cycle is a SUB-TAB and not a sixth shell tab — see
// `app_shell.dart`; anything that feels like a sixth domain belongs inside the
// domain that owns it.
//
// Three rules this screen exists to hold:
//   · Habits are a CONSISTENCY, never a streak. "5 of 7 days" cannot reset to
//     zero, so a missed day costs a day rather than costing everything.
//   · Adherence is a COUNT with its window stated, and a dose still ahead of
//     you today is in no denominator.
//   · There is no drug-interaction checking. The screen does not carry a card
//     saying so either — a disclaimer for a feature that was never offered is
//     still an advert for it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' show journalFieldLagDays;
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../data/day_label.dart';
import '../../data/journal_fields.dart';
import '../../data/med_store.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../stress/breath_phases.dart';
import '../ui2.dart';
import 'calm_breathing.dart';
import 'cycle_screen.dart';
import 'home_screen.dart' show weekdayShortName;
import 'journal_compose.dart';
import 'start_card.dart';
import 'metric_detail.dart' show detailScaffold;

class WellnessScreen extends StatefulWidget {
  const WellnessScreen({super.key});

  /// A deep link asking for one of the sub-tabs — [medsTab] from the dose
  /// reminder. -1 for the ordinary case: open where the screen opens.
  ///
  /// NOT A CONSTRUCTOR ARGUMENT, and it cannot be one. This screen is built by
  /// the shell's IndexedStack, which keeps it alive; a tap that lands on a
  /// Wellness already on screen rebuilds nothing, so there is no constructor
  /// call to carry the index. A request the screen listens for reaches it in
  /// BOTH cases — the live state's listener when Wellness is already up, and
  /// the fresh state's `initState` when the shell re-keys to switch domain.
  ///
  /// The shell CLEARS it a frame later rather than the screen consuming it on
  /// read: on the re-key path the outgoing state's listener fires first, and a
  /// consume-on-read would eat the request before the incoming one existed.
  static final ValueNotifier<int> tabRequest = ValueNotifier<int>(-1);

  /// Cycle is LAST on purpose: it is the one tab that can be switched off
  /// (Profile → Preferences → Cycle tracking, off by default), and dropping a
  /// trailing tab leaves every other tab's index where it was.
  ///
  /// On the widget rather than the state so [medsTab] can be checked against
  /// it — a deep link that lands on the wrong tab because the list was
  /// reordered is not a failure anything else would catch.
  ///
  /// Fallback labels only — index bookkeeping uses `.length`, and the actual
  /// display labels are localized in `build`.
  static const tabs = ['Today', 'Habits', 'Medication', 'Cycle'];
  static const _tabIds = ['today', 'habits', 'medication', 'cycle'];

  static const int medsTab = 2;

  @override
  State<WellnessScreen> createState() => _WellnessScreenState();
}

class _WellnessScreenState extends State<WellnessScreen> with RevisionReload {
  int _tab = 0;
  static const _tabs = WellnessScreen.tabs;

  /// Habit consistency is read over a fortnight: long enough that one bad week
  /// does not read as collapse, short enough to still be about now.
  static const _habitDays = 14;

  /// Read on every use, never captured once: the shell keeps this tab alive in
  /// its IndexedStack, so a field initialiser would still be yesterday after
  /// midnight and habit ticks would land on yesterday's date.
  String get _date => todayLabel();
  bool _loading = true;
  bool _loadError = false;

  /// One journal write at a time. `putJournalMetrics` deletes the day and
  /// re-inserts it, so two quick taps both read the same day and the second
  /// erased the first.
  bool _writingField = false;

  Map<String, JournalMetricValue> _todayFields = {};
  List<JournalFieldSpec> _habits = const [];
  List<JournalFieldSpec> _fields = const [];
  Map<String, Map<String, JournalMetricValue>> _habitHistory = const {};
  List<Map<String, dynamic>> _breathing = const [];
  List<MedDef> _meds = const [];
  List<MedSlot> _slots = const [];
  ({int taken, int of}) _adherence = (taken: 0, of: 0);

  @override
  void initState() {
    super.initState();
    final t = WellnessScreen.tabRequest.value;
    if (t >= 0 && t < _tabs.length) _tab = t;
    WellnessScreen.tabRequest.addListener(_onTabRequest);
    _load();
  }

  /// A dose reminder tapped while Wellness was already the open domain.
  void _onTabRequest() {
    final t = WellnessScreen.tabRequest.value;
    if (t < 0 || t >= _tabs.length || t == _tab || !mounted) return;
    setState(() => _tab = t);
  }

  @override
  void dispose() {
    WellnessScreen.tabRequest.removeListener(_onTabRequest);
    super.dispose();
  }

  /// Journal fields and medication entries move under this tab
  /// when a derive or an import runs — and it is one of the three the shell
  /// keeps alive forever, so it read them once and stopped.
  @override
  void reload() => _load();

  /// After a medication or journal write. The dose reminders, the strap buzz
  /// and the check-in are armed ahead of time and never look at the dose or
  /// the day when they fire — so a dose ticked at 07:56 still buzzed at 08:00
  /// until the next resume re-armed them.
  Future<void> _wrote() async {
    if (!mounted) return;
    unawaited(context.read<AppState>().refreshAiReminders());
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final token = beginRead(#wellness);
    final app = context.read<AppState>();
    final repo = app.repo;
    final now = DateTime.now();
    final date = dayLabelOf(now);
    setState(() {
      _loading = _loading || _loadError;
      _loadError = false;
    });
    try {
      final db = await LocalDb.instance;
      final meds = await MedDb.defs(db);
      final doses = await MedDb.dosesForDay(db, date);
      final adherence = await MedDb.adherenceWindow(db, days: 7);
      final breathing = await app.breathingHistory(limit: 5);
      final fields = repo == null
          ? <String, JournalMetricValue>{}
          : await repo.getJournalMetrics(date);
      final specs = repo == null
          ? <JournalFieldSpec>[]
          : await repo.getJournalFields();
      // Calendar arithmetic retains the intended fortnight across DST.
      final since = dayLabelOf(
        DateTime(now.year, now.month, now.day - (_habitDays - 1)),
      );
      final history = await LocalDb.journalMetricsByDay(sinceDaysEpoch: since);
      if (!stillNewest(#wellness, token)) return;
      // Do not commit a mixed-day snapshot if midnight passed during the read.
      if (date != todayLabel()) {
        unawaited(_load());
        return;
      }
      setState(() {
        _meds = meds;
        _slots = slotsForDay(meds, date, doses, now: DateTime.now());
        _adherence = adherence;
        _breathing = breathing;
        _todayFields = {...fields};
        _habits = [
          for (final spec in specs)
            if (spec.custom && spec.max == 1) spec,
        ];
        _fields = specs;
        _habitHistory = history;
        _loading = false;
      });
    } catch (_) {
      if (!stillNewest(#wellness, token)) return;
      setState(() {
        _loading = false;
        _loadError = true;
      });
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final last = _breathing.isEmpty ? null : _breathing.first;
    final lastSeconds = _reading(last?['seconds']);
    // `select`, not `watch`: this screen lives in the shell's IndexedStack and
    // stays mounted, so a plain watch would rebuild it on every unrelated
    // AppState notification for the life of the app.
    final showCycle = c.select<AppState, bool>((a) => a.cycleTrackingEnabled);
    final labels = [
      l?.wellnessTabToday ?? 'Today',
      l?.wellnessTabHabits ?? 'Habits',
      l?.wellnessTabMedication ?? 'Medication',
      l?.wellnessTabCycle ?? 'Cycle',
    ];
    final tabs = showCycle ? labels : labels.take(labels.length - 1).toList();
    // Clamped rather than reset: switching Cycle off while standing on it
    // lands on Medication, not back at Today.
    final tab = _tab.clamp(0, tabs.length - 1);
    final inset = shellScrollPadding(
      c,
      const EdgeInsets.fromLTRB(0, S.x4, 0, S.x16),
    );
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(S.x4, inset.top, S.x4, 0),
          child: Column(
            children: [
              ScreenTitle(l?.wellnessTitle ?? 'Wellness'),
              SubTabs(
                tabs,
                tab,
                (i) => setState(() => _tab = i),
                color: C.domMind,
              ),
              const SizedBox(height: S.x5),
            ],
          ),
        ),
        Expanded(
          child: SubPages(
            index: tab,
            count: tabs.length,
            onChanged: (i) => setState(() => _tab = i),
            builder: (c, i) => ListView(
              key: PageStorageKey('wellness-${WellnessScreen._tabIds[i]}'),
              padding: EdgeInsets.fromLTRB(S.x4, 0, S.x4, inset.bottom),
              children: [
                for (final w in <Widget>[
                  if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_loadError)
                    StatusCard(
                      l?.wellnessLoadErrorTitle ?? 'Could not load Wellness',
                      l?.wellnessLoadErrorBody ??
                          'Your saved entries could not be read. Try again.',
                      fix: l?.healthTryAgain ?? 'Try again',
                      icon: LucideIcons.refreshCw,
                      onFix: _load,
                    )
                  else ...[
                    if (i == 0) ...[
                      StartCard(
                        label: l?.wellnessStartASitting ?? 'START A SITTING',
                        // Count the patterns the breathing picker actually offers.
                        count: kBreathPatterns.length,
                        noun: l?.wellnessExercisesNoun ?? 'exercises',
                        sub: lastSeconds == null || lastSeconds < 0
                            ? (l?.wellnessPickOneAndGo ?? 'Pick one and go')
                            : (l?.wellnessLastMinutes(lastSeconds ~/ 60) ??
                                  'Last: ${lastSeconds ~/ 60} min'),
                        icon: LucideIcons.wind,
                        actionLabel: l?.calmBreathingBegin ?? 'Begin',
                        accent: C.domMind,
                        onNavigate: (open) async {
                          await open<void>(const CalmBreathing());
                          if (mounted) await _load();
                        },
                      ),
                      const SizedBox(height: S.x4),
                    ],
                    [_today, _habitsTab, _medication, _cycle][i](c),
                  ],
                ])
                  w,
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── TODAY ─────────────────────────────────────────────────────────────────

  Widget _today(BuildContext c) {
    final l = AppLocalizations.of(c);
    final completed = _habits
        .where((h) => (_todayFields[h.key]?.value ?? 0) >= 1)
        .length;
    final due = _slots.where((slot) => slot.state == DoseState.missed).length;
    final upcoming = _slots
        .where((slot) => slot.state == DoseState.upcoming)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The "Paced breathing / Begin" ActionCard used to sit here. It is the
        // hero card above now — same destination, same last-sitting line, one
        // door instead of two.
        MoodPicker(
          value: _todayFields['mood']?.value.round(),
          onChanged: (v) => _setField('mood', v?.toDouble()),
        ),
        const SizedBox(height: S.x4),
        ActionCard(
          l?.wellnessWriteTheDayDown ?? 'Write the day down',
          // Named from the field specs the journal actually holds. The old
          // literal listed four fields and went stale the moment a custom one
          // was added.
          _journalSubtitle(l),
          l?.wellnessOpen ?? 'Open',
          LucideIcons.notebookPen,
          C.blue,
          onNavigate: (open) async {
            await open<void>(const JournalCompose());
            if (mounted) await _load();
          },
        ),
        const SizedBox(height: S.x4),
        ActionCard(
          l?.wellnessTabHabits ?? 'Habits',
          _habits.isEmpty
              ? (l?.wellnessAddAHabit ?? 'Add a habit')
              : (l?.wellnessHabitsToday(completed, _habits.length) ??
                    '$completed of ${_habits.length} completed today'),
          l?.wellnessOpen ?? 'Open',
          LucideIcons.circleCheck,
          C.domMind,
          onTap: () => setState(() => _tab = 1),
        ),
        const SizedBox(height: S.x3),
        ActionCard(
          l?.wellnessTabMedication ?? 'Medication',
          _meds.isEmpty
              ? (l?.wellnessNothingScheduledBody ??
                    'Add what you take and when.')
              : (l?.wellnessMedicationToday(due, upcoming) ??
                    '$due due now · $upcoming upcoming'),
          l?.wellnessOpen ?? 'Open',
          LucideIcons.pill,
          C.blue,
          onTap: () => setState(() => _tab = WellnessScreen.medsTab),
        ),
      ],
    );
  }

  /// What the journal will actually ask you, read off its own field specs.
  String _journalSubtitle(AppLocalizations? l) {
    // Not `.toLowerCase()`: these are user-entered/localized field labels
    // (acronyms like HRV, or nouns a language capitalizes) — lowercasing
    // them here would corrupt content the join has no business rewriting.
    final names = [for (final f in _fields) f.localizedLabel(AppLocalizations.of(context))];
    if (names.isEmpty) {
      return l?.wellnessJournalDefaultSubtitle ??
          'Anything you want to remember about today';
    }
    if (names.length <= 4) {
      final joined = names.join(', ');
      return l?.wellnessJournalSubtitleShort(joined) ?? '$joined and a note';
    }
    final joined = names.take(4).join(', ');
    final more = names.length - 4;
    return l?.wellnessJournalSubtitleLong(joined, more) ??
        '$joined and $more more, plus a note';
  }

  Future<void> _setField(String key, double? v) async {
    final repo = context.read<AppState>().repo;
    final date = _date;
    if (repo == null || _writingField) return;
    setState(() => _writingField = true);
    try {
      // RE-READ THE DAY, do not write from the snapshot this tab loaded with.
      //
      // `postJournalMetrics` -> `putJournalMetrics` DELETES the whole day and
      // re-inserts what it is handed, so writing a merge of `_todayFields` — a
      // copy taken when the tab last loaded — silently deleted every journal
      // field written since. Open Wellness, go and write your journal from the
      // compose screen, come back without the tab reloading, tick one habit,
      // and the journal entry was gone.
      final next = {...await repo.getJournalMetrics(date)};
      if (v == null) {
        next.remove(key);
      } else {
        next[key] = JournalMetricValue(v);
      }
      await repo.postJournalMetrics(date, next);
      await _wrote();
    } finally {
      if (mounted) setState(() => _writingField = false);
    }
  }

  // ── CYCLE ────────────────────────────────────────────────────────────────

  /// Owns its own load: the tab is off for most users and its query touches two
  /// tables plus 120 derived days, which nobody should pay for by opening Today.
  Widget _cycle(BuildContext c) => const CycleTab();

  // ── HABITS ───────────────────────────────────────────────────────────────

  Widget _habitsTab(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final h in _habits)
          Padding(
            padding: const EdgeInsets.only(bottom: S.x3),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          h.label,
                          style: F.body.copyWith(
                            color: p.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // A habit you typed had no way out short of "Delete
                      // everything": the delete path existed end to end and
                      // nothing reached it.
                      Pressable(
                        semanticLabel:
                            l?.wellnessRemoveHabitSemantic(h.label) ??
                            'Remove ${h.label}',
                        onTap: () => _confirmRemoveHabit(h),
                        child: Padding(
                          padding: const EdgeInsets.only(right: S.x3),
                          child: Icon(
                            LucideIcons.trash2,
                            size: 18,
                            color: p.ink3,
                          ),
                        ),
                      ),
                      _Check(
                        on: (_todayFields[h.key]?.value ?? 0) >= 1,
                        // Null while a write is in flight: the tick is a
                        // read-modify-write of the whole day, and a second tap
                        // during the first one used to erase it.
                        onTap: _writingField
                            ? null
                            : () => _setField(
                                h.key,
                                (_todayFields[h.key]?.value ?? 0) >= 1
                                    ? null
                                    : 1,
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: S.x3),
                  Consistency(
                    _habitDaysDone(h.key),
                    _habitDays,
                    l?.wellnessDaysYouDidIt ?? 'Days you did it',
                    C.domMind,
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: S.x4),
        BigButton(
          l?.wellnessAddAHabit ?? 'Add a habit',
          icon: LucideIcons.plus,
          color: C.domMind,
          soft: true,
          onTap: () => _addHabit(c),
        ),
        // MIND-01/04/12 — the whole dose-response and habit-difference half of
        // journal analysis, plus the weekday test, behind ONE door. It has
        // lived here computed-and-discarded for months; putting the rows on
        // this tab would bury the thing the tab is for, which is ticking.
        const SizedBox(height: S.x5),
        ActionCard(
          l?.wellnessWhatYouLogTitle ?? 'What you log, against your numbers',
          l?.wellnessWhatYouLogSubtitle ??
              'Dose, habit difference, and the day of the week',
          l?.wellnessOpen ?? 'Open',
          LucideIcons.scatterChart,
          C.domMind,
          destination: const JournalFindings(),
        ),
      ],
    );
  }

  int _habitDaysDone(String key) {
    var n = 0;
    for (final day in _habitHistory.values) {
      if ((day[key]?.value ?? 0) >= 1) n++;
    }
    return n;
  }

  /// Remove the habit, keep its history.
  ///
  /// `journal_field_def` deliberately keeps a deleted field's recorded values
  /// (see db.dart's note on the table) — they were real answers. A "delete"
  /// that quietly keeps data is as much of a surprise as one that quietly loses
  /// it, so the confirm says which this is.
  Future<void> _confirmRemoveHabit(JournalFieldSpec h) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmRemove(
      context,
      title:
          l?.wellnessRemoveHabitConfirmTitle(h.label) ?? 'Remove ${h.label}?',
      body:
          l?.wellnessRemoveHabitConfirmBody ??
          'It stops being asked. The days you already recorded stay.',
    );
    if (!ok || !mounted) return;
    final repo = context.read<AppState>().repo;
    if (repo == null) return;
    await repo.deleteCustomJournalField(h.key);
    await _load();
  }

  Future<void> _addHabit(BuildContext c) async {
    final l = AppLocalizations.of(c);
    final name = await _askName(
      c,
      l?.wellnessAddAHabit ?? 'Add a habit',
      l?.wellnessHabitHint ?? 'Walk after lunch',
    );
    if (name == null || name.isEmpty || !mounted) return;
    final repo = context.read<AppState>().repo;
    if (repo == null) return;
    // Same guard as the custom-field sheet: a name with no letters or digits
    // ("???") slugs to the bare `custom_` every other such name shares.
    if (customJournalFieldKey(name) == customJournalFieldKey('')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)?.journalFieldErrorInvalidName ??
                'Use at least one letter or number',
          ),
        ),
      );
      return;
    }
    try {
      await repo.postCustomJournalField(
        JournalFieldSpec(
          key: customJournalFieldKey(name),
          label: name,
          kind: JournalFieldKind.rating,
          unit: '',
          max: 1,
          step: 1,
          custom: true,
        ),
      );
    } on StateError catch (_) {
      // putJournalFieldDef is create-only now — a duplicate lands here
      // instead of silently rewriting the first one's definition.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)?.wellnessAlreadyTrack(name) ??
                  'You already track "$name".',
            ),
          ),
        );
        return;
      }
    }
    await _load();
  }

  // ── MEDICATION ───────────────────────────────────────────────────────────

  Widget _medication(BuildContext c) {
    final l = AppLocalizations.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_meds.isEmpty)
          StatusCard(
            l?.wellnessNothingScheduledTitle ?? 'Nothing scheduled',
            l?.wellnessNothingScheduledBody ?? 'Add what you take and when.',
            fix: l?.wellnessAddAMedication ?? 'Add a medication',
            icon: LucideIcons.pill,
            onFix: () => _addMed(c),
          )
        else ...[
          // A medication with no slot TODAY is not an empty screen. It happens
          // for ordinary reasons — the days exclude today, the time had already
          // passed when it was added (`slotsForDay` will not invent a slot
          // behind you), or the day being viewed is not today — and every one
          // of them used to render an empty `Surface`: added a medication, no
          // tracker, nothing said. Absence states its reason, and the schedule
          // itself is the reason, so it is what gets printed.
          if (_slots.isEmpty) ...[
            StatusCard(
              l?.wellnessNothingDueTodayTitle ?? 'Nothing due today',
              l?.wellnessNothingDueTodayBody ??
                  'What you take is scheduled for other days or times.',
              icon: LucideIcons.pill,
            ),
            const SizedBox(height: S.x3),
            Surface(
              pad: const EdgeInsets.symmetric(vertical: S.x2),
              child: Column(
                children: [
                  for (final d in _meds)
                    for (final sch in d.schedule) _scheduleRow(c, d, sch),
                ],
              ),
            ),
          ] else
            Surface(
              pad: const EdgeInsets.symmetric(horizontal: S.x4),
              child: Column(
                children: [
                  for (final s in _slots)
                    MedRow(
                      slot: s,
                      onTap: () => _markDose(s),
                      // Everything that is not "I took it" lives behind here:
                      // skipping a dose on purpose, fixing the days it is due,
                      // and the exit for a course you finished — which used to
                      // keep coming due every day with nothing but "Delete
                      // everything" to stop it.
                      onMore: () => _medActions(c, s),
                    ),
                ],
              ),
            ),
          Section(
            l?.wellnessAdherence ?? 'Adherence',
            // An empty denominator is not an adherence of nothing. Consistency
            // would print "0 of 0 days" with an empty bar under it, which reads
            // as a failure; the reason is the honest answer until a dose has
            // actually come due.
            _adherence.of == 0
                ? StatusCard(
                    l?.wellnessNothingToScoreTitle ?? 'Nothing to score yet',
                    l?.wellnessNothingToScoreBody ??
                        'No scheduled doses have come due yet.',
                    icon: LucideIcons.pill,
                  )
                : Surface(
                    child: Consistency(
                      _adherence.taken,
                      _adherence.of,
                      l?.wellnessTakenOfScheduled ??
                          'Taken, of those scheduled in the last seven days.',
                      C.blue,
                      // Doses, not days — three a day over a week is 21 of
                      // them inside a seven-day window.
                      unit: l?.wellnessDosesUnit ?? 'doses',
                    ),
                  ),
          ),
          const SizedBox(height: S.x4),
          BigButton(
            l?.wellnessAddAMedication ?? 'Add a medication',
            icon: LucideIcons.plus,
            color: C.domMind,
            soft: true,
            onTap: () => _addMed(c),
          ),
        ],
      ],
    );
  }

  /// One scheduled time that is not due today: what it is, and when it is due.
  ///
  /// The row edits the schedule; its separate menu also permits removal.
  /// A day without a scheduled dose never offers take or skip actions.
  Widget _scheduleRow(BuildContext c, MedDef d, MedSchedule sch) {
    final slot = MedSlot(
      def: d,
      date: _date,
      slotMin: sch.minuteOfDay,
      state: DoseState.upcoming,
    );
    return Row(
      children: [
        Expanded(
          child: _SheetAction(
            LucideIcons.pill,
            d.label,
            sub: '${_daysLabel(c, sch.days)} · ${slot.timeLabel}',
            onTap: () => _editSchedule(c, slot),
          ),
        ),
        Pressable(
          semanticLabel:
              AppLocalizations.of(c)?.wellnessMoreForMed(d.label) ??
              'More for ${d.label}',
          onTap: () => _medActions(c, slot, scheduledToday: false),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x3),
            child: Icon(LucideIcons.ellipsis, size: 18, color: P.of(c).ink3),
          ),
        ),
      ],
    );
  }

  Future<void> _markDose(MedSlot s) async {
    final db = await LocalDb.instance;
    await MedDb.mark(
      db,
      medKey: s.def.key,
      date: s.date,
      slotMin: s.slotMin,
      taken: s.state != DoseState.taken,
    );
    await _wrote();
  }

  /// A dose deliberately NOT taken.
  ///
  /// `DoseState.skipped` has been in the enum, the schema and the row label
  /// since the store was written and nothing could ever enter it: `mark`'s only
  /// caller never passed `skipped`, so every untaken dose read back as
  /// `missed`. The count does not change — `adherence()` counts by decided, and
  /// both are decided-and-not-taken — but "I chose not to" and "I forgot" are
  /// not the same fact about a medication, and the user could not record the
  /// difference or correct it afterwards.
  Future<void> _skipDose(MedSlot s) async {
    final db = await LocalDb.instance;
    await MedDb.mark(
      db,
      medKey: s.def.key,
      date: s.date,
      slotMin: s.slotMin,
      taken: false,
      skipped: s.state != DoseState.skipped,
    );
    await _wrote();
  }

  Future<void> _medActions(
    BuildContext c,
    MedSlot s, {
    bool scheduledToday = true,
  }) async {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final skipped = s.state == DoseState.skipped;
    await showModalBottomSheet<void>(
      context: c,
      backgroundColor: p.card,
      sheetAnimationStyle: sheetMotion(c),
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(S.x5, 0, S.x5, S.x3),
              child: Text(
                '${s.def.label} · ${s.timeLabel}',
                style: F.head.copyWith(color: p.ink),
              ),
            ),
            if (scheduledToday)
              _SheetAction(
                LucideIcons.circleSlash,
                skipped
                    ? (l?.wellnessUndoSkipped ?? 'Undo skipped')
                    : (l?.wellnessSkippedOnPurpose ?? 'Skipped on purpose'),
                sub: skipped
                    ? (l?.wellnessBackToNotTaken ?? 'Back to not taken.')
                    : (l?.wellnessRecordedAsDecision ??
                          'Recorded as a decision, not a miss.'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _skipDose(s);
                },
              ),
            _SheetAction(
              LucideIcons.calendarDays,
              l?.wellnessWhichDaysDue ?? 'Which days it is due',
              sub: _daysLabel(c, _daysFor(s)),
              onTap: () {
                Navigator.of(sheet).pop();
                _editSchedule(c, s);
              },
            ),
            _SheetAction(
              LucideIcons.trash2,
              l?.wellnessRemoveMedTitle(s.def.label) ?? 'Remove ${s.def.label}',
              sub:
                  l?.wellnessRemoveMedBody ??
                  'It stops being scheduled. Marked doses stay.',
              onTap: () {
                Navigator.of(sheet).pop();
                _confirmRemoveMed(s.def);
              },
            ),
            const SizedBox(height: S.x4),
          ],
        ),
      ),
    );
  }

  /// The weekdays THIS slot is due on. An empty list means every day — that is
  /// `MedSchedule.onDay`'s own rule, not a guess made here.
  List<int> _daysFor(MedSlot s) {
    for (final sch in s.def.schedule) {
      if (sch.minuteOfDay == s.slotMin) {
        return sch.days.isEmpty ? const [1, 2, 3, 4, 5, 6, 7] : sch.days;
      }
    }
    return const [1, 2, 3, 4, 5, 6, 7];
  }

  Future<void> _editSchedule(BuildContext c, MedSlot s) async {
    final picked = await pickMedSchedule(
      c,
      minuteOfDay: s.slotMin,
      days: _daysFor(s),
    );
    if (picked == null || !mounted) return;
    // Only THIS slot is rewritten. A medication with a morning and an evening
    // dose keeps the other one exactly as it was.
    final rest = [
      for (final sch in s.def.schedule)
        if (sch.minuteOfDay != s.slotMin) sch,
    ];
    await MedDb.putDef(
      await LocalDb.instance,
      MedDef(
        key: s.def.key,
        label: s.def.label,
        doseValue: s.def.doseValue,
        doseUnit: s.def.doseUnit,
        kind: s.def.kind,
        note: s.def.note,
        active: s.def.active,
        createdAt: s.def.createdAt,
        schedule: [...rest, MedSchedule(picked.minuteOfDay, picked.days)],
      ),
    );
    await _wrote();
  }

  /// Remove the medication, keep the doses.
  ///
  /// `MedDb.deleteDef` keeps `med_dose` on purpose (see its note): those doses
  /// were taken, and the CSV export still carries them. What stops is the
  /// schedule — and with it the empty denominator that was dragging adherence
  /// down every day after the course ended.
  Future<void> _confirmRemoveMed(MedDef d) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmRemove(
      context,
      title: l?.wellnessRemoveMedConfirmTitle(d.label) ?? 'Remove ${d.label}?',
      body:
          l?.wellnessRemoveMedConfirmBody ??
          'It stops being scheduled and stops counting towards adherence. '
              'The doses you already marked stay.',
    );
    if (!ok || !mounted) return;
    await MedDb.deleteDef(await LocalDb.instance, d.key);
    await _wrote();
  }

  Future<void> _addMed(BuildContext c) async {
    final l = AppLocalizations.of(c);
    final name = await _askName(
      c,
      l?.wellnessAddAMedication ?? 'Add a medication',
      l?.wellnessMedHint ?? 'Vitamin D',
    );
    if (name == null || name.isEmpty) return;
    if (!c.mounted) return;
    // The weekdays used to be hardcoded to all seven with no way back in, so a
    // Monday-and-Thursday drug generated five phantom slots a week that
    // resolved as missed and went into adherence's denominator — a wrong number
    // on screen, produced by the app rather than by the person.
    final picked = await pickMedSchedule(c);
    if (picked == null || !mounted) return;
    await MedDb.putDef(
      await LocalDb.instance,
      MedDef(
        key: MedDb.keyFor(name),
        label: name,
        // Dose is left null — "as directed" is a real answer, and demanding a
        // number to get a reminder is how a checklist stops being used.
        schedule: [MedSchedule(picked.minuteOfDay, picked.days)],
      ),
    );
    await _wrote();
  }

  Future<String?> _askName(BuildContext c, String title, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: c,
      builder: (d) {
        final l = AppLocalizations.of(d);
        return AlertDialog(
          backgroundColor: P.of(d).card,
          title: Text(title, style: F.head.copyWith(color: P.of(d).ink)),
          content: OsTextField(
            controller: ctrl,
            label: l?.wellnessNameLabel ?? 'Name',
            hint: hint,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(d).pop(),
              child: Text(
                l?.actionCancel ?? 'Cancel',
                style: F.body.copyWith(color: P.of(d).ink2),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(d).pop(ctrl.text.trim()),
              child: Text(
                l?.wellnessAdd ?? 'Add',
                style: F.body.copyWith(color: P.of(d).on(C.domMind)),
              ),
            ),
          ],
        );
      },
    ).whenComplete(ctrl.dispose);
  }
}

// ── helpers ────────────────────────────────────────────────────────────────

/// A duration read from the breathing ledger, or absence for a malformed leaf.
double? _reading(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

/// A label and a sentence. Used by journal findings and habit effects, both of
/// which genuinely have only those two things.
///
/// It is NOT the readiness driver row any more — that claim ("the glass box
/// does not emit per-driver point contributions") was wrong, and it is what
/// kept "What charged and drained you" printing two bare words. The breakdown
/// carries a weight, a signed contribution and a spread gate per input, and
/// the baselines block carries the reading, the centre, the spread and the MDC.
/// See [DriverBreakdown].
class DriverRow extends StatelessWidget {
  const DriverRow({super.key, required this.label, required this.detail});

  final String label, detail;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.dot, size: 18, color: p.on(C.domMind)),
          const SizedBox(width: S.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: F.body.copyWith(color: p.ink)),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: F.over.copyWith(color: p.ink3, height: 1.4),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The days a dose is due, in the words a person would use. `DateTime.weekday`
/// values, 1 = Monday; empty means every day.
String _daysLabel(BuildContext c, List<int> days) {
  final l = AppLocalizations.of(c);
  final set = days.toSet();
  if (set.isEmpty || set.length == 7) return l?.wellnessEveryDay ?? 'Every day';
  if (set.length == 5 && !set.contains(6) && !set.contains(7)) {
    return l?.wellnessWeekdays ?? 'Weekdays';
  }
  if (set.length == 2 && set.contains(6) && set.contains(7)) {
    return l?.wellnessWeekends ?? 'Weekends';
  }
  final sorted = set.toList()..sort();
  return [for (final d in sorted) weekdayShortName(d, l)].join(', ');
}

/// Pick a time and the weekdays it repeats on. Returns null if dismissed.
///
/// One sheet for BOTH the add flow and the edit path, because a schedule the
/// user can enter but not correct is the shape of bug this replaced: the app
/// wrote seven days a week whatever the drug was, and then counted the days it
/// invented against the person taking it.
Future<MedSchedule?> pickMedSchedule(
  BuildContext c, {
  int minuteOfDay = 8 * 60,
  List<int> days = const [1, 2, 3, 4, 5, 6, 7],
}) async {
  var minute = minuteOfDay;
  var picked = days.toSet();
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  return showModalBottomSheet<MedSchedule>(
    context: c,
    backgroundColor: p.card,
    sheetAnimationStyle: sheetMotion(c),
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: StatefulBuilder(
        builder: (sheet, setSheet) {
          // Theme changes rebuild the open sheet without recreating its draft.
          final p = P.of(sheet);
          return Padding(
            padding: const EdgeInsets.fromLTRB(S.x5, 0, S.x5, S.x5),
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  l?.wellnessWhenYouTakeIt ?? 'When you take it',
                  style: F.head.copyWith(color: p.ink),
                ),
                const SizedBox(height: S.x4),
                Pressable(
                  semanticLabel: l?.wellnessChangeTheTime ?? 'Change the time',
                  onTap: () async {
                    final at = await showTimePicker(
                      context: sheet,
                      initialTime: TimeOfDay(
                        hour: (minute ~/ 60) % 24,
                        minute: minute % 60,
                      ),
                    );
                    if (sheet.mounted && at != null) {
                      setSheet(() => minute = at.hour * 60 + at.minute);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(S.x4),
                    decoration: BoxDecoration(
                      color: p.card2,
                      borderRadius: R.controlOf(sheet),
                    ),
                    child: Row(
                      children: [
                        Icon(LucideIcons.clock, size: 17, color: p.ink3),
                        const SizedBox(width: S.x3),
                        Expanded(
                          child: Text(
                            formatMinuteOfDay(minute),
                            style: F.n17.copyWith(color: p.ink),
                          ),
                        ),
                        Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: S.x4),
                Text(
                  l?.wellnessWhichDays ?? 'WHICH DAYS',
                  style: F.over.copyWith(color: p.ink3),
                ),
                const SizedBox(height: S.x2),
                Wrap(
                  spacing: S.x2,
                  runSpacing: S.x2,
                  children: [
                    for (var d = 1; d <= 7; d++)
                      Pressable(
                        semanticLabel: weekdayShortName(d, l),
                        onTap: () => setSheet(() {
                          picked.contains(d) ? picked.remove(d) : picked.add(d);
                        }),
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(
                            horizontal: S.x4,
                            vertical: S.x2,
                          ),
                          decoration: BoxDecoration(
                            color: picked.contains(d)
                                ? p.wash(C.domMind)
                                : p.card2,
                            borderRadius: R.rPill,
                            border: Border.all(
                              color: picked.contains(d)
                                  ? p.on(C.domMind)
                                  : p.line,
                            ),
                          ),
                          child: Text(
                            weekdayShortName(d, l),
                            style: F.cap.copyWith(
                              color: picked.contains(d)
                                  ? p.on(C.domMind)
                                  : p.ink2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: S.x3),
                // A schedule with no days is not a schedule. Saying so beats
                // saving one that can never come due.
                Text(
                  picked.isEmpty
                      ? (l?.wellnessPickAtLeastOneDay ??
                            'Pick at least one day.')
                      : (l?.wellnessDueDays(_daysLabel(c, picked.toList())) ??
                            'Due ${_daysLabel(c, picked.toList()).toLowerCase()}.'),
                  style: F.cap.copyWith(color: p.ink3),
                ),
                const SizedBox(height: S.x4),
                BigButton(
                  l?.actionSave ?? 'Save',
                  color: C.domMind,
                  onTap: picked.isEmpty
                      ? null
                      : () => Navigator.of(
                          sheet,
                        ).pop(MedSchedule(minute, picked.toList()..sort())),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _SheetAction extends StatelessWidget {
  const _SheetAction(this.icon, this.title, {this.sub = '', this.onTap});
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.x5, vertical: S.x3),
        child: Row(
          children: [
            Icon(icon, size: 17, color: p.ink3),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: F.body.copyWith(color: p.ink)),
                  if (sub.isNotEmpty)
                    Text(sub, style: F.cap.copyWith(color: p.ink3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One scheduled dose. A slot still ahead of you reads as upcoming, never as a
/// miss — that distinction is the whole reason `taken_ts` is nullable.
class MedRow extends StatelessWidget {
  const MedRow({super.key, required this.slot, this.onTap, this.onMore});

  final MedSlot slot;
  final VoidCallback? onTap;

  /// Everything that is not "I took it": skip, reschedule, remove. Null hides
  /// the control. There is no long-press or swipe here on purpose — `Pressable`
  /// is the app's only gesture, so a second action needs a second target.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final taken = slot.state == DoseState.taken;
    return Pressable(
      onTap: onTap,
      semanticLabel:
          l?.wellnessMedAtTime(slot.def.label, slot.timeLabel) ??
          '${slot.def.label} at ${slot.timeLabel}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: p.wash(C.blue),
                borderRadius: R.controlOf(c),
              ),
              child: Icon(LucideIcons.pill, size: 17, color: p.on(C.blue)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    slot.def.label,
                    style: F.body.copyWith(color: taken ? p.ink3 : p.ink),
                  ),
                  Text(
                    '${slot.def.doseLabel} · ${slot.timeLabel} · '
                    '${_stateLabel(l, slot.state)}',
                    style: F.over.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
            if (onMore != null)
              Pressable(
                semanticLabel:
                    l?.wellnessMoreForMed(slot.def.label) ??
                    'More for ${slot.def.label}',
                onTap: onMore,
                child: Padding(
                  padding: const EdgeInsets.only(right: S.x3),
                  child: Icon(LucideIcons.ellipsis, size: 18, color: p.ink3),
                ),
              ),
            _Check(on: taken, onTap: null),
          ],
        ),
      ),
    );
  }

  static String _stateLabel(AppLocalizations? l, DoseState s) => switch (s) {
    DoseState.taken => l?.wellnessStateTaken ?? 'taken',
    DoseState.skipped => l?.wellnessStateSkipped ?? 'skipped',
    DoseState.missed => l?.wellnessStateNotTaken ?? 'not taken',
    DoseState.upcoming => l?.wellnessStateDueLater ?? 'due later',
  };
}

class _Check extends StatelessWidget {
  const _Check({required this.on, required this.onTap});
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final box = AnimatedContainer(
      duration: motion(c, Motion.base),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? p.fill(C.green) : p.card2,
        border: on ? null : Border.all(color: p.line, width: 1.6),
      ),
      child: on
          ? Icon(LucideIcons.check, size: 15, color: p.inkOnFill)
          : const SizedBox.shrink(),
    );
    if (onTap == null) return box;
    final l = AppLocalizations.of(c);
    return Pressable(
      semanticLabel: on
          ? (l?.actionDone ?? 'Done')
          : (l?.wellnessMarkDone ?? 'Mark done'),
      onTap: onTap,
      child: box,
    );
  }
}

// ══════════════════ WHAT YOU LOG, AGAINST YOUR NUMBERS ══════════════════
//
// MIND-01 (dose response), MIND-04 (habits), MT-06 (caffeine timing),
// MT-07 (alcohol phrasing) and MIND-12 (weekday) all answer the same question
// from the same place, so they are one screen behind one tap rather than five
// cards competing on the Habits tab.
//
// EVERYTHING HERE IS ASSOCIATION ON YOUR OWN DAYS. Never cause, never a
// recommendation, never a nudge. The confound is total and stated: the days you
// do a thing are days you were already that kind of day.
//
// The empty state is the DEFAULT outcome, not an error. 9 built-in numeric
// fields × 4 outcomes is 36 simultaneous tests, so a per-test gate manufactures
// about two findings per user out of pure noise; analytics corrects the whole
// grid with Benjamini-Hochberg and most people will see nothing. A screen that
// cannot say "nothing separated itself" is a screen that will invent something.

class JournalFindings extends StatefulWidget {
  /// Non-null skips the repository, the way every other detail screen here
  /// takes its fixture.
  final List<Map<String, dynamic>>? rows;
  final Map<String, dynamic>? weekday;

  const JournalFindings({super.key, this.rows, this.weekday});

  @override
  State<JournalFindings> createState() => _JournalFindingsState();
}

class _JournalFindingsState extends State<JournalFindings> {
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _weekday = const {};
  bool _loading = true;
  bool _loadError = false;

  @override
  void initState() {
    super.initState();
    if (widget.rows != null) {
      _rows = widget.rows!;
      _weekday = widget.weekday ?? const {};
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = false;
    });
    final repo = context.read<AppState>().repo;
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final j = await repo.getJournalInsights(range: '90d');
      final w = await repo.getWeekdayEffect();
      if (!mounted) return;
      setState(() {
        _rows = [
          for (final e in (j['numeric_insights'] as List? ?? const []))
            if (e is Map) e.cast<String, dynamic>(),
        ];
        _weekday = w;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final title = l?.wellnessWhatYouLogScreenTitle ?? 'What you log';
    if (_loading) {
      return detailScaffold(c, title, const [
        SizedBox(height: S.x8),
        Center(child: CircularProgressIndicator()),
      ]);
    }
    if (_loadError) {
      return detailScaffold(c, title, [
        StatusCard(
          l?.wellnessFindingsErrorTitle ?? 'Could not load your findings',
          l?.wellnessFindingsErrorBody ??
              'Your saved analysis could not be read. Try again.',
          fix: l?.healthTryAgain ?? 'Try again',
          icon: LucideIcons.refreshCw,
          onFix: _load,
        ),
      ]);
    }
    final p = P.of(c);
    final doses = [
      for (final r in _rows)
        if (r['binary'] != true) r,
    ];
    final habits = [
      for (final r in _rows)
        if (r['binary'] == true) r,
    ];
    return detailScaffold(c, title, [
      const SizedBox(height: S.x2),
      if (_rows.isEmpty)
        StatusCard(
          l?.wellnessNothingSeparatedTitle ?? 'Nothing separated itself yet',
          l?.wellnessNothingSeparatedBody ??
              'Everything you log is tested against your recovery, HRV, '
                  'resting heart rate and sleep efficiency. Nothing has '
                  'cleared the bar yet.',
          icon: LucideIcons.scatterChart,
        )
      else ...[
        if (habits.isNotEmpty)
          Section(
            l?.wellnessTheDaysYouDidIt ?? 'The days you did it',
            _list(c, habits),
          ),
        if (doses.isNotEmpty)
          Section(
            l?.wellnessHowMuchAndWhatFollowed ?? 'How much, and what followed',
            _list(c, doses),
          ),
        const SizedBox(height: S.x2),
        Text(
          l?.wellnessLinkNeverCause ??
              'A link on your own days — never a cause. The days you do a '
                  'thing are days you were already that kind of day.',
          style: F.over.copyWith(color: p.ink3, height: 1.5),
        ),
      ],
      Section(
        l?.wellnessWhichDayOfWeek ?? 'Which day of the week',
        _weekdayCard(c),
      ),
    ]);
  }

  Widget _list(BuildContext c, List<Map<String, dynamic>> rows) {
    final l = AppLocalizations.of(c);
    return Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4),
      child: Column(
        children: [
          for (final r in rows)
            DriverRow(label: _headline(l, r), detail: _detail(l, r)),
        ],
      ),
    );
  }

  // ── copy ────────────────────────────────────────────────────────────────

  /// MT-07's whole change: the outcome's own units on the days she logged it,
  /// not a rank correlation read out loud. "On the 11 nights you logged
  /// alcohol, your resting HR ran 6 bpm higher" is the same finding the rho
  /// carried and a sentence a person can check against their own memory.
  String _headline(AppLocalizations? l, Map<String, dynamic> r) {
    final field = (r['field_label'] ?? '').toString();
    final outcome = (r['outcome_label'] ?? '').toString();
    final unit = (r['unit'] ?? '').toString();
    if (r['binary'] == true) {
      final delta = (r['delta'] as num?)?.toDouble() ?? 0;
      final direction = delta > 0
          ? (l?.wellnessHigher ?? 'higher')
          : (l?.wellnessLower ?? 'lower');
      final n = '${r['n_with']}';
      final amount = _amount(delta.abs(), unit);
      return l?.wellnessHeadlineBinary(n, field, outcome, amount, direction) ??
          'On the $n days you logged $field, $outcome ran $amount $direction';
    }
    final n = '${r['n']}';
    final slope = (r['slope_per_unit'] as num?)?.toDouble();
    final rho = (r['rho'] as num?)?.toDouble() ?? 0;
    if (slope == null) {
      final direction = rho > 0
          ? (l?.wellnessHigher ?? 'higher')
          : (l?.wellnessLower ?? 'lower');
      return l?.wellnessHeadlineNoSlope(n, field, direction, outcome) ??
          'On the $n days you logged $field, more of it went with '
              '$direction $outcome';
    }
    final (per, step) = _perUnit(l, r);
    final direction = slope > 0
        ? (l?.wellnessHigher ?? 'higher')
        : (l?.wellnessLower ?? 'lower');
    final amount = _amount((slope * per).abs(), unit);
    return l?.wellnessHeadlineSlope(
          n,
          field,
          outcome,
          amount,
          direction,
          step,
        ) ??
        'On the $n days you logged $field, $outcome ran '
            '$amount $direction per $step';
  }

  /// MIND-02 — WHICH NIGHT this row is about.
  ///
  /// Outcomes labelled with a date come from the night that ENDED on that
  /// morning, while the journal row is written at bedtime and describes the
  /// daytime. So analytics pairs each field at its own lag: behaviour (coffee,
  /// alcohol, water, steps) lands on the night that FOLLOWS, and a
  /// retrospective self-report (mood, sleep quality, soreness) already
  /// describes the night that just finished. It is never a blanket shift — the
  /// two kinds point in opposite directions and one constant breaks half of
  /// them.
  ///
  /// Said out loud on every row, because the alignment changed underneath
  /// findings people had already read, and a finding that quietly means a
  /// different night is a different finding.
  String _alignment(AppLocalizations? l, Map<String, dynamic> r) {
    // Read from the same constant analytics paired on, so the sentence cannot
    // drift away from the arithmetic.
    final field = (r['field'] ?? '').toString();
    // The two derived caffeine-timing keys carry caffeine's own lag.
    final lag =
        journalFieldLagDays[field] ??
        (field.startsWith('caffeine') ? journalFieldLagDays['caffeine'] : null);
    if (lag == null) {
      return l?.wellnessMatchedSameDay ??
          'Matched against the same day\'s numbers.';
    }
    return lag > 0
        ? (l?.wellnessMatchedNightFollowed ??
              'Matched against the night that followed.')
        : (l?.wellnessMatchedNightEnded ??
              'Matched against the night that ended that morning.');
  }

  String _detail(AppLocalizations? l, Map<String, dynamic> r) {
    final when = _alignment(l, r);
    if (r['binary'] == true) {
      final d = (r['cohens_d'] as num?)?.toDouble();
      final n = '${r['n_without']}';
      final against =
          l?.wellnessAgainstDaysYouDidNot(n) ??
          'Against the $n days you did not';
      return '$against'
          '${d == null ? '' : ' · d ${d.abs().toStringAsFixed(1)}'}. $when';
    }
    final lo = (r['rho_low'] as num?)?.toDouble();
    final hi = (r['rho_high'] as num?)?.toDouble();
    final rho = (r['rho'] as num?)?.toDouble();
    final ci = (lo == null || hi == null)
        ? ''
        : ' (${l?.wellnessRangeTo(lo.toStringAsFixed(2), hi.toStringAsFixed(2)) ?? '${lo.toStringAsFixed(2)} to ${hi.toStringAsFixed(2)}'})';
    final base = rho == null
        ? ''
        : (l?.wellnessRankCorrelation(rho.toStringAsFixed(2), ci) ??
              'Rank correlation ${rho.toStringAsFixed(2)}$ci. ');
    // MT-06's own ceiling, said where the finding is: `at_min` is the LAST
    // occurrence, so timing cannot tell two coffees from five, and a late
    // stressful day produces both the late coffee and the bad night.
    if (r['field'] == 'caffeine_last_min') {
      return '$base$when ${l?.wellnessCaffeineCaveat ?? 'This is your last '
              'caffeine of the day only — two cups and five look identical '
              'here, so "later" can quietly mean "more". A long, stressful day '
              'produces both the late coffee and the poor night.'}';
    }
    return '$base$when'.trim();
  }

  /// How to say one step of this field. Minutes-past-midnight is unreadable per
  /// minute, so caffeine timing is stated per HOUR later — a slope, never a
  /// cutoff time, which is a threshold read off a dozen self-reported points.
  (double, String) _perUnit(AppLocalizations? l, Map<String, dynamic> r) {
    if (r['field'] == 'caffeine_last_min') {
      return (60.0, l?.wellnessHourLater ?? 'hour later');
    }
    final u = (r['field_unit'] ?? '').toString();
    // Singular: the phrase is "per unit", "per mg", "per point".
    final one = u.isEmpty
        ? (l?.wellnessPointUnit ?? 'point')
        : (u.endsWith('s') ? u.substring(0, u.length - 1) : u);
    return (1.0, one);
  }

  String _amount(double v, String unit) {
    final n = v >= 10 ? v.round().toString() : v.toStringAsFixed(1);
    return unit.isEmpty ? n : '$n $unit';
  }

  // ── MIND-12 ─────────────────────────────────────────────────────────────

  /// Two gates, and both of them refusing is the normal answer. Kruskal-Wallis
  /// across the seven groups, then a permutation test on the biggest gap — the
  /// second one is what pays for having looked at seven days and reported the
  /// worst. Without it this is a machine for manufacturing weekday
  /// superstitions.
  Widget _weekdayCard(BuildContext c) {
    final l = AppLocalizations.of(c);
    if (_weekday['present'] != true) {
      return StatusCard(
        l?.wellnessNotEnoughWeeksTitle ?? 'Not enough weeks yet',
        l?.wellnessNotEnoughWeeksBody ??
            'Comparing seven weekdays needs at least eight weeks of days, '
                'with five of every weekday in them.',
        icon: LucideIcons.calendarDays,
      );
    }
    if (_weekday['meaningful'] != true) {
      return StatusCard(
        l?.wellnessNoDayStandsOutTitle ?? 'No day of the week stands out',
        l?.wellnessNoDayStandsOutBody ??
            'No day stands apart from the other six once we account for '
                'having checked all seven.',
        icon: LucideIcons.calendarDays,
      );
    }
    final day = (_weekday['peak_weekday'] as num?)?.toInt() ?? 1;
    final delta = (_weekday['peak_delta'] as num?)?.toDouble() ?? 0;
    final n = (_weekday['n_by_weekday'] as Map?)?['$day'];
    final direction = delta > 0
        ? (l?.wellnessHigher ?? 'higher')
        : (l?.wellnessLower ?? 'lower');
    final weekdayPlural = _weekdayPlural(l, day);
    return Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4),
      child: DriverRow(
        label:
            l?.wellnessWeekdayHeadline(
              weekdayPlural,
              '${delta.abs().round()}',
              direction,
            ) ??
            '${_weekdayName(day)}s: readiness runs '
                '${delta.abs().round()} $direction than your overall median',
        detail:
            l?.wellnessWeekdayDetail('$n') ??
            'From $n of them. A weekday is not a cause — it is a container '
                'for what you do on it. Nothing here is advice.',
      ),
    );
  }
}

/// The localized plural weekday name ("Mondays"), for [weekday] 1 = Monday.
String _weekdayPlural(AppLocalizations? l, int weekday) {
  final fallback = '${_weekdayName(weekday)}s';
  return switch (weekday) {
    1 => l?.wellnessPluralMonday ?? fallback,
    2 => l?.wellnessPluralTuesday ?? fallback,
    3 => l?.wellnessPluralWednesday ?? fallback,
    4 => l?.wellnessPluralThursday ?? fallback,
    5 => l?.wellnessPluralFriday ?? fallback,
    6 => l?.wellnessPluralSaturday ?? fallback,
    _ => l?.wellnessPluralSunday ?? fallback,
  };
}

const _kWeekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String _weekdayName(int weekday) => _kWeekdayNames[(weekday - 1).clamp(0, 6)];
