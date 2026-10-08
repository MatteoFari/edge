// The band alarm.
//
// This screen exists because the alarm is the one thing in the app that keeps
// working when the app does not. It is armed on the STRAP's own real-time
// clock, so it survives the app being killed, the phone rebooting, and the
// phone being out of range entirely. The rebuild shipped with no alarm UI at
// all while `AppState` still restored `alarm_epoch` on launch and still ran the
// confirmation state machine — which means an alarm armed on an older build
// went on firing every morning with nothing anywhere to see it or stop it.
//
// The honesty problem is confirmation. Writing SET_ALARM to the band is not
// evidence that the band latched it; the strap says so separately, by emitting
// event 56, and it might never arrive. And after a relaunch there is no live
// confirmation at all — only the epoch we wrote down. Three different states,
// and the screen says which one it is rather than drawing a confident green
// tick over all three.
//
// A single next-occurrence time picker used to live here. It is gone: the
// weekly schedule below is now the ONLY thing that arms the band (AppState
// computes the next enabled occurrence on every connect/sync), so a second,
// independent "set one alarm" affordance would just be a second source of
// truth that the schedule engine silently overwrites on the next sync.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/day_label.dart' show calendarDaysBetween;
import '../../l10n/app_localizations.dart';
import '../../state/alarm_schedule.dart';
import '../../state/app_state.dart';
import '../../state/clock_format.dart' show formatClock, use24HourClock;
import '../screens/home_screen.dart' show weekdayShortName;
import '../screens/metric_detail.dart' show detailLinkRow;
import '../ui2.dart';

/// What we actually know about the armed alarm.
enum AlarmArmState {
  /// Nothing armed.
  none,

  /// Written to the band; its confirmation event may still be in flight.
  pending,

  /// The band emitted ALARM_SET — it latched.
  confirmed,

  /// Armed, but unconfirmed: either the band never acknowledged the write, or
  /// this is an alarm from a previous run of the app and there is no live
  /// confirmation to read. Both mean the same thing to the user — we cannot
  /// promise it will fire — so they share one state rather than being dressed
  /// up as two.
  unknown,
}

bool _unusedDay(AlarmScheduleEntry day) => !day.configured;

/// The database has one slot per weekday, so matching saved settings form one
/// editable schedule. Untouched default/off slots remain available to add to
/// it. Other groups are never part of the editor's update.
List<List<AlarmScheduleEntry>> _alarmGroups(List<AlarmScheduleEntry> schedule) {
  final groups = <List<AlarmScheduleEntry>>[];
  for (final day in schedule) {
    if (_unusedDay(day)) continue;
    final index = groups.indexWhere((group) {
      final first = group.first;
      return first.hour == day.hour &&
          first.minute == day.minute &&
          first.enabled == day.enabled &&
          first.smartWindowMinutes == day.smartWindowMinutes;
    });
    if (index < 0) {
      groups.add([day]);
    } else {
      groups[index].add(day);
    }
  }
  return groups;
}

String _repeatLabel(BuildContext c, Set<int> days) {
  final l = AppLocalizations.of(c);
  if (days.length == 7) return l?.alarmEveryDay ?? 'Every day';
  if (days.length == 5 && days.containsAll(const [0, 1, 2, 3, 4])) {
    return l?.alarmWeekdays ?? 'Weekdays';
  }
  if (days.length == 2 && days.containsAll(const [5, 6])) {
    return l?.alarmWeekends ?? 'Weekends';
  }
  return [
    for (var day = 0; day < 7; day++)
      if (days.contains(day)) weekdayShortName(day + 1, l),
  ].join(' · ');
}

class _AlarmEditor extends StatefulWidget {
  final List<AlarmScheduleEntry> schedule, original;
  final Future<void> Function(List<AlarmScheduleEntry>)? onSave;

  const _AlarmEditor({
    required this.schedule,
    required this.original,
    required this.onSave,
  });

  @override
  State<_AlarmEditor> createState() => _AlarmEditorState();
}

class _AlarmEditorState extends State<_AlarmEditor> {
  late TimeOfDay _time;
  late Set<int> _days;
  late Set<int> _available;
  late bool _enabled;
  late int _smartMinutes;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final first = widget.original.firstOrNull;
    _time = TimeOfDay(
      hour: first?.hour ?? defaultAlarmHour,
      minute: first?.minute ?? defaultAlarmMinute,
    );
    _enabled = first?.enabled ?? true;
    _smartMinutes = first?.smartWindowMinutes ?? 0;
    _days = widget.original.map((day) => day.weekday).toSet();
    _available = {
      ..._days,
      for (final day in widget.schedule)
        if (_unusedDay(day)) day.weekday,
    };
    if (first == null) {
      _days = _available.intersection({0, 1, 2, 3, 4});
      if (_days.isEmpty) _days = {..._available};
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      initialEntryMode: TimePickerEntryMode.input,
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: use24HourClock),
        child: child!,
      ),
    );
    if (picked != null && mounted) setState(() => _time = picked);
  }

  Future<void> _pickSmartWindow() async {
    final l = AppLocalizations.of(context);
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(l?.alarmSmartWake ?? 'Smart wake'),
        children: [
          for (final minutes in const [0, 15, 30, 45])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, minutes),
              child: Text(
                minutes == 0
                    ? (l?.stateOff ?? 'Off')
                    : (l?.alarmSmartWakeEarly(minutes) ?? '$minutes min early'),
              ),
            ),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _smartMinutes = picked);
  }

  /// A removal or deselected weekday goes back to an unused off slot. Only
  /// the original group's weekdays can be removed; occupied days belonging
  /// to another group cannot be selected or changed here.
  Future<void> _save({bool delete = false}) async {
    final action = widget.onSave;
    if (_saving || action == null || (!delete && _days.isEmpty)) return;
    final selected = delete ? <int>{} : _days;
    final affected = {
      ...widget.original.map((day) => day.weekday),
      ...selected,
    };
    final entries = [
      for (var day = 0; day < 7; day++)
        if (affected.contains(day))
          AlarmScheduleEntry(
            weekday: day,
            hour: selected.contains(day) ? _time.hour : defaultAlarmHour,
            minute: selected.contains(day) ? _time.minute : defaultAlarmMinute,
            enabled: selected.contains(day) && _enabled,
            configured: selected.contains(day),
            smartWindowMinutes: selected.contains(day) ? _smartMinutes : 0,
          ),
    ];
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action(entries);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              e is StateError &&
                  e.message == 'The alarm schedule changed while editing.'
              ? (AppLocalizations.of(context)?.alarmScheduleChanged ??
                    'The schedule changed while you were editing. Your draft was '
                        'not saved. Reopen the editor to review the latest schedule.')
              : '$e'.replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _choice(
    BuildContext c,
    String label,
    bool selected,
    VoidCallback? onTap, {
    String? semanticLabel,
    bool compact = false,
  }) {
    final p = P.of(c);
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: semanticLabel ?? label,
      child: ExcludeSemantics(
        child: Pressable(
          onTap: onTap,
          child: AnimatedContainer(
            duration: motion(c, Motion.base),
            curve: Motion.effectsCurve(c),
            constraints: const BoxConstraints(minHeight: S.tap),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? S.x1 : S.x3,
              vertical: S.x2,
            ),
            decoration: BoxDecoration(
              color: selected ? p.fill(C.green) : p.card2,
              border: Border.all(color: selected ? p.fill(C.green) : p.line),
              borderRadius: R.controlOf(c),
            ),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: F.cap.copyWith(
                  color: selected
                      ? p.inkOnFill
                      : onTap == null
                      ? p.ink3
                      : p.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preset(BuildContext c, String label, Set<int> days) => _choice(
    c,
    label,
    _days.length == days.length && _days.containsAll(days),
    !_saving && _available.containsAll(days)
        ? () => setState(() => _days = {...days})
        : null,
  );

  Widget _weekdayChoices(BuildContext c) => LayoutBuilder(
    builder: (c, box) {
      final l = AppLocalizations.of(c);
      final choices = [
        for (var day = 0; day < 7; day++)
          _choice(
            c,
            weekdayShortName(day + 1, l),
            _days.contains(day),
            !_saving && _available.contains(day)
                ? () => setState(() {
                    if (!_days.add(day)) _days.remove(day);
                  })
                : null,
            semanticLabel: _weekdayName(c, day),
            compact: true,
          ),
      ];
      if (!bigText(c) && box.maxWidth >= S.tap * 7 + S.x1 * 6) {
        return Row(
          children: [
            for (var day = 0; day < 7; day++) ...[
              if (day > 0) const SizedBox(width: S.x1),
              Expanded(child: choices[day]),
            ],
          ],
        );
      }
      return Wrap(spacing: S.x2, runSpacing: S.x2, children: choices);
    },
  );

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final canSave = !_saving && widget.onSave != null && _days.isNotEmpty;
    final cancel = BigButton(
      l?.actionCancel ?? 'Cancel',
      soft: true,
      onTap: _saving ? null : () => Navigator.pop(c),
    );
    final save = Semantics(
      enabled: canSave,
      child: BigButton(
        _saving
            ? (l?.alarmSavingChanges ?? 'Saving…')
            : (l?.alarmSaveChanges ?? 'Save changes'),
        onTap: canSave ? () => _save() : null,
        soft: !canSave,
      ),
    );
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x8),
            children: [
              NavBar(
                l?.alarmEditorTitle ?? 'Wake schedule',
                onBack: _saving ? () {} : () => Navigator.pop(c),
              ),
              const SizedBox(height: S.x2),
              Text(
                l?.alarmEditorSubtitle ??
                    'Choose a time and the days it repeats.',
                style: F.body.copyWith(color: p.ink2),
              ),
              const SizedBox(height: S.x6),
              Text(
                l?.alarmWakeUpTime ?? 'Wake-up time',
                style: F.head.copyWith(color: p.ink2),
              ),
              const SizedBox(height: S.x3),
              Surface(
                semanticLabel:
                    '${l?.alarmWakeUpTime ?? 'Wake-up time'}, '
                    '${formatClock(_time.hour, _time.minute)}',
                color: p.wash(C.green),
                onTap: _saving ? null : _pickTime,
                pad: const EdgeInsets.all(S.x6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatClock(_time.hour, _time.minute),
                        style: (bigText(c) ? F.t2 : F.n48).copyWith(
                          color: p.on(C.green),
                        ),
                      ),
                    ),
                    const SizedBox(width: S.x3),
                    Icon(
                      LucideIcons.clock,
                      size: S.navIcon,
                      color: p.on(C.green),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: S.x6),
              Text(
                l?.alarmRepeatOn ?? 'Repeat on',
                style: F.head.copyWith(color: p.ink2),
              ),
              const SizedBox(height: S.x3),
              Wrap(
                spacing: S.x2,
                runSpacing: S.x2,
                children: [
                  _preset(c, l?.alarmWeekdays ?? 'Weekdays', {0, 1, 2, 3, 4}),
                  _preset(c, l?.alarmWeekends ?? 'Weekends', {5, 6}),
                  _preset(c, l?.alarmEveryDay ?? 'Every day', {
                    0,
                    1,
                    2,
                    3,
                    4,
                    5,
                    6,
                  }),
                ],
              ),
              const SizedBox(height: S.x3),
              _weekdayChoices(c),
              if (_available.length < 7) ...[
                const SizedBox(height: S.x3),
                Text(
                  l?.alarmOtherDaysUnavailable ??
                      'Days used by another alarm are unavailable.',
                  style: F.cap.copyWith(color: p.ink3),
                ),
              ],
              if (_days.isEmpty) ...[
                const SizedBox(height: S.x3),
                Text(
                  l?.alarmSelectDay ?? 'Select at least one day.',
                  style: F.cap.copyWith(color: p.on(C.orange)),
                ),
              ],
              const SizedBox(height: S.x4),
              Divider(color: p.line),
              Semantics(
                toggled: _enabled,
                enabled: !_saving,
                child: Surface(
                  elevation: 0,
                  color: p.bg,
                  onTap: _saving
                      ? null
                      : () => setState(() => _enabled = !_enabled),
                  pad: const EdgeInsets.symmetric(vertical: S.x3),
                  child: Row(
                    children: [
                      Icon(
                        _enabled ? LucideIcons.squareCheck : LucideIcons.square,
                        size: S.navIcon,
                        color: _enabled ? p.on(C.green) : p.ink3,
                      ),
                      const SizedBox(width: S.x3),
                      Expanded(
                        child: Text(
                          l?.alarmEnabledForDays ??
                              'Alarm on for selected days',
                          style: F.body.copyWith(color: p.ink),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(color: p.line),
              const SizedBox(height: S.x3),
              Text(
                l?.alarmSmartWake ?? 'Smart wake',
                style: F.head.copyWith(color: p.ink),
              ),
              const SizedBox(height: S.x2),
              Surface(
                elevation: 0,
                color: p.card2,
                semanticLabel:
                    '${l?.alarmSmartWake ?? 'Smart wake'}, '
                    '${_smartMinutes == 0 ? (l?.stateOff ?? 'Off') : (l?.alarmSmartWakeEarly(_smartMinutes) ?? '$_smartMinutes min early')}',
                onTap: _saving ? null : _pickSmartWindow,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _smartMinutes == 0
                            ? (l?.stateOff ?? 'Off')
                            : (l?.alarmSmartWakeEarly(_smartMinutes) ??
                                  '$_smartMinutes min early'),
                        style: F.body.copyWith(color: p.ink),
                      ),
                    ),
                    Icon(LucideIcons.chevronDown, color: p.ink3),
                  ],
                ),
              ),
              const SizedBox(height: S.x3),
              Text(
                _smartMinutes == 0
                    ? (l?.alarmFixedWakeExplanation ??
                          'The band buzzes at the wake-up time once the alarm is confirmed.')
                    : (l?.alarmSmartWakeExplanation ??
                          'While the app is connected, it may try an earlier buzz if it detects light sleep. The confirmed wake-up alarm stays on the band.'),
                style: F.cap.copyWith(color: p.ink2),
              ),
              const SizedBox(height: S.x6),
              if (_error != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: F.body.copyWith(color: p.on(C.red)),
                  ),
                ),
                const SizedBox(height: S.x3),
              ],
              if (bigText(c)) ...[
                save,
                const SizedBox(height: S.x3),
                cancel,
              ] else
                Row(
                  children: [
                    Expanded(child: cancel),
                    const SizedBox(width: S.x3),
                    Expanded(child: save),
                  ],
                ),
              const SizedBox(height: S.x3),
              Text(
                l?.alarmEditorDraftHint ??
                    'Nothing changes until Save. Other alarm entries stay unchanged.',
                style: F.cap.copyWith(color: p.ink3),
              ),
              if (widget.original.isNotEmpty) ...[
                const SizedBox(height: S.x6),
                Divider(color: p.line),
                const SizedBox(height: S.x3),
                BigButton(
                  l?.alarmDeleteEntry ?? 'Delete alarm',
                  color: C.red,
                  soft: true,
                  icon: LucideIcons.trash2,
                  onTap: !_saving && widget.onSave != null
                      ? () => _save(delete: true)
                      : null,
                ),
                const SizedBox(height: S.x3),
                Text(
                  l?.alarmDeleteEntryHint(
                        _repeatLabel(
                          c,
                          widget.original.map((d) => d.weekday).toSet(),
                        ),
                      ) ??
                      'Removes the saved alarm for ${_repeatLabel(c, widget.original.map((d) => d.weekday).toSet())}. Other entries stay unchanged.',
                  style: F.cap.copyWith(color: p.ink3),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _weekdayName(BuildContext c, int day) {
    final l = AppLocalizations.of(c);
    return l == null
        ? const [
            'Monday',
            'Tuesday',
            'Wednesday',
            'Thursday',
            'Friday',
            'Saturday',
            'Sunday',
          ][day]
        : [
            l.homeWeekdayMonday,
            l.homeWeekdayTuesday,
            l.homeWeekdayWednesday,
            l.homeWeekdayThursday,
            l.homeWeekdayFriday,
            l.homeWeekdaySaturday,
            l.homeWeekdaySunday,
          ][day];
  }
}

/// The armed instant and what we know about it. Shared by this screen and
/// Home's door so the two can never disagree. Reading it arms nothing.
(DateTime?, AlarmArmState) alarmArmOf(AppState app) {
  final epoch = app.alarmEpoch;
  if (epoch == null) return (null, AlarmArmState.none);
  return (
    DateTime.fromMillisecondsSinceEpoch(epoch * 1000),
    app.alarmConfirmed
        ? AlarmArmState.confirmed
        : app.alarmPending
        ? AlarmArmState.pending
        : AlarmArmState.unknown,
  );
}

/// Home's door onto the alarm: the next armed day and time plus its state,
/// or "Set an alarm". A plain [detailLinkRow], not a card. An epoch already
/// behind [now] fired or was missed while the link was down (only a live
/// event or the next connect clears it), so it says so instead of passing a
/// spent alarm off as the next one.
Widget alarmDoor(
  BuildContext c,
  DateTime? at,
  AlarmArmState state, {
  DateTime? now,
}) {
  final l = AppLocalizations.of(c);
  final String sub;
  if (at == null) {
    sub = l?.alarmSetAnAlarm ?? 'Set an alarm';
  } else {
    final what = at.isAfter(now ?? DateTime.now())
        ? AlarmScreenView._localizedStateLabel(c, state)
        : (l?.alarmInThePast ??
              'In the past — it has already fired or been missed');
    sub = '${AlarmScreenView._dayAndTime(c, at)} · $what';
  }
  return detailLinkRow(
    c,
    LucideIcons.alarmClock,
    l?.alarmNavTitle ?? 'Alarm',
    sub,
    null,
    destination: const AlarmScreen(),
  );
}

class AlarmScreen extends StatelessWidget {
  const AlarmScreen({super.key});

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    final schedule = app.alarmSchedule;
    final (armedAt, state) = alarmArmOf(app);
    return AlarmScreenView(
      armedAt: armedAt,
      state: state,
      firedAt: app.alarmFiredAt,
      connected: app.isConnected,
      schedule: schedule,
      onSaveScheduleEntries: (entries) => app.setAlarmScheduleEntries(
        entries,
        expected: [for (final entry in entries) schedule[entry.weekday]],
      ),
      onTest: app.testAlarmBuzz,
      onCancel: app.disableAlarm,
    );
  }
}

class AlarmScreenView extends StatelessWidget {
  final DateTime? armedAt;
  final AlarmArmState state;
  final bool connected;

  /// When the band last fired the alarm, shown for the rest of that day.
  final DateTime? firedAt;

  /// Injectable clock. "Tomorrow" vs "Later today" is relative, so a golden of
  /// this screen is otherwise a function of when the suite happens to run.
  final DateTime? now;

  /// Always exactly 7 entries in weekday order — see
  /// `fillDefaultAlarmSchedule` in state/alarm_schedule.dart, which is what
  /// [AppState.alarmSchedule] guarantees.
  final List<AlarmScheduleEntry> schedule;

  /// Only explicit Save/Delete actions call this. Entries not included in
  /// the update retain their saved values; the state layer persists the
  /// affected weekdays together and re-arms once.
  final Future<void> Function(List<AlarmScheduleEntry>)? onSaveScheduleEntries;
  final Future<void> Function()? onTest, onCancel;

  const AlarmScreenView({
    super.key,
    this.armedAt,
    this.state = AlarmArmState.none,
    this.connected = false,
    this.firedAt,
    this.now,
    this.schedule = const [],
    this.onSaveScheduleEntries,
    this.onTest,
    this.onCancel,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final at = armedAt;
    final fired = firedAt;
    final anyDayEnabled = schedule.any((d) => d.enabled);
    final groups = _alarmGroups(schedule);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(
                l?.alarmNavTitle ?? 'Alarm',
                sub: l?.alarmNavSub ?? 'Wakes you on the band, not the phone',
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                children: [
                  if (fired != null &&
                      calendarDaysBetween(fired, now ?? DateTime.now()) ==
                          0) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Pill(
                        l?.alarmFiredAt(_hhmm(fired)) ??
                            'Fired at ${_hhmm(fired)}',
                        C.green,
                        icon: LucideIcons.alarmClockCheck,
                      ),
                    ),
                    const SizedBox(height: S.x3),
                  ],
                  if (at != null) ...[
                    Surface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (at.isAfter(now ?? DateTime.now()))
                            Text(
                              l?.alarmNextLabel ?? 'NEXT',
                              style: F.over.copyWith(color: p.ink3),
                            ),
                          const SizedBox(height: S.x1),
                          Text(
                            _dayAndTime(c, at),
                            style: F.n48.copyWith(color: p.ink),
                          ),
                          Text(
                            _whichDay(c, at, now ?? DateTime.now()),
                            style: F.cap.copyWith(color: p.ink2),
                          ),
                          const SizedBox(height: S.x3),
                          Pill(
                            _localizedStateLabel(c, state),
                            _stateColor(state),
                            icon: _stateIcon(state),
                          ),
                        ],
                      ),
                    ),
                    if (_stateDetail(c, state) case final detail?) ...[
                      const SizedBox(height: S.x3),
                      StatusCard(
                        _stateHeadline(c, state),
                        detail,
                        icon: _stateIcon(state),
                      ),
                    ],
                    const SizedBox(height: S.x4),
                  ],
                  if (!connected)
                    StatusCard(
                      l?.alarmNotConnectedTitle ?? 'The band is not connected',
                      l?.alarmNotConnectedBody ??
                          'Changing the schedule, testing and cancelling all '
                              'write to the band, so they need a live '
                              'connection. An alarm that is already armed is '
                              'unaffected — it lives on the band.',
                      icon: LucideIcons.bluetoothOff,
                    )
                  else ...[
                    Text(
                      l?.alarmScheduleGroup ?? 'Weekly schedule',
                      style: F.t2.copyWith(color: p.ink),
                    ),
                    const SizedBox(height: S.x3),
                    for (final group in groups) ...[
                      Surface(
                        semanticLabel:
                            '${_repeatLabel(c, group.map((d) => d.weekday).toSet())}, '
                            '${_hhmmOf(group.first.hour, group.first.minute)}, '
                            '${group.first.enabled ? (l?.stateOn ?? 'On') : (l?.stateOff ?? 'Off')}',
                        onNavigate: (open) => _edit(c, open, group),
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.alarmClock,
                              color: p.on(C.green),
                              size: S.navIcon,
                            ),
                            const SizedBox(width: S.x3),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _hhmmOf(
                                      group.first.hour,
                                      group.first.minute,
                                    ),
                                    style: (bigText(c) ? F.t2 : F.n34).copyWith(
                                      color: p.ink,
                                    ),
                                  ),
                                  const SizedBox(height: S.x1),
                                  Text(
                                    _repeatLabel(
                                      c,
                                      group.map((d) => d.weekday).toSet(),
                                    ),
                                    style: F.cap.copyWith(color: p.ink2),
                                  ),
                                  if (!group.first.enabled)
                                    Text(
                                      l?.stateOff ?? 'Off',
                                      style: F.cap.copyWith(color: p.ink3),
                                    ),
                                ],
                              ),
                            ),
                            Icon(LucideIcons.chevronRight, color: p.ink3),
                          ],
                        ),
                      ),
                      const SizedBox(height: S.x3),
                    ],
                    if (groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: S.x3),
                        child: Text(
                          l?.alarmHeadlineNone ?? 'No alarm is set',
                          style: F.body.copyWith(color: p.ink2),
                        ),
                      ),
                    if (schedule.any(_unusedDay))
                      DetailLink(
                        builder: (open) => BigButton(
                          l?.alarmSetAnAlarm ?? 'Set an alarm',
                          icon: LucideIcons.plus,
                          onTap: () => _edit(c, open, const []),
                        ),
                      ),
                    const SizedBox(height: S.x3),
                    if (at != null) ...[
                      BigButton(
                        l?.alarmTestTheBuzz ?? 'Test the buzz',
                        icon: LucideIcons.vibrate,
                        color: C.blue,
                        soft: true,
                        onTap: () => _run(
                          c,
                          onTest,
                          l?.alarmBuzzingTheBand ?? 'Buzzing the band',
                        ),
                      ),
                      const SizedBox(height: S.x3),
                    ],
                    if (at != null || anyDayEnabled)
                      BigButton(
                        l?.alarmCancelTheAlarm ?? 'Cancel the alarm',
                        icon: LucideIcons.bellOff,
                        color: C.red,
                        soft: true,
                        onTap: () => _run(
                          c,
                          onCancel,
                          l?.alarmCancelled ?? 'Alarm cancelled',
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext c,
    DetailOpener open,
    List<AlarmScheduleEntry> original,
  ) async {
    final result = await open<bool>(
      _AlarmEditor(
        schedule: schedule,
        original: original,
        onSave: onSaveScheduleEntries,
      ),
    );
    if (result == true && c.mounted) {
      _say(
        c,
        AppLocalizations.of(c)?.alarmScheduleSaved ?? 'Wake schedule saved',
      );
    }
  }

  /// Run a band/schedule write and report what happened. Every one of these
  /// throws when the band is not connected, and silence would read as success.
  static Future<void> _run(
    BuildContext c,
    Future<void> Function()? action,
    String ok,
  ) async {
    if (action == null) return;
    try {
      await action();
      if (c.mounted) _say(c, ok);
    } catch (e) {
      if (c.mounted) _say(c, '$e'.replaceFirst('Exception: ', ''));
    }
  }

  static void _say(BuildContext c, String msg) =>
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));

  static String _hhmm(DateTime d) => _hhmmOf(d.hour, d.minute);

  static String _hhmmOf(int hour, int minute) => formatClock(hour, minute);

  /// "Tue 07:30" — the weekday plus the time, both from the ARMED instant
  /// (not merely from the schedule row), so this never claims a day the band
  /// hasn't actually latched yet.
  static String _dayAndTime(BuildContext c, DateTime at) =>
      '${weekdayShortName(at.weekday, AppLocalizations.of(c))} ${_hhmm(at)}';

  static String _whichDay(BuildContext c, DateTime d, DateTime now) {
    final l = AppLocalizations.of(c);
    final days = calendarDaysBetween(now, d);
    if (!d.isAfter(now)) {
      return l?.alarmInThePast ??
          'In the past — it has already fired or been missed';
    }
    if (days == 0) return l?.alarmLaterToday ?? 'Later today';
    if (days == 1) return l?.alarmTomorrow ?? 'Tomorrow';
    return l?.alarmInDays(days) ?? 'In $days days';
  }

  // Kept context-free and @visibleForTesting: the arm-state contract this
  // guards ("only `confirmed` may claim it") is tested without a widget tree.
  @visibleForTesting
  static String stateLabel(AlarmArmState s) => switch (s) {
    AlarmArmState.confirmed => 'Confirmed',
    AlarmArmState.pending => 'Waiting',
    AlarmArmState.unknown => 'Not confirmed',
    AlarmArmState.none => 'Not set',
  };

  static String _localizedStateLabel(BuildContext c, AlarmArmState s) {
    final l = AppLocalizations.of(c);
    return switch (s) {
      AlarmArmState.confirmed => l?.alarmStateConfirmed ?? 'Confirmed',
      AlarmArmState.pending => l?.alarmStateWaiting ?? 'Waiting',
      AlarmArmState.unknown => l?.alarmStateNotConfirmed ?? 'Not confirmed',
      AlarmArmState.none => l?.alarmStateNotSet ?? 'Not set',
    };
  }

  static Color _stateColor(AlarmArmState s) => switch (s) {
    AlarmArmState.confirmed => C.green,
    AlarmArmState.pending => C.blue,
    AlarmArmState.unknown => C.orange,
    AlarmArmState.none => C.blue,
  };

  static IconData _stateIcon(AlarmArmState s) => switch (s) {
    AlarmArmState.confirmed => LucideIcons.badgeCheck,
    AlarmArmState.pending => LucideIcons.loader,
    AlarmArmState.unknown => LucideIcons.circleHelp,
    AlarmArmState.none => LucideIcons.alarmClock,
  };

  static String _stateHeadline(BuildContext c, AlarmArmState s) {
    final l = AppLocalizations.of(c);
    return switch (s) {
      AlarmArmState.confirmed =>
        l?.alarmHeadlineConfirmed ?? 'The band has this alarm',
      AlarmArmState.pending =>
        l?.alarmHeadlinePending ?? 'Sent — waiting for the band to confirm',
      AlarmArmState.unknown =>
        l?.alarmHeadlineUnknown ?? 'We cannot tell whether this will fire',
      AlarmArmState.none => l?.alarmHeadlineNone ?? 'No alarm is set',
    };
  }

  static String? _stateDetail(BuildContext c, AlarmArmState s) {
    final l = AppLocalizations.of(c);
    return switch (s) {
      AlarmArmState.confirmed =>
        l?.alarmDetailConfirmed ??
            'The band reported that it latched the alarm.',
      AlarmArmState.pending =>
        l?.alarmDetailPending ??
            'The write reached the band. Its confirmation usually arrives within '
                'a few seconds.',
      AlarmArmState.unknown =>
        l?.alarmDetailUnknown ??
            'The time above is what this app last sent. The band never confirmed '
                'it — or it was set in an earlier run of the app, and there is no '
                'way to ask the band what it is holding. Set it again while '
                'connected if you need to be sure.',
      AlarmArmState.none => null,
    };
  }
}
