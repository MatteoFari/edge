// HOME — decision-oriented. "What matters today?"
//
// Three rings that decide the day — what the night gave back, what the day has
// cost, what the night was made of — three signals worth a glance under them,
// and the small set of things the app can honestly say are worth doing. The
// hard part is not the circles: readiness exists on 71 % of days and needs
// four prior nights before it exists at all, so what a ring does with nothing
// in it is the design. See [RingTrio]. No insight feed and no general
// health-observation card: those are OBSERVATION, and observation lives on
// Health. A home screen that also observes is a dashboard, and a dashboard is
// what this rebuild is replacing.
//
// ONE NAMED EXCEPTION, and it is deliberately not a crack in that rule: the
// illness watch ([_bodyWatch]). It is not a feed and it cannot grow into one —
// exactly one detector may render here, it renders only when its own state is
// amber or red, and it is silent on every ordinary day. The reason it earns
// Home is timing rather than importance: the watch is at its most useful when
// it first goes amber, and amber has no notification, so before this the
// earliest signal the app produces could only be found by opening Health and
// scrolling. A signal that arrives too late to act on is not worth computing.
// If a second observation ever wants this slot, the answer is no — build the
// feed on Health where the others already live.
//
// This file also carries the plumbing every screen in this folder shares —
// navigation, the repo handle, and the three ways a value arrives from the
// data layer. They live here rather than in a fourth file because there are
// only three of them and they are read together.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/ble_state.dart' show BandStatus, BandCondition;
import '../../ble/band_status_l10n.dart' show localizedBandStatus;
import '../../ai/briefing.dart'
    show
        Briefing,
        BriefingPeriod,
        BriefingStore,
        currentBriefingPeriod,
        resolveBriefingToShow;
import '../../data/day_label.dart' show todayLabel, calendarDaysBetween;
import '../../compute/onehz_pipeline.dart'
    show readinessInputShortfallNote, readinessUnstableBaselineNote;
import '../../data/db.dart' show DbRebuild, LocalDb;
import '../../data/journal_fields.dart' show formatMinuteOfDay;
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart';
import '../../notify/notification_prefs.dart' show NotificationPrefs;
import '../../state/alarm_schedule.dart'
    show AlarmScheduleEntry, nextAlarmOccurrence;
import '../../state/app_state.dart';
import '../../state/clock_format.dart' show formatClockOf;
import '../../state/units_controller.dart';
import '../../theme/theme_switcher.dart' show themedRoute;
import '../activity/day_strain.dart' show DayStrainDetail;
import '../profile/alarm.dart'
    show AlarmArmState, AlarmScreen, alarmArmOf, alarmDoor;
import '../profile/devices.dart' show MyDevices, formatDayTime;
import '../profile/profile.dart';
import '../ui2.dart';
import 'ai_briefing.dart' show AiBriefingScreen;
import 'coach.dart';
import 'detected_activities.dart';
import 'metric_detail.dart';
import 'home_metric_preview.dart';
import 'readiness_detail.dart';
import 'sleep_detail.dart';

// ═══════════════════ shared plumbing ═══════════════════

/// Page padding. The bottom inset clears the shell's floating nav.
const pad = EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x16 + S.x8);

/// Push from a plain control. Cards use DetailLink to expand from their surface.
///
/// This was a raw `PageRouteBuilder` with its own fade+slide, which silently
/// killed the iOS edge-swipe-back on all ~20 screens it pushes — a
/// PageRouteBuilder has no interactive back-gesture machinery. The app's own
/// transition is registered in the theme instead (see page_transitions.dart),
/// so a plain route gets the fade-through on Android and the Cupertino slide
/// WITH swipe-back on iOS. [themedRoute] also keeps the pushed screen
/// re-colouring on an appearance change and names the route for Crashlytics.
void go(BuildContext c, Widget w) =>
    Navigator.of(c).push(themedRoute((_) => w, name: w.runtimeType.toString()));

/// The repo, or null when there is no AppState above us — which is the case in
/// every golden. A screen with no repo renders its absent states, which is
/// exactly what we want a golden to capture.
LocalRepository? repoOf(BuildContext c) {
  try {
    return c.read<AppState>().repo;
  } catch (_) {
    return null;
  }
}

/// A briefing stays a readable, working door after its unread emphasis settles.
class _BriefingEntry extends StatelessWidget {
  final bool unread;
  final String title, summary;
  final Future<void> Function(DetailOpener) onNavigate;

  const _BriefingEntry({
    required this.unread,
    required this.title,
    required this.summary,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final color = unread
        ? Color.alphaBlend(p.wash(kCoachAccent), p.card)
        : p.card;
    final newLabel = l?.homeBriefingNew ?? 'New';
    final label = unread
        ? (l?.homeBriefingUnreadLabel(title, summary) ??
              '$title, $newLabel. $summary')
        : (l?.homeBriefingReadLabel(title, summary) ?? '$title. $summary');
    return DetailLink(
      color: color,
      builder: (open) => Pressable(
        key: const ValueKey('home-ai-briefing'),
        semanticLabel: label,
        onTap: () => onNavigate(open),
        child: ExcludeSemantics(
          child: AnimatedContainer(
            key: const ValueKey('home-ai-briefing-surface'),
            duration: motion(c, Motion.slow),
            curve: Motion.effectsCurve(c),
            width: double.infinity,
            padding: const EdgeInsets.all(S.x4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: R.cardOf(c),
              boxShadow: p.el(1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                AnimatedContainer(
                  key: const ValueKey('home-briefing-icon'),
                  duration: motion(c, Motion.slow),
                  curve: Motion.effectsCurve(c),
                  width: S.x12,
                  height: S.x12,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: unread ? p.wash(kCoachAccent) : p.card2,
                    borderRadius: R.rPill,
                  ),
                  child: brandGlyph(kEdgeMarkAsset, size: S.navIcon)(
                    unread ? p.on(kCoachAccent) : p.ink2,
                  ),
                ),
                const SizedBox(width: S.x3),
                Expanded(
                  child: Column(
                    key: const ValueKey('home-briefing-text'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: S.x2,
                        runSpacing: S.x1,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(title, style: F.head.copyWith(color: p.ink)),
                          AnimatedSwitcher(
                            duration: motion(c, Motion.base),
                            switchInCurve: Motion.effectsCurve(c),
                            switchOutCurve: Motion.effectsCurve(c),
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SizeTransition(
                                    sizeFactor: animation,
                                    axis: Axis.horizontal,
                                    axisAlignment: -1,
                                    child: child,
                                  ),
                                ),
                            child: unread
                                ? Pill(
                                    newLabel,
                                    kCoachAccent,
                                    key: const ValueKey('briefing-new'),
                                  )
                                : const SizedBox.shrink(
                                    key: ValueKey('briefing-read'),
                                  ),
                          ),
                        ],
                      ),
                      const SizedBox(height: S.x1),
                      Text(
                        summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: F.cap.copyWith(color: p.ink2, height: 1.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: S.x2),
                Icon(
                  LucideIcons.chevronRight,
                  key: const ValueKey('home-briefing-chevron'),
                  size: S.x5,
                  color: p.ink2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The user's unit system, or null in a golden. A screen that cannot reach it
/// renders what the store holds, which is metric.
UnitsController? unitsOf(BuildContext c) {
  try {
    return c.watch<UnitsController>();
  } catch (_) {
    return null;
  }
}

/// "72.4 kg" → `('72.4', 'kg')`. [UnitsController] owns every conversion and
/// hands back one string; this only puts the two halves in the two slots a
/// row has. Never convert in a screen.
(String, String) splitUnit(String s) {
  final i = s.lastIndexOf(' ');
  return i < 0 ? (s, '') : (s.substring(0, i), s.substring(i + 1));
}

/// The band-sync trigger, or null when there is no AppState above us. Every
/// "Sync the band" CTA in this folder goes through here — a call to action
/// with no action behind it is worse than no call to action.
VoidCallback? syncOf(BuildContext c) {
  try {
    final app = c.read<AppState>();
    return app.syncNow;
  } catch (_) {
    return null;
  }
}

/// Whether the database had to be rebuilt to start this launch, or null in a
/// golden. Same shape as [repoOf] and [syncOf].
DbRebuild? dbRebuildOf(BuildContext c) {
  try {
    return c.read<AppState>().dbRebuild;
  } catch (_) {
    return null;
  }
}

/// The armed alarm and its state, or null when there is no AppState above us
/// (every golden). Read-only: Home never arms or re-arms anything.
(DateTime?, AlarmArmState)? alarmArmOfContext(BuildContext c) {
  try {
    return c.select<AppState, (DateTime?, AlarmArmState)>(alarmArmOf);
  } catch (_) {
    return null;
  }
}

/// Whether a live workout is open, or false in a golden. `select`, not
/// `watch`: AppState ticks at ~1 Hz while a session is live, and this screen
/// only cares about the bool flipping. The bare-day card branches on it — see
/// [workoutHoldCard].
bool workoutLiveOf(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.activeWorkout != null);
  } catch (_) {
    return false;
  }
}

/// Whether the band is actively sending data right now, or false in a
/// golden. Same shape and same reasoning as [workoutLiveOf] — `select`
/// because this only cares about the bool flipping, not AppState's ~1 Hz
/// heartbeat.
bool syncingNowOf(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.syncingNow);
  } catch (_) {
    return false;
  }
}

/// Whether a derive job is running or about to (the backlog just landed and
/// today's numbers are being worked out), or false in a golden.
/// How far the data we hold actually reaches — the band's OWN clock on the
/// newest record BANKED, not when the BLE frame arrived and not when the app
/// last talked to the strap. Null in a golden and before any record exists.
///
/// `select`, like its neighbours: this rebuilds when the data edge moves, not
/// on AppState's ~1 Hz heartbeat.
DateTime? lastDataAtOf(BuildContext c) {
  try {
    return c.select<AppState, DateTime?>((a) => a.lastRecordAt);
  } catch (_) {
    return null;
  }
}

/// "Synced through 11:06" — the one line that answers "how far are we?".
///
/// It reads the BAND's clock, so it says how far the DATA reaches. That is a
/// different number from "last contact" and only this one is the question a
/// sync status has to answer: a connection that transfers nothing is not
/// progress, and a status built on contact time would report it as progress.
///
/// [todayId] is the `YYYY-MM-DD` the screen is ALREADY showing, not
/// `DateTime.now()`. A clock read during `build` decides "is this today?" once
/// and then goes stale — sitting on Home across midnight with no new record,
/// last night's 23:50 would keep rendering as a bare "23:50" and read as
/// tonight. Keying off the rendered day cannot contradict the date line
/// directly above it, whatever the hour. Null (no day on screen yet) ⇒ always
/// dated, which is the honest answer when we do not know what "today" is.
///
/// Bare clock time for the day on screen, the full "Fri 4 Sep, 07:12"
/// otherwise — a lone "07:12" against a strap not worn since Friday is the
/// most misleading thing this line could say.
String syncedThroughLabel(
  DateTime? at,
  String? todayId, [
  AppLocalizations? l,
]) {
  if (at == null) return l?.homeSyncedNever ?? 'No band data yet';
  final today = todayId == null ? null : DateTime.tryParse(todayId);
  final isToday =
      today != null &&
      at.year == today.year &&
      at.month == today.month &&
      at.day == today.day;
  final when = isToday ? formatClockOf(at) : formatDayTime(at, l);
  return l?.homeSyncedThrough(when) ?? 'Synced through $when';
}

/// The band's battery, straight off the same [DeviceState] devices.dart
/// already reads (`app.device.batteryPct`/`.charging`) — never a second poll.
/// Null when unpaired or the strap hasn't reported a level yet, which this
/// deliberately renders as nothing rather than a placeholder.
(double, bool)? deviceBatteryOf(BuildContext c) {
  try {
    return c.select<AppState, (double, bool)?>((a) {
      final pct = a.device.batteryPct;
      final charging = a.device.charging;
      // Both or neither — a known level with an unknown charging state must
      // not fall back to `false`, which would draw a plain (or worse, red)
      // icon over a charging state we simply haven't heard yet.
      return (pct == null || charging == null) ? null : (pct, charging);
    });
  } catch (_) {
    return null;
  }
}

/// Draining, not charging, at or under the same default the low-battery
/// notification uses ([NotificationPrefs.batteryPctDefault]) — this reads the
/// shared constant rather than the user's live pref, since a color hint on
/// Home is not worth an async prefs read on every build.
bool lowBattery(double pct, bool charging) =>
    // Strict `<`, matching device_alerts.dart's own `fireLow` comparison —
    // the color hint should agree with the alert at the boundary, not just
    // near it.
    !charging && pct < NotificationPrefs.batteryPctDefault;

/// "78%" with a battery glyph, next to the sync line — the one place that
/// already used a battery icon as an unrelated recovery-ring metaphor, but
/// this is the actual reading. Mirrors devices.dart's `SourceRow` battery
/// chip (same icon swap, same 13px size) rather than inventing a new look.
Widget? batteryLine(BuildContext c) {
  final battery = deviceBatteryOf(c);
  if (battery == null) return null;
  final (pct, charging) = battery;
  final p = P.of(c);
  final color = lowBattery(pct, charging) ? p.on(C.red) : p.ink3;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        charging ? LucideIcons.batteryCharging : LucideIcons.battery,
        size: 13,
        color: color,
      ),
      const SizedBox(width: 3),
      Text('${pct.round()}%', style: F.cap.copyWith(color: color)),
    ],
  );
}

/// The status line as Home renders it, so the loading / failed / bare paths
/// show it too. It answers "how far are we?", and the moment that question is
/// loudest is the one where there is no day to show.
Widget syncedThroughLine(
  BuildContext c,
  String? todayId, [
  AppLocalizations? l,
]) {
  return Text(
    syncedThroughLabel(lastDataAtOf(c), todayId, l),
    style: F.cap.copyWith(color: P.of(c).ink3),
  );
}

bool derivingOf(BuildContext c) {
  try {
    return c.select<AppState, bool>((a) => a.deriving || a.derivePending);
  } catch (_) {
    return false;
  }
}

/// Read a metric envelope. `_scalarMetric` writes the literal string `'—'` for
/// an absent value, so this must never be replaced by `map['value'] as num`.
Metric metricOf(Object? raw) => Metric.parse(raw);

/// WHICH SENSOR counted the steps, in the two words a card has room for — or
/// null when nothing counted (and on days derived before the ladder existed,
/// whose envelopes name no sensor).
///
/// Read off `inputs_used`, which names the sensor rather than the table the
/// count was stored in. The strap's 100 Hz pedometer and its on-chip counter
/// are BOTH "Strap" here: they are genuinely different measurements, but that
/// difference is a density-3 fact and it is spelled out on Nerd stats. What
/// this must never blur is strap versus phone — a card that lets the phone's
/// count read as the wrist's, or the other way round, defeats the whole point
/// of resolving the day per window.
String? stepSensorLabel(Metric m, [AppLocalizations? l]) {
  final used = m.inputsUsed;
  final strap =
      used.contains('band_pedometer_100hz') ||
      used.contains('band_step_counter');
  final phone = used.contains('phone_pedometer');
  if (strap && phone) return l?.homeStepSensorStrapPhone ?? 'Strap + phone';
  if (strap) return l?.homeStepSensorStrap ?? 'Strap';
  if (phone) return l?.homeStepSensorPhone ?? 'Phone';
  return null;
}

/// The inner object of an envelope whose `value` is a MAP, not a number —
/// every cross-day metric is one of these (`regularity.value.sri`,
/// `sleep_coach.need.value.need_sec`). `Metric.parse` reads those as absent,
/// because a map is not a num, so the object has to come out by hand.
Map<String, dynamic>? envValue(Object? raw) {
  if (raw is! Map) return null;
  final v = raw['value'];
  return v is Map ? v.cast<String, dynamic>() : null;
}

/// The night the overnight block in a `getToday()` result actually came from,
/// when that is NOT today's — otherwise null.
///
/// `getToday` holds the last scored night over until today's settles, which is
/// every morning before the first sync and the whole of any gap after one.
/// Readiness, sleep, resting HR, HRV and skin temperature then all describe
/// that night while steps and active energy describe today.
///
/// WHAT THIS IS STILL FOR, now that no screen prints its numbers as today's
/// (see [overnightMetric]): naming WHICH NIGHT, and opening it. A screen that
/// is explicitly about a dated night — Sleep, with a day stepper over it —
/// wants this, because the night it should open is the last one that scored,
/// not a calendar day with no sleep in it. Every screen resolves that night
/// HERE so Home, Readiness, Sleep and Health cannot each answer "which night?"
/// differently.
String? heldOverNightOf(Map<String, dynamic> today) {
  final st = today['status'];
  if (st is! Map) return null;
  return st['showing_prior_overnight'] == true
      ? st['overnight_day']?.toString()
      : null;
}

/// Why today has no overnight figures, or null when it has its own.
///
/// Two absences that are not interchangeable, both read straight off
/// `status.overnight_state`:
///
///   * `building` — today's records HAVE reached the app and the night has not
///     finished being worked out. It resolves on its own and there is nothing
///     to ask anyone to do.
///   * anything else — nothing from last night has arrived. Syncing is the
///     thing that changes it.
///
/// Prose, not a `key:arg` token, so `whyFromNote` passes it through as the
/// sentence it already is.
String? staleOvernightNote(Map<String, dynamic> today, [AppLocalizations? l]) {
  if (heldOverNightOf(today) == null) return null;
  final st = today['status'];
  return (st is Map ? st['overnight_state']?.toString() : null) == 'building'
      ? l?.homeOvernightBuilding ?? 'Last night is still being worked out.'
      : l?.homeOvernightNothingYet ??
            'Nothing from last night has reached the app yet.';
}

/// An overnight envelope, REFUSED when the night behind it is not today's.
///
/// This reverses a decision that was made deliberately and was wrong on a
/// phone. `getToday` serves the last scored night whenever today's has not
/// settled, and the old argument for printing it was that the number is real
/// and the most recent one there is, so naming its night is enough. It is not:
/// a figure in the today slot is read as today's before anything under it is,
/// so a morning the strap was never worn showed last week's sleep as this
/// morning's, and the caption saying otherwise sat below three rings nobody
/// reads past. A stale number is a worse answer than an honest gap.
///
/// So the numbers stop here and the reason travels in their place. The night
/// itself is not lost — [heldOverNightOf] still names it, and the screens that
/// are ABOUT a dated night still open it.
Metric overnightMetric(
  Map<String, dynamic> today,
  Object? raw, [
  AppLocalizations? l,
]) {
  final why = staleOvernightNote(today, l);
  return why == null ? metricOf(raw) : Metric(note: why);
}

/// A scalar lifted out of an object-valued envelope, wearing that envelope's
/// honesty (tier, confidence, note) so `StatusCard.forMetric` still works on
/// it.
Metric envMetric(Object? raw, num? scalar, {String? unit}) {
  final m = raw is Map
      ? raw.cast<String, dynamic>()
      : const <String, dynamic>{};
  final env = Metric.parse({...m, 'value': scalar});
  return scalar == null && env.note == null
      ? Metric(unit: unit, note: m['note']?.toString())
      : Metric(
          value: scalar,
          unit: unit ?? env.unit,
          confidence: env.confidence,
          tier: env.tier,
          inputsUsed: env.inputsUsed,
          note: env.note,
        );
}

/// One stored chart point: `t` is the epoch SECONDS `getChart` stamps on it
/// (local noon of the day the value was derived on), `v` the value.
typedef ChartPoint = ({int t, double v});

/// A `[{t, v}]` point list from `getChart`, timestamps INTACT.
///
/// [seriesOf] drops `t`, and everything downstream then labelled its x axis off
/// the ARRAY INDEX — `'Today'`, `'N days ago'`, weekday letters. `metric_series`
/// stores one row per DERIVED day, not one per calendar day, so after a sync gap
/// the newest stored point is days old and was still being called "Today".
/// Anything that draws a dated axis reads this.
List<ChartPoint> pointsOf(Object? chart) {
  final pts = chart is Map ? chart['points'] : null;
  if (pts is! List) return const [];
  return [
    for (final e in pts)
      if (e is Map && e['v'] is num && e['t'] is num)
        (t: (e['t'] as num).round(), v: (e['v'] as num).toDouble()),
  ];
}

/// The bare values of a point list, for statistics — a mean, a last reading,
/// an [AxisSpec]. NEVER for a painter: a compacted list is the bug, because it
/// lets 22 stored days masquerade as 30 continuous ones.
List<double> valuesOf(List<ChartPoint> pts) => [for (final p in pts) p.v];

/// [pts] laid out DENSE: one slot per calendar day, [days] slots long, ending
/// today. A day `metric_series` has no row for is `null`, which the painter
/// draws as a break rather than joining across.
///
/// This is the shape every chart in this app takes. `metric_series` gets a row
/// only on a day that derives, so the stored list is already compacted: after a
/// four-day sync gap the newest point sat at the right-hand edge under the
/// label "Today", and the line ran straight through the missing week as though
/// it had been measured.
List<double?> denseDays(List<ChartPoint> pts, int days, {DateTime? end}) {
  final out = List<double?>.filled(days, null);
  for (final p in pts) {
    final behind = end == null
        ? daysBehind(p.t)
        : calendarDaysBetween(
            DateTime.fromMillisecondsSinceEpoch(p.t * 1000),
            end,
          );
    if (behind == null || behind < 0 || behind >= days) continue;
    out[days - 1 - behind] = p.v;
  }
  return out;
}

/// A `[{t, v}]` point list from `getChart` as a plain series.
///
/// Values only — the caller cannot tell WHEN any of them was recorded. Use
/// [pointsOf] for anything that labels, spans or dates the series; this is for
/// sparklines, which claim nothing about time.
List<double> seriesOf(Object? chart) => valuesOf(pointsOf(chart));

/// An x-axis label for a stored point: [todayWord] when the point really is
/// today's, otherwise "N days ago" counted from the point's OWN date.
///
/// The same vocabulary the axes already spoke. What changed is where N comes
/// from: it used to be the point's position in the array, and `metric_series`
/// holds one row per DERIVED day, so a thirty-point series can span two months
/// and both its edges were labelled as though it spanned thirty days.
String axisDay(
  int? epochSec, {
  String todayWord = 'Today',
  String unitWord = 'days',
  AppLocalizations? l,
}) {
  final behind = daysBehind(epochSec);
  if (behind == null) return '';
  if (l != null) {
    return behind <= 0
        ? l.metricDetailToday
        : l.metricDetailDaysAgoLabel(behind);
  }
  if (behind <= 0) return todayWord;
  return '$behind $unitWord ago';
}

/// Whole calendar days between a stored point and today, or null when there is
/// no point. Anything above zero means the number drawn is not today's, and a
/// card that presents it as today's has to say so.
int? daysBehind(int? epochSec, {DateTime? end}) {
  if (epochSec == null) return null;
  return calendarDaysBetween(
    DateTime.fromMillisecondsSinceEpoch(epochSec * 1000),
    end ?? DateTime.now(),
  );
}

/// The withheld-rollup reason inside a `getInsights()` result, or null when the
/// result is real (or simply empty).
Map<String, dynamic>? staleReasonOf(Map<String, dynamic> insights) =>
    insights['stale'] is Map
    ? (insights['stale'] as Map).cast<String, dynamic>()
    : null;

/// The cross-day rollup was WITHHELD: `getInsights` returned the reason it
/// refused instead of the numbers (`LocalRepositoryImpl.crossDayStaleReason`).
///
/// Every screen that reads the rollup renders this rather than quietly showing
/// nothing — "you have no drivers yet" and "we have drivers we will not stand
/// behind" are different states, and the cold-start copy is a wrong answer to
/// the second one.
/// The database could not be opened on this launch and was rebuilt.
///
/// This is the loudest thing this screen can say, and it should be: the old
/// file is parked on disk and only what `salvaged` lists came back. A rebuild
/// the user never hears about is indistinguishable from their data quietly
/// vanishing — which is the one thing a local-first app must never do.
///
/// The counts are stated per table rather than summed. "1,204 rows recovered"
/// reads as reassurance; "nutrition 0" is the sentence that actually tells
/// someone their food log is gone.
StatusCard? dbRebuiltCard(DbRebuild? r, [AppLocalizations? l]) {
  if (r == null) return null;
  final saved = r.salvaged.entries.where((e) => e.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final lost = r.salvaged.entries.where((e) => e.value == 0).toList();
  final savedList = saved
      .map((e) => '${e.key} ${thousands(e.value)}')
      .join(' · ');
  final lostList = lost.map((e) => e.key).join(' · ');
  return StatusCard(
    l?.homeDbRebuiltTitle ?? 'Your database was rebuilt to start the app',
    '${r.cause}\n\n'
    '${saved.isEmpty ? (l?.homeDbRebuiltNothingRecovered ?? 'Nothing could be read back.') : (l?.homeDbRebuiltRecovered(savedList) ?? 'Recovered: $savedList.')}'
    '${lost.isEmpty ? '' : ' ${l?.homeDbRebuiltEmpty(lostList) ?? 'Empty: $lostList.'}'}'
    '\n\n${l?.homeDbRebuiltKept(r.quarantinePath) ?? 'The original file is kept at ${r.quarantinePath} — nothing was deleted.'}',
    icon: LucideIcons.databaseBackup,
  );
}

/// The bare day during a live workout — missing COMPUTE, not data. A live
/// session holds derivation (`DeriveScheduler.setWorkoutActive`), so nothing
/// lands in `day_result` until it ends: the band keeps recording, the sync
/// keeps landing records, and "Sync the band" is a false answer — the sync
/// completes and changes nothing on this screen. The true remedy is finishing
/// the session, and its bar is pinned right below this card, so the card
/// points there rather than duplicating the door.
StatusCard workoutHoldCard([AppLocalizations? l]) => StatusCard(
  l?.homeWorkoutHoldTitle ?? 'A workout is still running',
  l?.homeWorkoutHoldBody ??
      'Today is on hold while a workout is live: the band keeps recording, '
          'but the numbers are computed once the session ends. Finish the workout '
          'from the bar below and today fills in — syncing will not.',
  icon: LucideIcons.timer,
);

StatusCard? staleInsightsCard(
  Map<String, dynamic>? reason,
  VoidCallback? onSync, [
  AppLocalizations? l,
]) {
  final s = reason;
  if (s == null) return null;
  final built = s['built_for_day']?.toString();
  return StatusCard(
    l?.homeInsightsRebuildingTitle ??
        'Your cross-day insights are being rebuilt',
    switch (s['kind']) {
      'algo_version' =>
        l?.homeInsightsRebuildingAlgoVersion ??
            'How these are computed changed with the last update.',
      'stale' =>
        built == null || built.isEmpty
            ? (l?.homeInsightsStaleOverWeek ??
                  'The last rollup was built over a week ago, which is too old to stand behind.')
            : (l?.homeInsightsStaleOnDay(prettyDay(built, l)) ??
                  'The last rollup was built on ${prettyDay(built, l)}, which is too old to stand behind.'),
      _ =>
        l?.homeInsightsNoVersionStamp ??
            'The stored rollup carries no version stamp.',
    },
    fix: onSync == null ? '' : (l?.homeSyncBand ?? 'Sync the band'),
    icon: LucideIcons.refreshCw,
    onFix: onSync,
  );
}

// ── formatting ──

String hm(num? minutes) {
  if (minutes == null) return '';
  final m = minutes.round();
  return m < 60
      ? '${m}m'
      : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

String thousands(num? v) {
  if (v == null) return '';
  final s = v.round().abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// A metric value at the precision its unit actually carries.
///
/// ONE rule, so the same reading is not `71.6` on the detail screen and `72`
/// on the card that links to it. A tenth of a bpm on a nocturnal minimum — or
/// of a millisecond on beat timing recovered from 1 Hz records — is precision
/// the measurement does not have, and a number printing more digits than it
/// knows reads as a more careful measurement than it is. Unitless scores keep
/// a decimal only while they are small enough for one to mean something.
String metricValue(String unit, num? value, [AppLocalizations? l]) {
  final text = _metricValue(unit, value);
  if (l?.localeName != 'it' || unit == 'min') return text;
  if (unit == 'steps' || unit == 'kcal') {
    return value == null ? '' : displayNumber(value.round(), l);
  }
  return text.replaceAll('.', ',');
}

String _metricValue(String unit, num? value) {
  if (value == null) return '';
  final v = value.toDouble();
  switch (unit) {
    case 'min':
      return hm(v);
    case 'steps':
    case 'kcal':
      return thousands(v);
    case 'bpm':
    case 'ms':
    case '%':
      return v.round().toString();
    case 'br/min':
    case '°':
      return v.toStringAsFixed(1);
  }
  if (v.abs() >= 100) return v.round().toString();
  if (v.abs() >= 10) return v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
  return v.toStringAsFixed(1);
}

/// The unit to print BESIDE [metricValue]'s output, which is empty when the
/// format already carries it: `metricValue('min', 443)` is "7h 23m", and a
/// `min` label next to that reads "7h 23m min".
String unitBeside(String unit) => unit == 'min' ? '' : unit;

/// Minute-of-day → "10:40 PM".
///
/// ONE clock format in the app. This used to render 24-hour while Wellness
/// rendered the same field 12-hour, so a target bedtime read `22:40` on Home
/// and `10:40 PM` two screens away. Both now go through the journal layer's
/// [formatMinuteOfDay], which follows the user's 12/24-hour choice
/// (`state/clock_format.dart`).
String clock(num? minOfDay) =>
    minOfDay == null ? '' : formatMinuteOfDay(minOfDay.round());

/// Epoch seconds → "11:08 PM" / "23:08" in the device zone.
String clockOfTs(num? ts) {
  if (ts == null) return '';
  return formatClockOf(DateTime.fromMillisecondsSinceEpoch(ts.round() * 1000));
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String monthName(int month, AppLocalizations? l) {
  if (l == null) return _months[month - 1];
  return [
    l.homeMonthJanuary,
    l.homeMonthFebruary,
    l.homeMonthMarch,
    l.homeMonthApril,
    l.homeMonthMay,
    l.homeMonthJune,
    l.homeMonthJuly,
    l.homeMonthAugust,
    l.homeMonthSeptember,
    l.homeMonthOctober,
    l.homeMonthNovember,
    l.homeMonthDecember,
  ][month - 1];
}

const _monthsShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Abbreviated month for "Thu 4 Sep" date chips.
String monthShortName(int month, AppLocalizations? l) {
  if (l == null) return _monthsShort[month - 1];
  return [
    l.homeMonthJanuaryShort,
    l.homeMonthFebruaryShort,
    l.homeMonthMarchShort,
    l.homeMonthAprilShort,
    l.homeMonthMayShort,
    l.homeMonthJuneShort,
    l.homeMonthJulyShort,
    l.homeMonthAugustShort,
    l.homeMonthSeptemberShort,
    l.homeMonthOctoberShort,
    l.homeMonthNovemberShort,
    l.homeMonthDecemberShort,
  ][month - 1];
}

String _weekdayName(int weekday, AppLocalizations? l) {
  if (l == null) return _weekdays[weekday - 1];
  return [
    l.homeWeekdayMonday,
    l.homeWeekdayTuesday,
    l.homeWeekdayWednesday,
    l.homeWeekdayThursday,
    l.homeWeekdayFriday,
    l.homeWeekdaySaturday,
    l.homeWeekdaySunday,
  ][weekday - 1];
}

const _weekdaysShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Abbreviated weekday for `DateTime.weekday` (1 = Monday), e.g. "Thu 4 Sep"
/// date chips. Reuses the `wellness*` short-day keys — they're already
/// translated everywhere and mean the same three letters here.
String weekdayShortName(int weekday, AppLocalizations? l) {
  if (l == null) return _weekdaysShort[weekday - 1];
  return [
    l.wellnessMon,
    l.wellnessTue,
    l.wellnessWed,
    l.wellnessThu,
    l.wellnessFri,
    l.wellnessSat,
    l.wellnessSun,
  ][weekday - 1];
}

/// 'YYYY-MM-DD' → "Saturday, 20 May".
String prettyDay(String? dayId, [AppLocalizations? l]) {
  final d = dayId == null ? null : DateTime.tryParse(dayId);
  if (d == null) return '';
  return '${_weekdayName(d.weekday, l)}, ${d.day} ${monthName(d.month, l)}';
}

/// The readiness band. `readiness_glassbox` carries no label of its own, so the
/// banding is ours and lives in one place — this one.
///
/// [tier] is that same banding in a form the native surfaces can read.
/// `WidgetService.push` publishes it as `readiness_tier` (and [label] as
/// `readiness_band`) so the widget, the Watch and Siri paint it in their own
/// palettes instead of each keeping a private copy of the cut-offs. They did,
/// and a 65 rendered green on the phone, orange on the widget and yellow on
/// the wrist. -1 = not scored.
///
/// THE CUT-OFFS ARE THE SCORE'S OWN QUANTILES, NOT ROUND NUMBERS (issue #250).
/// `readinessComposite` is `100 / (1 + exp(-z̄))` with no scale parameter, and
/// z̄ is a weight-renormalised mean of per-input robust z's — each ~N(0,1)
/// against that person's OWN baseline. So the score is a percentile of self
/// whose CENTRE IS 50 BY CONSTRUCTION: a night exactly at personal median
/// scores 50, and the old 40/60/80 bands filed that median night under "Take it
/// easy". Roughly a quarter of all nights fell under "Rest today" and 1.7 %
/// could ever reach "Good to go" — it needed every input ~1.4 SD above median
/// at once. A warning that fires on the typical night is not a warning.
///
/// z̄'s own SD is NOT 1: averaging the disclosed weights (.40/.30/.20/.10,
/// renormalised over present inputs) gives σ ≈ 0.55-0.60 if the inputs were
/// independent, ~0.70 at the positive correlation HRV/RHR/RR actually have.
/// σ ≈ 0.65 is the middle of that, and the cut-offs below are its quantiles:
///
///   score = 100 / (1 + exp(-0.65 · Φ⁻¹(p)))
///     p=.05 → 26   p=.20 → 37   p=.75 → 61
///
/// which lands 5 % of nights on "Rest today", 15 % on "Take it easy", 55 % on
/// "Steady" and 25 % on "Good to go". The median night is now the neutral band,
/// which is the whole point. Under the old cut-offs the same distribution read
/// 27 / 47 / 25 / 2.
///
/// σ is the one soft number here — it is a property of how correlated a given
/// person's four inputs are, and it moves with how many of them are present.
/// Re-derive it from a real `metric_series` readiness distribution when there
/// is one long enough to measure; do not nudge the cut-offs by feel.
({String label, Color color, int tier}) readinessBand(
  num? v, [
  AppLocalizations? l,
]) {
  if (v == null) {
    return (
      label: l?.homeReadinessNotScored ?? 'Not scored',
      color: C.n400,
      tier: -1,
    );
  }
  if (v >= 61) {
    return (
      label: l?.homeReadinessGoodToGo ?? 'Good to go',
      color: C.green,
      tier: 3,
    );
  }
  if (v >= 37) {
    return (label: l?.homeReadinessSteady ?? 'Steady', color: C.green, tier: 2);
  }
  if (v >= 26) {
    return (
      label: l?.homeReadinessTakeItEasy ?? 'Take it easy',
      color: C.orange,
      tier: 1,
    );
  }
  return (
    label: l?.homeReadinessRestToday ?? 'Rest today',
    color: C.red,
    tier: 0,
  );
}

/// Glass-box driver keys are the pipeline's own short names.
const driverLabels = {
  'hrv': 'HRV',
  'rhr': 'Resting heart rate',
  'resp': 'Breathing rate',
  'temp': 'Skin temperature',
};

/// A pipeline key the map does not cover is HUMANISED, never printed raw. The
/// glass-box emits whatever inputs the composite used, so a new one used to
/// surface on Home as `resp_rate_slope`.
String driverLabel(Object? key, [AppLocalizations? l]) {
  final k = key?.toString() ?? '';
  final known = switch (k) {
    'hrv' => l?.homeDriverHrv ?? driverLabels['hrv'],
    'rhr' => l?.homeDriverRhr ?? driverLabels['rhr'],
    'resp' => l?.homeDriverResp ?? driverLabels['resp'],
    'temp' => l?.homeDriverTemp ?? driverLabels['temp'],
    _ => null,
  };
  if (known != null) return known;
  if (k.isEmpty) return '';
  final words = k.replaceAll('_', ' ').trim();
  return words.isEmpty ? '' : '${words[0].toUpperCase()}${words.substring(1)}';
}

/// The three rings, and what each one does when its metric is not there.
///
/// A ring is a shape that always renders, and this data frequently is not
/// there: readiness exists on 71 % of days and needs four prior nights before
/// it exists at all. So the absent states ARE the design here rather than an
/// error branch bolted onto three pretty circles. Each ring has four:
///
///   * MEASURED — an arc, the number, and what the number is out of.
///   * CALIBRATING — a muted arc at nights-banked over nights-needed, with the
///     count under it. Visibly progress towards a real ring; an arc at zero
///     would read as a bad score, which is the lie this exists to avoid. It is
///     drawn only for a `need_baseline` note, the one absence that IS progress.
///   * MEASURED, UNSCALED — sleep with no computed need behind it. The number
///     is real and the fraction is not known, so the track draws empty and the
///     line under it says there is no target yet. Filling it against the
///     hardcoded 480 would be inventing the user's sleep need.
///   * ABSENT — the track alone, the absence in words where the number goes,
///     and the PIPELINE'S OWN reason on a row under the trio which is also the
///     door into the screen that can say more. Three [StatusCard]s is not a
///     home screen; a ring with nothing in it and no reason is worse than one.
///
/// Every ring opens something: recovery → [ReadinessDetail], strain →
/// [DayStrainDetail], sleep → [SleepDetail].
class RingTrio extends StatelessWidget {
  final HomeData d;

  /// Push the ring's own screen. Null in a gallery, where there is no navigator
  /// worth pushing onto.
  final void Function(HomeRingKind)? onOpen;
  final Widget Function(HomeRingKind)? detailBuilder;

  final HomeRingKind? expanded;
  final void Function(HomeRingKind)? onExpand;
  final VoidCallback? onClose;
  final String? day;

  const RingTrio({
    super.key,
    required this.d,
    this.onOpen,
    this.expanded,
    this.onExpand,
    this.onClose,
    this.day,
    this.detailBuilder,
  });

  /// Whether ANY of the three has something to draw. When none do, the screen
  /// owes the user one written absence, not three empty circles.
  static bool has(HomeData d) =>
      HomeRingKind.values.any((k) => _ringOf(k, d, null).why == null);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final rings = [for (final k in HomeRingKind.values) _ringOf(k, d, l)];
    if (isExpressive(c)) {
      return _ExpressiveMetrics(
        rings: rings,
        d: d,
        onOpen: onOpen,
        expanded: expanded,
        onExpand: onExpand,
        onClose: onClose,
        day: day,
        detailBuilder: detailBuilder,
      );
    }
    final gaps = rings.where((r) => r.why != null).toList();
    // THERE IS NO "THESE TWO ARE FROM SATURDAY" LINE ANY MORE, and there is
    // nothing left for one to explain. Recovery and sleep used to be served
    // from the last scored night whenever today's had not settled, and this
    // card carried one sentence naming that night. Read on a phone, the
    // sentence lost: a number inside a ring is today's, and a caption under
    // three rings does not undo it. The loader refuses the older night now
    // ([overnightMetric]), so a ring with no night behind it is a gap row with
    // the reason in it — same place every other absence on this screen goes.

    return Surface(
      elevation: 2,
      child: Column(
        children: [
          if (bigText(c))
            // Past ~1.3× a 100 pt column cannot hold the word "Recovery" on one
            // line and there is nowhere for it to wrap to. The ring keeps its
            // size and the type gets the width instead.
            for (var i = 0; i < rings.length; i++) ...[
              if (i > 0) const SizedBox(height: S.x2),
              _RingRow(rings[i], onTap: _open(rings[i].kind)),
            ]
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < rings.length; i++) ...[
                  if (i > 0) const SizedBox(width: S.x3),
                  Expanded(
                    child: _RingColumn(rings[i], onTap: _open(rings[i].kind)),
                  ),
                ],
              ],
            ),
          for (final r in gaps) ...[
            const SizedBox(height: S.x2),
            Divider(color: p.line, height: 1),
            _GapRow(r, onTap: _open(r.kind)),
          ],
          if (d.readiness.value != null && d.drivers.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            Divider(color: p.line, height: 1),
            const SizedBox(height: S.x3),
            Pressable(
              onTap: _open(HomeRingKind.recovery),
              // Top-aligned: at an accessibility size the driver list is three
              // lines and "Why?" was centred against the middle of them.
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l?.homeWhyLabel ?? 'Why?',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                  const SizedBox(width: S.x2),
                  Expanded(
                    child: Text(
                      d.drivers
                          .take(3)
                          .map((e) => driverLabel(e['label'], l))
                          .join(' · '),
                      style: F.cap.copyWith(color: p.ink2),
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, size: 15, color: p.ink3),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  VoidCallback? _open(HomeRingKind k) {
    final f = onOpen;
    return f == null ? null : () => f(k);
  }
}

/// Which ring. The three the app can stand behind on a home screen: what the
/// night gave back, what the day has cost, and what the night was made of.
enum HomeRingKind { recovery, strain, sleep }

/// One ring's resolved state — the only place a metric becomes a shape.
class _RingState {
  final HomeRingKind kind;
  final String label, value, sub;
  final IconData icon;
  final Color color;

  /// What to sweep, 0…1 — null when there is nothing honest to sweep.
  final double? frac;

  /// The arc is calibration progress, not the metric, and is drawn muted.
  final bool calibrating;

  /// Nights banked / nights needed, set only while [calibrating] — the
  /// dashed ring divides itself into exactly [need] beads and fills [have]
  /// of them, rather than approximating that count from [frac].
  final int? have, need;

  /// The absence's reason, as the pipeline gave it. Non-null only when the
  /// ring is [absent].
  final String? why;

  const _RingState(
    this.kind,
    this.label,
    this.icon,
    this.color, {
    required this.value,
    this.sub = '',
    this.frac,
    this.calibrating = false,
    this.have,
    this.need,
    this.why,
  });

  /// A number the ring is actually reporting. Calibration is progress, not a
  /// reading, so it is not one.
  bool get measured => why == null && !calibrating;

  Color arc(P p) => calibrating ? p.ink3 : p.on(color);
  Color ink(P p) => measured ? p.on(color) : p.ink3;

  String get spoken => [
    label,
    measured ? value : value.toLowerCase(),
    if (sub.isNotEmpty) sub,
    ?why,
  ].join('. ');
}

_RingState _ringOf(HomeRingKind k, HomeData d, AppLocalizations? l) {
  switch (k) {
    case HomeRingKind.recovery:
      final v = d.readiness.value;
      final band = readinessBand(v, l);
      return v == null
          ? _gap(
              k,
              l?.homeRingRecovery ?? 'Recovery',
              LucideIcons.batteryCharging,
              C.green,
              d.readiness,
              l?.homeReadinessNotScored ?? 'Not scored',
              l,
              // The same shortfall sentence the Readiness detail screen's
              // banner shows, off the SAME stored diagnostic — _gap's own
              // whyFromNote(m.note, l: l) doesn't recognise the need_inputs:
              // convention this composite uses (only need_baseline:), so
              // without this it fell through to the generic "nothing
              // recorded says why" even with a real, known reason on hand.
              // metricName: 'recovery' — this ring is labelled "Recovery",
              // not "Readiness", and the sentence should say what the ring
              // itself says. The second translator covers the z-cap absence
              // shape readinessInputShortfallNote alone doesn't (PR #510).
              fallbackWhy:
                  readinessInputShortfallNote(
                    d.absentDiag,
                    metricName: 'recovery',
                  ) ??
                  readinessUnstableBaselineNote(
                    d.absentDiag?['note']?.toString(),
                    metricName: 'recovery',
                  ) ??
                  '',
            )
          : _RingState(
              k,
              l?.homeRingRecovery ?? 'Recovery',
              LucideIcons.batteryCharging,
              band.color,
              value: '${v.round()}',
              sub: band.label,
              frac: v / 100,
            );
    case HomeRingKind.strain:
      final v = d.strain.value;
      // 0–21 is the scale's own ceiling, not a target invented here.
      return v == null
          ? _gap(
              k,
              l?.homeRingStrain ?? 'Strain',
              LucideIcons.zap,
              C.purple,
              d.strain,
              l?.homeRingNoStrain ?? 'No strain',
              l,
              unit: 'days',
            )
          : _RingState(
              k,
              l?.homeRingStrain ?? 'Strain',
              LucideIcons.zap,
              C.purple,
              value: displayNumber(v, l, decimals: 1),
              sub: l?.homeStrainOf21 ?? 'of 21',
              frac: v / 21,
            );
    case HomeRingKind.sleep:
      final v = d.sleepMin.value;
      final need = d.sleepNeedMin.value;
      return v == null
          ? _gap(
              k,
              l?.homeRingSleep ?? 'Sleep',
              LucideIcons.moon,
              C.blue,
              d.sleepMin,
              l?.homeRingNoSleep ?? 'No sleep',
              l,
              fallbackWhy:
                  l?.homeSleepGapFallback ??
                  'No night long enough to score was recorded.',
            )
          : _RingState(
              k,
              l?.homeRingSleep ?? 'Sleep',
              LucideIcons.moon,
              C.blue,
              value: hm(v),
              // No computed need means no denominator. The hardcoded 480 in
              // the sleep bundle is not this user's need and must never be
              // shown as one, so the ring stays open and says so.
              sub: need == null
                  ? (l?.homeSleepNoTarget ?? 'No target yet')
                  : (l?.homeOfSpan(hm(need)) ?? 'of ${hm(need)}'),
              frac: need == null || need <= 0 ? null : v / need,
            );
  }
}

/// The absent half: calibrating when the note says the gate is a baseline
/// still filling, otherwise the absence and its reason.
_RingState _gap(
  HomeRingKind k,
  String label,
  IconData icon,
  Color color,
  Metric m,
  String word,
  AppLocalizations? l, {
  String unit = 'nights',
  String fallbackWhy = '',
}) {
  final counts = baselineCountsFromNote(m.note);
  if (counts != null) {
    return _RingState(
      k,
      label,
      icon,
      color,
      value: l?.homeCalibrating ?? 'Calibrating',
      sub: unit == 'days'
          ? (l?.homeCalibratingDays(counts.have, counts.need) ??
                '${counts.have} of ${counts.need} days')
          : (l?.homeCalibratingNights(counts.have, counts.need) ??
                '${counts.have} of ${counts.need} nights'),
      frac: (counts.have / counts.need).clamp(0.0, 1.0),
      calibrating: true,
      have: counts.have,
      need: counts.need,
    );
  }
  return _RingState(
    k,
    label,
    icon,
    color,
    value: word,
    // THE PIPELINE'S REASON FIRST. A sentence written here by someone who
    // never saw the day is the fallback, and where there is neither the ring
    // says it does not know rather than guessing a cause.
    why:
        whyFromNote(m.note, unit: unit, l: l) ??
        (fallbackWhy.isNotEmpty
            ? localizedMetricReason(fallbackWhy, l)!
            : (l?.homeGapNoReason ??
                  'Nothing recorded says why this is missing.')),
  );
}

/// The dial itself. An empty [frac] draws the track and nothing else — which is
/// exactly what [Ring] already does with a zero sweep.
class _Dial extends StatelessWidget {
  final _RingState r;
  final double stroke, icon;

  const _Dial(this.r, {required this.stroke, required this.icon});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Stack(
      alignment: Alignment.center,
      children: [
        CustomPaint(
          size: Size.infinite,
          // Calibrating draws as discrete dashes filling in night by night;
          // a finished (or absent-but-not-calibrating) ring draws the
          // continuous arc, solid only once it is an actual measurement.
          painter: r.calibrating
              // One dash per night the baseline needs, not a fixed count —
              // "6 of 14" draws as 14 divisions with 6 filled.
              ? DashedRing(
                  r.frac ?? 0,
                  r.arc(p),
                  p.track,
                  stroke: stroke,
                  segments: r.need ?? 24,
                )
              : Ring(
                  r.frac ?? 0,
                  r.arc(p),
                  p.track,
                  stroke: stroke,
                  t: animate(c, 1),
                  solid: r.measured,
                ),
        ),
        Icon(r.icon, size: icon, color: r.ink(p)),
      ],
    );
  }
}

/// The default: three across, the number under the ring rather than inside it.
/// Inside is where a duration overflows its own circle at the first
/// accessibility step, and nothing about "7h 45m" gets shorter.
class _RingColumn extends StatelessWidget {
  final _RingState r;
  final VoidCallback? onTap;

  const _RingColumn(this.r, {this.onTap});

  @override
  Widget build(BuildContext c) => Pressable(
    onTap: onTap,
    semanticLabel: r.spoken,
    child: Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 96),
          child: AspectRatio(
            aspectRatio: 1,
            child: _Dial(r, stroke: 7, icon: 20),
          ),
        ),
        const SizedBox(height: S.x3),
        _RingText(r, align: TextAlign.center),
      ],
    ),
  );
}

/// The accessibility layout: ring left, type in the width it needs.
class _RingRow extends StatelessWidget {
  final _RingState r;
  final VoidCallback? onTap;

  const _RingRow(this.r, {this.onTap});

  @override
  Widget build(BuildContext c) => Pressable(
    onTap: onTap,
    semanticLabel: r.spoken,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Row(
        children: [
          SizedBox(width: 56, height: 56, child: _Dial(r, stroke: 5, icon: 15)),
          const SizedBox(width: S.x3),
          Expanded(child: _RingText(r, align: TextAlign.start)),
        ],
      ),
    ),
  );
}

class _RingText extends StatelessWidget {
  final _RingState r;
  final TextAlign align;

  const _RingText(this.r, {required this.align});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final cross = align == TextAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: cross,
      children: [
        Text(
          r.label.toUpperCase(),
          style: F.over.copyWith(color: p.ink3),
          textAlign: align,
        ),
        const SizedBox(height: S.x1),
        // Absent reads as words, never as a dash and never as a zero — so it
        // takes the sentence weight rather than the numeral one.
        Text(
          r.value,
          style: r.measured
              ? F.n24.copyWith(color: p.ink)
              : F.body.copyWith(color: p.ink2),
          textAlign: align,
        ),
        if (r.sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            r.sub,
            style: F.cap.copyWith(color: p.ink3),
            textAlign: align,
          ),
        ],
      ],
    );
  }
}

/// WHY a ring is empty, on the row that also opens the screen which can say
/// more about it. The three parts of a [StatusCard] — what is missing, why,
/// what to do about it — at the size a home screen can afford to spend on an
/// absence.
class _GapRow extends StatelessWidget {
  final _RingState r;
  final VoidCallback? onTap;

  const _GapRow(this.r, {this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(r.icon, size: 15, color: p.ink3),
            const SizedBox(width: S.x2),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${r.label} · ',
                      style: F.cap.copyWith(
                        color: p.ink2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: r.why,
                      style: F.cap.copyWith(color: p.ink3),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: S.x2),
            Icon(LucideIcons.chevronRight, size: 15, color: p.ink3),
          ],
        ),
      ),
    );
  }
}

/// The same resolved states as the original trio, with recovery given the
/// largest space. No metric is recomputed for this presentation.
class _ExpressiveMetrics extends StatefulWidget {
  final List<_RingState> rings;
  final HomeData d;
  final void Function(HomeRingKind)? onOpen, onExpand;
  final HomeRingKind? expanded;
  final VoidCallback? onClose;
  final String? day;
  final Widget Function(HomeRingKind)? detailBuilder;
  const _ExpressiveMetrics({
    required this.rings,
    required this.d,
    this.onOpen,
    this.expanded,
    this.onExpand,
    this.onClose,
    this.day,
    this.detailBuilder,
  });
  @override
  State<_ExpressiveMetrics> createState() => _ExpressiveMetricsState();
}

class _ExpressiveMetricsState extends State<_ExpressiveMetrics>
    with SingleTickerProviderStateMixin {
  final _region = GlobalKey();
  final _expandedSurface = GlobalKey();
  final _cards = {for (final k in HomeRingKind.values) k: GlobalKey()};
  late final _controller =
      AnimationController(vsync: this, duration: Motion.spatial)
        ..addStatusListener((status) {
          if (status == AnimationStatus.dismissed && mounted) {
            setState(() => _visible = null);
          }
        });
  HomeRingKind? _visible;
  Rect? _origin;
  Size? _size;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = motion(context, Motion.spatial);
    if (!Motion.enabled(context) && _visible != null) {
      _controller.value = widget.expanded == null ? 0 : 1;
    }
  }

  @override
  void didUpdateWidget(_ExpressiveMetrics old) {
    super.didUpdateWidget(old);
    if (old.expanded == widget.expanded) return;
    if (widget.expanded == null) {
      _controller.reverse();
      return;
    }
    if (_visible == widget.expanded) {
      _controller.forward();
      return;
    }
    final region = _region.currentContext?.findRenderObject() as RenderBox?;
    final card =
        _cards[widget.expanded]?.currentContext?.findRenderObject()
            as RenderBox?;
    if (region == null || card == null || !region.hasSize || !card.hasSize) {
      return;
    }
    _size = region.size;
    _origin = card.localToGlobal(Offset.zero, ancestor: region) & card.size;
    _visible = widget.expanded;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  VoidCallback? _open(HomeRingKind kind) {
    final open = widget.onExpand ?? widget.onOpen;
    return open == null ? null : () => open(kind);
  }

  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (c, constraints) {
      final p = P.of(c);
      return AnimatedBuilder(
        animation: _controller,
        builder: (c, _) {
          final t = Motion.spatialCurve(
            c,
          ).transform(_controller.value).clamp(0.0, 1.0);
          final visible = _visible;
          final r = visible == null
              ? null
              : widget.rings.firstWhere((r) => r.kind == visible);
          final target = _size == null ? null : Offset.zero & _size!;
          final rect = target == null || _origin == null
              ? null
              : Rect.lerp(_origin, target, t)!;
          return Stack(
            key: _region,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxWidth
                      .clamp(0, S.x16 * 6)
                      .toDouble(),
                ),
                child: IgnorePointer(
                  ignoring: visible != null,
                  child: ExcludeSemantics(
                    excluding: visible != null,
                    child: Opacity(opacity: 1 - t, child: _cardsLayout(c)),
                  ),
                ),
              ),
              if (r != null && rect != null)
                Positioned.fromRect(
                  rect: rect,
                  child: ClipRRect(
                    borderRadius: R.cardOf(c),
                    child: Opacity(
                      opacity: (t * 3).clamp(0.0, 1.0),
                      child: RepaintBoundary(
                        key: _expandedSurface,
                        child: DecoratedBox(
                          key: ValueKey('expanded-${r.kind.name}'),
                          decoration: BoxDecoration(
                            color: p.card,
                            borderRadius: R.cardOf(c),
                            border: Border.all(color: p.line),
                          ),
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: target!.width,
                            maxWidth: target.width,
                            minHeight: target.height,
                            maxHeight: target.height,
                            child: SizedBox.fromSize(
                              size: target.size,
                              child: Padding(
                                padding: const EdgeInsets.all(S.x4),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                r.label,
                                                style: F.cap.copyWith(
                                                  color: p.ink2,
                                                ),
                                              ),
                                              Text(
                                                r.value,
                                                style: r.measured
                                                    ? TextStyle.lerp(
                                                        r.kind ==
                                                                HomeRingKind
                                                                    .recovery
                                                            ? F.n48
                                                            : F.n24,
                                                        F.n34,
                                                        t,
                                                      )!.copyWith(color: p.ink)
                                                    : F.head.copyWith(
                                                        color: p.ink2,
                                                      ),
                                              ),
                                              if (r.sub.isNotEmpty)
                                                Text(
                                                  r.sub,
                                                  style: F.over.copyWith(
                                                    color: p.ink3,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        Pressable(
                                          onTap: widget.onClose,
                                          semanticLabel:
                                              AppLocalizations.of(
                                                c,
                                              )?.homeMetricClose ??
                                              'Close summary',
                                          child: Icon(
                                            LucideIcons.x,
                                            size: S.x5,
                                            color: p.ink2,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: S.x3),
                                    if (bigText(c)) _fullDetails(c, r),
                                    Expanded(
                                      child: Opacity(
                                        opacity: ((t - .5) * 2).clamp(0.0, 1.0),
                                        child: _MetricPreviewBody(
                                          key: ValueKey(
                                            '${r.kind.name}:${widget.day}',
                                          ),
                                          kind: r.kind,
                                          day: widget.day ?? todayLabel(),
                                        ),
                                      ),
                                    ),
                                    if (!bigText(c)) _fullDetails(c, r),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );

  Widget _fullDetails(BuildContext c, _RingState r) {
    final p = P.of(c);
    Widget link(VoidCallback? tap) => Pressable(
      onTap: tap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              AppLocalizations.of(c)?.homeMetricFullDetails ?? 'Full details',
              style: F.cap.copyWith(color: p.on(r.arc(p))),
            ),
          ),
          Icon(LucideIcons.arrowUpRight, size: S.x5, color: p.on(r.arc(p))),
        ],
      ),
    );
    final destination = widget.detailBuilder?.call(r.kind);
    return destination == null
        ? link(widget.onOpen == null ? null : () => widget.onOpen!(r.kind))
        : DetailLink(
            source: _expandedSurface,
            builder: (open) => link(() => open<void>(destination)),
          );
  }

  Widget _cardsLayout(BuildContext c) {
    final recovery = widget.rings.firstWhere(
      (r) => r.kind == HomeRingKind.recovery,
    );
    final sleep = widget.rings.firstWhere((r) => r.kind == HomeRingKind.sleep);
    final strain = widget.rings.firstWhere(
      (r) => r.kind == HomeRingKind.strain,
    );
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Column(
      children: [
        KeyedSubtree(
          key: _cards[recovery.kind],
          child: _ExpressiveRecovery(recovery, onTap: _open(recovery.kind)),
        ),
        const SizedBox(height: S.x3),
        LayoutBuilder(
          builder: (c, box) {
            final sleepCard = KeyedSubtree(
              key: _cards[sleep.kind],
              child: _ExpressiveMetric(sleep, onTap: _open(sleep.kind)),
            );
            final strainCard = KeyedSubtree(
              key: _cards[strain.kind],
              child: _ExpressiveMetric(strain, onTap: _open(strain.kind)),
            );
            // Durations and absence explanations need their full width at narrow
            // sizes and at accessibility text sizes.
            if (bigText(c) || box.maxWidth < 340) {
              return Column(
                children: [
                  sleepCard,
                  const SizedBox(height: S.x3),
                  strainCard,
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: sleepCard),
                  const SizedBox(width: S.x3),
                  Expanded(child: strainCard),
                ],
              ),
            );
          },
        ),
        if (widget.d.readiness.value != null &&
            widget.d.drivers.isNotEmpty) ...[
          const SizedBox(height: S.x2),
          Pressable(
            onTap: _open(HomeRingKind.recovery),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: S.x2,
                vertical: S.x2,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l?.homeWhyLabel ?? 'Why?',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                  const SizedBox(width: S.x2),
                  Expanded(
                    child: Text(
                      widget.d.drivers
                          .take(3)
                          .map((e) => driverLabel(e['label'], l))
                          .join(' · '),
                      style: F.cap.copyWith(color: p.ink2),
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, size: S.x4, color: p.ink3),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MetricPreviewBody extends StatefulWidget {
  final HomeRingKind kind;
  final String day;
  const _MetricPreviewBody({super.key, required this.kind, required this.day});
  @override
  State<_MetricPreviewBody> createState() => _MetricPreviewBodyState();
}

class _MetricPreviewBodyState extends State<_MetricPreviewBody>
    with RevisionReload {
  HomeMetricPreviewData? _data;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  @override
  void reload() => _load();
  Future<void> _load() async {
    final token = beginRead(#preview);
    final repo = repoOf(context);
    setState(() {
      _data = null;
      _failed = false;
    });
    try {
      final data = repo == null
          ? HomeMetricPreviewData(day: widget.day)
          : await HomeMetricPreviewData.load(repo, widget.kind, widget.day);
      if (stillNewest(#preview, token)) setState(() => _data = data);
    } catch (_) {
      if (stillNewest(#preview, token)) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c);
    if (_failed) {
      return SingleChildScrollView(
        child: StatusCard(
          l?.homeMetricLoadFailed ?? 'Could not load this summary',
          '',
          fix: l?.homeMetricRetry ?? 'Retry',
          onFix: _load,
        ),
      );
    }
    if (_data == null) {
      return Center(child: CircularProgressIndicator(color: p.on(C.green)));
    }
    final preview = buildHomeMetricPreview(c, _data!, widget.kind);
    // Recovery fits its chart around the measured readings in this space.
    // The other summaries retain their scrollable detail content.
    return widget.kind == HomeRingKind.recovery
        ? preview
        : SingleChildScrollView(child: preview);
  }
}

class _ExpressiveRecovery extends StatelessWidget {
  final _RingState r;
  final VoidCallback? onTap;

  const _ExpressiveRecovery(this.r, {this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final text = _ExpressiveMetricText(r, hero: true);
    final gauge = SizedBox(
      width: S.x16 + S.x16,
      height: S.x16 + S.x16,
      child: RepaintBoundary(
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size.infinite,
              painter: r.calibrating
                  ? DashedRing(
                      r.frac ?? 0,
                      r.arc(p),
                      p.track,
                      stroke: S.x2,
                      segments: r.need!,
                    )
                  : ExpressiveRecoveryGauge(r.frac, r.arc(p), p.track),
            ),
            Icon(r.icon, size: S.navIcon, color: r.ink(p)),
          ],
        ),
      ),
    );
    return Surface(
      key: const ValueKey('expressive-recovery'),
      elevation: 2,
      onTap: onTap,
      semanticLabel: r.spoken,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (c, box) {
                if (bigText(c) || box.maxWidth < 280) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      text,
                      const SizedBox(height: S.x3),
                      Align(alignment: Alignment.center, child: gauge),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: text),
                    const SizedBox(width: S.x3),
                    gauge,
                  ],
                );
              },
            ),
            if (r.why != null) ...[
              const SizedBox(height: S.x3),
              Text(r.why!, style: F.cap.copyWith(color: p.ink3)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExpressiveMetric extends StatelessWidget {
  final _RingState r;
  final VoidCallback? onTap;

  const _ExpressiveMetric(this.r, {this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final sleep = r.kind == HomeRingKind.sleep;
    return Surface(
      key: ValueKey('expressive-${r.kind.name}'),
      onTap: onTap,
      semanticLabel: r.spoken,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ExpressiveMetricText(r),
            const SizedBox(height: S.x3),
            RepaintBoundary(
              child: SizedBox(
                height: sleep && !r.calibrating ? S.x6 : S.x12,
                width: double.infinity,
                child: CustomPaint(
                  painter: r.calibrating
                      // Calibration is not strain or sleep. Retain the measured
                      // night/day count as a dashed dial, with its own text.
                      ? null
                      : sleep
                      ? ExpressiveSleepMeter(r.frac, r.arc(p), p.track)
                      : ExpressiveStrainSegments(r.frac, r.arc(p), p.track),
                  child: r.calibrating
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: S.x12,
                            height: S.x12,
                            child: CustomPaint(
                              painter: DashedRing(
                                r.frac ?? 0,
                                r.arc(p),
                                p.track,
                                stroke: S.x1,
                                segments: r.need!,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ),
            if (r.why != null) ...[
              const SizedBox(height: S.x3),
              Text(r.why!, style: F.cap.copyWith(color: p.ink3)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExpressiveMetricText extends StatelessWidget {
  final _RingState r;
  final bool hero;

  const _ExpressiveMetricText(this.r, {this.hero = false});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(r.label.toUpperCase(), style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x2),
        Text(
          r.value,
          style: r.measured
              ? (hero ? F.n48 : F.n24).copyWith(color: p.ink)
              : F.head.copyWith(color: p.ink2),
        ),
        if (r.sub.isNotEmpty) ...[
          const SizedBox(height: S.x2),
          Text(r.sub, style: F.cap.copyWith(color: p.ink2)),
        ],
      ],
    );
  }
}

/// Read-only snapshot independent of the derived day. Reading a schedule
/// never arms it, and a computed occurrence cannot inherit an old arm's latch.
({DateTime? at, AlarmArmState state, List<AlarmScheduleEntry> schedule})?
_alarmSnapshotOf(BuildContext c) {
  try {
    return c.select<
      AppState,
      ({DateTime? at, AlarmArmState state, List<AlarmScheduleEntry> schedule})
    >((app) {
      final (at, state) = alarmArmOf(app);
      return (at: at, state: state, schedule: app.alarmSchedule);
    });
  } catch (_) {
    return null;
  }
}

Widget _expressiveAlarmCard(BuildContext c) {
  final snapshot = _alarmSnapshotOf(c);
  final now = DateTime.now();
  final at = snapshot?.at;
  final scheduled = nextAlarmOccurrence(snapshot?.schedule ?? const [], now);
  final display = at ?? scheduled;
  final state = snapshot?.state ?? AlarmArmState.none;
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  final past = at != null && !at.isAfter(now);
  final status = past
      ? (l?.alarmInThePast ??
            'In the past — it has already fired or been missed')
      : switch (at == null ? AlarmArmState.none : state) {
          AlarmArmState.confirmed => l?.alarmStateConfirmed ?? 'Confirmed',
          AlarmArmState.pending => l?.alarmStateWaiting ?? 'Waiting',
          AlarmArmState.unknown => l?.alarmStateNotConfirmed ?? 'Not confirmed',
          AlarmArmState.none => l?.alarmStateNotSet ?? 'Not set',
        };
  final time = display == null
      ? (l?.alarmSetAnAlarm ?? 'Set an alarm')
      : '${weekdayShortName(display.weekday, l)} ${formatClockOf(display)}';
  final title = l?.alarmNavTitle ?? 'Alarm';
  final scheduleLabel = at == null && scheduled != null
      ? (l?.alarmScheduleGroup ?? 'Weekly schedule')
      : null;
  final color = !past && at != null && state == AlarmArmState.confirmed
      ? C.green
      : C.blue;
  return Surface(
    key: const ValueKey('home-next-alarm'),
    destination: const AlarmScreen(),
    semanticLabel:
        '$title. $time. $status'
        '${scheduleLabel == null ? '' : '. $scheduleLabel'}',
    child: ExcludeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            key: const ValueKey('home-alarm-icon'),
            width: S.x12,
            height: S.x12,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.wash(color),
              borderRadius: R.rPill,
            ),
            child: Icon(
              LucideIcons.alarmClock,
              size: S.navIcon,
              color: p.on(color),
            ),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              key: const ValueKey('home-alarm-text'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: F.over.copyWith(color: p.ink3)),
                const SizedBox(height: S.x1),
                Text(time, style: F.head.copyWith(color: p.ink)),
                const SizedBox(height: S.x1),
                Text(status, style: F.cap.copyWith(color: p.ink2)),
                if (scheduleLabel != null) ...[
                  const SizedBox(height: S.x1),
                  Text(scheduleLabel, style: F.cap.copyWith(color: p.ink3)),
                ],
              ],
            ),
          ),
          const SizedBox(width: S.x2),
          Icon(
            LucideIcons.chevronRight,
            key: const ValueKey('home-alarm-chevron'),
            size: S.x5,
            color: p.ink2,
          ),
        ],
      ),
    ),
  );
}

// ═══════════════════ the screen ═══════════════════

class HomeData {
  final String? name;
  final String? dayId;
  final Metric readiness;
  final List<Map<String, dynamic>> drivers;
  final Metric sleepMin, rhr, steps, calories, caloriesTotal;

  /// The day's 0–21 strain, read from the same `getToday` bundle the Workout
  /// tab reads. Nothing on this screen computes it.
  final Metric strain;

  final int stepGoal;
  final Metric sleepNeedMin;
  final Metric bedtime;
  final Map<String, dynamic>? strainTarget;

  /// Non-null when the cross-day rollup was withheld rather than absent — see
  /// [staleInsightsCard]. Drivers, sleep need and bedtime are all empty in that
  /// case, and the screen owes the user the reason.
  final Map<String, dynamic>? insightsStale;

  /// The last night that scored, when that is NOT today's — so the screen can
  /// say WHERE THE DATA STOPS on a day it has nothing of its own.
  ///
  /// It is no longer where readiness, sleep or resting heart rate come from:
  /// [overnightMetric] refuses those at the loader, and this is what is left
  /// of the held-over night once its numbers are gone. Its one job on this
  /// screen is the sentence in the nothing-today card — "the last night this
  /// app scored was Saturday" is a fact about coverage, not a reading dressed
  /// as one.
  final String? heldOverNight;

  /// The illness watch's own state — 'green' / 'amber' / 'red', or null before
  /// it has the 7 nights of baseline it needs. Home renders it only when it is
  /// amber or red; see the exception noted at the top of this file.
  final String? illnessState;

  /// The night the watch is ABOUT, and how far that night sat from this user's
  /// own baseline. `z` belongs to the latest night alone and can be negative
  /// while the run is still up, so the copy says which direction rather than
  /// implying the run reversed.
  final String? illnessDay;
  final double? illnessZ;

  /// `LocalDb.readinessAbsentDiag` off today's bundle — null unless
  /// [readiness] is absent. See `readiness_detail.dart`'s own copy of this
  /// field for why: this card's "not scored" explanation has to be built
  /// from the SAME diagnostic that screen's does, or the two can disagree.
  final Map<String, dynamic>? absentDiag;

  const HomeData({
    this.name,
    this.dayId,
    this.readiness = Metric.empty,
    this.drivers = const [],
    this.sleepMin = Metric.empty,
    this.rhr = Metric.empty,
    this.steps = Metric.empty,
    this.calories = Metric.empty,
    this.caloriesTotal = Metric.empty,
    this.strain = Metric.empty,
    this.stepGoal = kDefaultStepGoal,
    this.sleepNeedMin = Metric.empty,
    this.bedtime = Metric.empty,
    this.strainTarget,
    this.heldOverNight,
    this.illnessState,
    this.illnessDay,
    this.illnessZ,
    this.insightsStale,
    this.absentDiag,
  });

  /// The three illness fields, replaced together. Test-facing sugar, and they
  /// travel as a set on purpose — they are read as one envelope, and setting
  /// one without the others describes a state the pipeline cannot produce.
  HomeData copyOrIllness(String? state, String? day, double? z) => HomeData(
    name: name,
    dayId: dayId,
    readiness: readiness,
    drivers: drivers,
    sleepMin: sleepMin,
    rhr: rhr,
    steps: steps,
    calories: calories,
    caloriesTotal: caloriesTotal,
    strain: strain,
    stepGoal: stepGoal,
    sleepNeedMin: sleepNeedMin,
    bedtime: bedtime,
    strainTarget: strainTarget,
    heldOverNight: heldOverNight,
    illnessState: state,
    illnessDay: day,
    illnessZ: z,
    insightsStale: insightsStale,
    absentDiag: absentDiag,
  );

  /// A day OTHER than today, for the Home day switcher.
  ///
  /// Deliberately thin next to [load]: everything [load] does beyond the six
  /// headline numbers below (frozen-morning-headline pin, the illness watch,
  /// sleep coach need/bedtime, readiness drivers, the stale-rollup notice) is
  /// about the ambiguity of an in-progress "today" — a past day already
  /// settled, so there is nothing there to resolve. Reuses the same
  /// date-parameterized getters the strain/sleep detail screens already read
  /// ([LocalRepository.getDayStrain]/[getDaySleepV2]) plus the one figure
  /// neither carries ([getDayOverview]'s readiness/resting_hr).
  static Future<HomeData> loadForDay(
    LocalRepository repo,
    String date, [
    AppLocalizations? l,
  ]) async {
    final profile = await repo.getProfile();
    final overview = await repo.getDayOverview(date);
    final strain = await repo.getDayStrain(date);
    final sleep = await repo.getDaySleepV2(date);
    var readiness = metricOf(overview['readiness']);
    // Same lookup [load] does for today, for the same reason: the ring's
    // shortfall explanation needs the stored diagnostic, and a day the
    // switcher stepped onto can be absent too, not just today (PR #510).
    final absentDiag = readiness.value != null
        ? null
        : await LocalDb.readinessAbsentDiag(date);
    if (readiness.value == null && readiness.note == null) {
      readiness = Metric(note: absentDiag?['note']?.toString());
    }
    return HomeData(
      name: profile['name']?.toString(),
      dayId: date,
      readiness: readiness,
      absentDiag: absentDiag,
      rhr: metricOf(overview['resting_hr']),
      strain: metricOf(strain['strain']),
      steps: metricOf(strain['steps']),
      calories: metricOf(strain['calories']),
      caloriesTotal: metricOf(strain['calories_total']),
      sleepMin: metricOf(sleep['duration_min']),
      stepGoal: (profile['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal,
    );
  }

  static Future<HomeData> load(
    LocalRepository repo, [
    AppLocalizations? l,
  ]) async {
    final today = await repo.getToday();
    return _loadToday(repo, today, l);
  }

  /// Expressive Home follows the most recent settled main sleep. Midnight
  /// still starts a calendar storage day; it does not clear the waking day
  /// the user is looking at. Explicit date selections bypass this choice.
  static Future<HomeData> loadForWakingDay(
    LocalRepository repo, [
    AppLocalizations? l,
  ]) async {
    final today = await repo.getToday();
    final status = today['status'];
    final current = status is Map
        ? DateTime.tryParse(status['today_day']?.toString() ?? '')
        : null;
    final lastSleep = status is Map
        ? DateTime.tryParse(status['last_sleep_day']?.toString() ?? '')
        : null;
    if (current != null &&
        lastSleep != null &&
        calendarDaysBetween(lastSleep, current) > 0) {
      return loadForDay(repo, status['last_sleep_day'].toString(), l);
    }
    return _loadToday(repo, today, l);
  }

  static Future<HomeData> _loadToday(
    LocalRepository repo,
    Map<String, dynamic> today,
    AppLocalizations? l,
  ) async {
    final cd = await repo.getInsights();
    final profile = await repo.getProfile();

    final daily = today['daily'];
    final sleep = today['sleep'];
    Object? d(String k) => daily is Map ? daily[k] : null;
    Object? s(String k) => sleep is Map ? sleep[k] : null;

    final gb = cd['readiness_glassbox'];
    final gbDrivers = gb is Map ? gb['drivers'] : null;

    final coach = cd['sleep_coach'];
    final needEnv = coach is Map ? coach['need'] : null;
    final bedEnv = coach is Map ? coach['bedtime'] : null;
    final needSec = (envValue(needEnv)?['need_sec'] as num?);

    final strain = today['coach'];

    final heldOver = heldOverNightOf(today);

    // Same envelope Health reads. The watch runs on NOCTURNAL RESTING HEART
    // RATE ALONE — it has never been given a temperature series — so nothing
    // here may imply a second signal.
    final illness = today['illness'];

    // The three that come off the OVERNIGHT block. Gated, so a night that is
    // not today's cannot arrive wearing today's clothes — see
    // [overnightMetric]. Steps, active energy and strain are today's own and
    // are read straight.
    final readiness = overnightMetric(today, d('readiness'), l);
    final absentDiag = readiness.value != null
        ? null
        : await LocalDb.readinessAbsentDiag(
            (today['status'] as Map?)?['today_day']?.toString(),
          );

    return HomeData(
      name: profile['name']?.toString(),
      dayId: (today['status'] as Map?)?['today_day']?.toString(),
      heldOverNight: heldOver,
      illnessState: illness is Map ? illness['state']?.toString() : null,
      illnessDay: illness is Map ? illness['date']?.toString() : null,
      illnessZ: illness is Map ? (illness['z'] as num?)?.toDouble() : null,
      readiness: readiness,
      absentDiag: absentDiag,
      drivers: [
        for (final e in (gbDrivers is List ? gbDrivers : const []))
          if (e is Map) e.cast<String, dynamic>(),
      ],
      strain: metricOf(d('strain')),
      sleepMin: overnightMetric(today, s('duration_min'), l),
      rhr: overnightMetric(today, d('resting_hr'), l),
      steps: metricOf(d('steps')),
      calories: metricOf(d('calories')),
      caloriesTotal: metricOf(d('calories_total')),
      stepGoal: (today['step_goal'] as num?)?.toInt() ?? kDefaultStepGoal,
      // sleep_coach.need is the COMPUTED need. `sleep.need_min` is a hardcoded
      // 480 and must never be shown as "your sleep need".
      sleepNeedMin: envMetric(
        needEnv,
        needSec == null ? null : needSec / 60,
        unit: 'min',
      ),
      bedtime: envMetric(
        bedEnv,
        envValue(bedEnv)?['bedtime_min_of_day'] as num?,
      ),
      strainTarget: strain is Map && strain['strain_target'] is Map
          ? (strain['strain_target'] as Map).cast<String, dynamic>()
          : null,
      insightsStale: staleReasonOf(cd),
    );
  }
}

/// The sync frontier and day picker share the same header on loaded and empty
/// days. A quiet radio is not proof that a backlog has finished transferring.
class ExpressiveHomeHeader extends StatelessWidget {
  final String day;
  final List<String> days;
  final ValueChanged<String> onDay;
  final int refreshRevision;

  const ExpressiveHomeHeader({
    super.key,
    required this.day,
    required this.days,
    required this.onDay,
    this.refreshRevision = 0,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final syncing = syncingNowOf(c);
    var deriving = false;
    try {
      // A queued settle timer is not active processing. The empty-day status
      // still uses derivingOf to explain pending work when no results exist.
      deriving = c.select<AppState, bool>((a) => a.deriving);
    } catch (_) {
      // The gallery has no compute scheduler.
    }
    final at = lastDataAtOf(c);
    String? connection;
    BandStatus? fault;
    try {
      connection = c.select<AppState, String>((a) => a.status);
      final condition = c.select<AppState, BandCondition>(
        (a) => a.engine.bandStatus.condition,
      );
      final status = c.read<AppState>().engine.bandStatus;
      if (status.condition == condition && status.isFault) {
        fault = localizedBandStatus(c, status);
      }
    } catch (_) {
      // The gallery has no band state.
    }
    final connecting =
        connection == 'connecting' ||
        connection == 'reconnecting' ||
        connection == 'scanning';
    final busy = fault == null && (syncing || deriving || connecting);
    final offline =
        !busy &&
        fault == null &&
        connection != null &&
        connection != 'connected';
    final label = fault != null
        ? (l?.homeHeaderSyncIssue ?? 'Sync error')
        : syncing
        ? (l?.devicesSyncing ?? 'Syncing')
        : deriving
        ? (l?.homeHeaderProcessing ?? 'Processing')
        : connecting
        ? (l?.bandStatusConnectingTitle ?? 'Connecting')
        : offline
        ? (l?.homeHeaderOffline ?? 'Offline')
        : null;
    final saved = syncedThroughLabel(at, day, l);
    final complete = !busy && !offline && fault == null && at != null;
    final description = fault != null
        ? '${fault.title}. ${fault.reason}. $saved'
        : label != null
        ? '$label. $saved'
        : complete
        ? '${l?.homeHeaderSyncComplete ?? 'Sync complete'}. $saved'
        : saved;
    final accent = fault != null
        ? C.red
        : syncing || connecting
        ? C.blue
        : deriving
        ? C.purple
        : complete
        ? C.green
        : null;
    final icon = fault != null
        ? LucideIcons.circleAlert
        : busy
        ? LucideIcons.refreshCw
        : offline
        ? LucideIcons.bluetoothOff
        : complete
        ? LucideIcons.check
        : LucideIcons.watch;
    (double?, bool?) battery = (null, null);
    try {
      battery = c.select<AppState, (double?, bool?)>(
        (a) => (a.device.batteryPct, a.device.charging),
      );
    } catch (_) {
      // An unpaired band and the gallery both have an unknown battery.
    }
    final pct = battery.$1;
    final knownBattery = pct != null && pct.isFinite && pct >= 0 && pct <= 100;
    final batteryLabel = knownBattery ? '${pct.round()}%' : '—';
    final batteryAccent = battery.$2 == true
        ? C.green
        : knownBattery && pct < 10
        ? C.red
        : knownBattery && pct < 20
        ? C.yellow
        : null;
    final batteryDescription =
        '${l?.devicesBattery ?? 'Battery'}. '
        '${knownBattery ? batteryLabel : l?.devicesBatteryNotReported ?? 'Not reported since the last connection'}'
        '${battery.$2 == true ? '. ${l?.devicesCharging ?? 'Charging'}' : ''}';
    final date = DateTime.tryParse(day);
    final monthDay = date == null
        ? day
        : '${date.day} ${monthName(date.month, l)}';
    final shortMonthDay = date == null
        ? day
        : '${date.day} ${monthShortName(date.month, l)}';
    final weekday = date == null ? '' : '${_weekdayName(date.weekday, l)}, ';
    final shortWeekday = date == null
        ? ''
        : '${weekdayShortName(date.weekday, l)}, ';
    return Padding(
      padding: const EdgeInsets.only(top: S.x3, bottom: S.x5),
      child: LayoutBuilder(
        builder: (c, box) {
          final dateStyle = F.head.copyWith(color: p.ink);
          final labelStyle = _headerLabelStyle(c);
          double textWidth(String text, TextStyle style) =>
              _headerTextSize(c, text, style).width;
          final arrowWidth = days.isEmpty ? 0.0 : S.x1 + S.x4;
          const actionsWidth = S.tap;
          final gaps = S.x1 * 3;
          final batteryWidth =
              S.tap + S.x3 + textWidth(batteryLabel, labelStyle);
          // Choose date abbreviations against the widest state, so the written
          // month doesn't switch halfway through a sync/processing transition.
          final widestSync =
              [
                    l?.devicesSyncing ?? 'Syncing',
                    l?.homeHeaderProcessing ?? 'Processing',
                    l?.homeHeaderSyncIssue ?? 'Sync error',
                    l?.homeHeaderOffline ?? 'Offline',
                    l?.bandStatusConnectingTitle ?? 'Connecting',
                  ]
                  .map((word) => S.tap + S.x3 + textWidth(word, labelStyle))
                  .reduce((a, b) => a > b ? a : b);
          final remainingDate =
              box.maxWidth -
              widestSync -
              S.tap -
              actionsWidth -
              gaps -
              arrowWidth;
          final shownMonth = textWidth(monthDay, dateStyle) <= remainingDate
              ? monthDay
              : shortMonthDay;
          final dateWidth = textWidth(shownMonth, dateStyle) + arrowWidth;
          // A single row cannot fit arbitrary accessibility text. Keep complete
          // words and full tap targets in a scrollable row instead of clipping or
          // shrinking the user's font. Normal phone sizes never need scrolling.
          final minRowWidth =
              dateWidth +
              actionsWidth +
              gaps +
              (widestSync + S.tap > S.tap + batteryWidth
                  ? widestSync + S.tap
                  : S.tap + batteryWidth);
          final rowWidth = minRowWidth > box.maxWidth
              ? minRowWidth
              : box.maxWidth;
          final quietWeekdaySpace =
              rowWidth - dateWidth - S.tap - batteryWidth - actionsWidth - gaps;
          final shownWeekday =
              textWidth(weekday, dateStyle) <= quietWeekdaySpace
              ? weekday
              : textWidth(shortWeekday, dateStyle) <= quietWeekdaySpace
              ? shortWeekday
              : '';
          return SingleChildScrollView(
            key: const ValueKey('home-header-row-scroll'),
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: rowWidth,
              child: Row(
                key: const ValueKey('home-header-row'),
                children: [
                  Expanded(
                    child: Pressable(
                      key: const ValueKey('home-day-picker'),
                      semanticLabel:
                          l?.metricDetailChooseDayShowing(prettyDay(day, l)) ??
                          'Choose a day. Showing ${prettyDay(day, l)}',
                      onTap: days.isEmpty
                          ? null
                          : () async {
                              final picked = await chooseDay(c, days, day);
                              if (c.mounted &&
                                  picked != null &&
                                  picked != day) {
                                onDay(picked);
                              }
                            },
                      child: Row(
                        children: [
                          Flexible(
                            child: _HomeDayLabel(
                              weekday: shownWeekday,
                              monthDay: shownMonth,
                              compact: label != null,
                              style: dateStyle,
                            ),
                          ),
                          if (days.isNotEmpty) ...[
                            const SizedBox(width: S.x1),
                            Icon(
                              LucideIcons.chevronDown,
                              size: S.x4,
                              color: p.ink3,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: S.x1),
                  _HomeHeaderPill(
                    id: 'sync',
                    complete: complete,
                    refreshRevision: refreshRevision,
                    label: label,
                    description: description,
                    busy: busy,
                    icon: icon,
                    accent: accent,
                  ),
                  const SizedBox(width: S.x1),
                  _HomeHeaderPill(
                    id: 'battery',
                    label: batteryLabel,
                    compact: label != null,
                    description: batteryDescription,
                    icon: battery.$2 == true
                        ? LucideIcons.batteryCharging
                        : knownBattery && pct < 20
                        ? LucideIcons.batteryLow
                        : LucideIcons.battery,
                    accent: batteryAccent,
                  ),
                  const SizedBox(width: S.x1),
                  Pressable(
                    semanticLabel:
                        l?.homeProfileSettings ?? 'Profile and settings',
                    onTap: () => go(c, const ProfileHome()),
                    child: SizedBox(
                      width: S.tap,
                      height: S.tap,
                      child: Center(
                        child: Icon(
                          LucideIcons.settings,
                          key: const ValueKey('home-settings-icon'),
                          size: S.navIcon,
                          color: p.ink2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

TextStyle _headerLabelStyle(BuildContext c) => DefaultTextStyle.of(c).style
    .merge(F.cap.copyWith(fontWeight: FontWeight.w600))
    .copyWith(inherit: false);

Size _headerTextSize(BuildContext c, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(c).style.merge(style),
    ),
    textDirection: Directionality.of(c),
    textScaler: MediaQuery.textScalerOf(c),
    locale: Localizations.localeOf(c),
    maxLines: 1,
  )..layout();
  final size = Size(
    painter.width.ceilToDouble(),
    painter.height.ceilToDouble(),
  );
  painter.dispose();
  return size;
}

/// Keep the month and day on the same surface as the weekday fades away.
class _HomeDayLabel extends StatelessWidget {
  final String weekday, monthDay;
  final bool compact;
  final TextStyle style;

  const _HomeDayLabel({
    required this.weekday,
    required this.monthDay,
    required this.compact,
    required this.style,
  });

  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (c, box) {
      final weekdayWidth = _headerTextSize(c, weekday, style).width;
      final monthWidth = _headerTextSize(c, monthDay, style).width;
      final available = weekdayWidth == 0
          ? 0.0
          : ((box.maxWidth - monthWidth) / weekdayWidth).clamp(0.0, 1.0);
      final expanded = compact ? 0.0 : 1.0;
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: expanded, end: expanded),
        duration: motion(c, Motion.spatial),
        curve: Motion.spatialCurve(c),
        child: Text(
          monthDay,
          key: const ValueKey('home-day-month'),
          style: style,
          maxLines: 1,
          softWrap: false,
        ),
        builder: (c, value, month) {
          final width = value.clamp(0.0, available);
          return Row(
            key: const ValueKey('home-day-label-size'),
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRect(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: width,
                  child: Opacity(
                    opacity: ((width - .45) / .55).clamp(0.0, 1.0),
                    child: Text(
                      weekday,
                      key: const ValueKey('home-day-weekday'),
                      style: style,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ),
              month!,
            ],
          );
        },
      );
    },
  );
}

/// Sync and battery share the same measured surface and motion. Labels are
/// laid out once at full width, then faded in only when the growing pill fits.
class _HomeHeaderPill extends StatefulWidget {
  final String id, description;
  final String? label;
  final bool busy, compact, complete;
  final IconData icon;
  final Color? accent;
  final int refreshRevision;
  const _HomeHeaderPill({
    required this.id,
    required this.description,
    required this.icon,
    this.label,
    this.accent,
    this.busy = false,
    this.compact = false,
    this.complete = false,
    this.refreshRevision = 0,
  });

  @override
  State<_HomeHeaderPill> createState() => _HomeHeaderPillState();
}

class _HomeHeaderPillState extends State<_HomeHeaderPill> {
  Timer? _settleTimer;
  bool _subdued = false;

  @override
  void initState() {
    super.initState();
    _resetSettle();
  }

  @override
  void didUpdateWidget(covariant _HomeHeaderPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.complete != widget.complete ||
        oldWidget.refreshRevision != widget.refreshRevision) {
      _resetSettle();
    }
  }

  void _resetSettle() {
    _settleTimer?.cancel();
    _subdued = false;
    if (widget.complete) {
      _settleTimer = Timer(Motion.statusSettle, () {
        if (mounted && widget.complete) {
          setState(() => _subdued = true);
        }
      });
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final id = widget.id;
    final label = widget.label;
    final description = widget.description;
    final busy = widget.busy;
    final compact = widget.compact;
    final icon = widget.icon;
    final accent = widget.accent;
    final p = P.of(c);
    final accentInk = accent == null ? p.ink3 : p.on(accent);
    final ink = _subdued ? Color.lerp(p.ink3, accentInk, .55)! : accentInk;
    final fill = accent == null
        ? p.card2
        : Color.alphaBlend(
            p.wash(accent, strength: _subdued ? .4 : 1),
            p.card2,
          );
    final diameter = _subdued ? S.x10 - S.x1 : S.tap;
    final style = _headerLabelStyle(c);
    final textSize = _headerTextSize(c, label ?? '', style);
    final width = label == null || compact
        ? diameter
        : S.tap + textSize.width + S.x3;
    final height = label == null || compact
        ? diameter
        : (textSize.height + S.x4).clamp(S.tap, double.infinity).toDouble();
    return Tooltip(
      message: description,
      excludeFromSemantics: true,
      child: Semantics(
        liveRegion: id == 'sync',
        child: Pressable(
          key: ValueKey('home-$id-status'),
          semanticLabel: description,
          onTap: () => go(c, const MyDevices()),
          child: ExcludeSemantics(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(begin: ink, end: ink),
              duration: motion(c, Motion.slow),
              curve: Motion.effectsCurve(c),
              builder: (c, color, _) => TweenAnimationBuilder<Size?>(
                tween: SizeTween(
                  begin: Size(width, height),
                  end: Size(width, height),
                ),
                duration: motion(c, Motion.spatial),
                curve: Motion.spatialCurve(c),
                builder: (c, size, _) {
                  final surfaceWidth = size!.width.clamp(
                    S.x10 - S.x1,
                    double.infinity,
                  );
                  final fits =
                      surfaceWidth >= S.tap + textSize.width + S.x2 &&
                      size.height >= textSize.height + S.x2;
                  return ClipRRect(
                    borderRadius: R.rPill,
                    child: SizedBox(
                      key: ValueKey('home-$id-surface'),
                      width: surfaceWidth,
                      height: size.height.clamp(S.x10 - S.x1, double.infinity),
                      child: AnimatedContainer(
                        key: ValueKey('home-$id-fill'),
                        duration: motion(c, Motion.slow),
                        curve: Motion.effectsCurve(c),
                        decoration: BoxDecoration(
                          color: fill,
                          borderRadius: R.rPill,
                          border: Border.all(color: p.line),
                        ),
                        child: Stack(
                          children: [
                            PositionedDirectional(
                              start: 0,
                              top: 0,
                              bottom: 0,
                              width: surfaceWidth.clamp(0.0, S.tap),
                              child: Center(
                                child: AnimatedSwitcher(
                                  duration: motion(c, Motion.base),
                                  switchInCurve: Motion.effectsCurve(c),
                                  switchOutCurve: Motion.effectsCurve(c),
                                  child: busy && Motion.enabled(c)
                                      ? SizedBox(
                                          key: const ValueKey('sync-spinner'),
                                          width: S.x5,
                                          height: S.x5,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: color,
                                          ),
                                        )
                                      : Icon(
                                          icon,
                                          key: ValueKey(icon),
                                          size: S.x5,
                                          color: color,
                                        ),
                                ),
                              ),
                            ),
                            PositionedDirectional(
                              start: S.tap,
                              top: 0,
                              bottom: 0,
                              width: textSize.width,
                              child: AnimatedOpacity(
                                opacity: label != null && !compact && fits
                                    ? 1
                                    : 0,
                                duration: motion(c, Motion.fast),
                                curve: Motion.effectsCurve(c),
                                child: Center(
                                  child: Text(
                                    label ?? '',
                                    key: ValueKey('home-$id-label'),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: style.copyWith(color: color),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  /// Injected only by goldens; production always loads.
  final HomeData? data;

  /// Hour of day, injected only by goldens. The greeting reads the clock, so a
  /// golden baked in the evening fails the next morning on nothing but the
  /// word "evening" — a test that breaks by being run at a different time is
  /// noise that trains you to regenerate without looking.
  final int? hour;

  /// Whether a workout is live, injected only by tests/goldens — production
  /// reads it off AppState via [workoutLiveOf].
  final bool? workoutLive;

  const HomeScreen({super.key, this.data, this.hour, this.workoutLive});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RevisionReload {
  HomeData? _d;
  HomeRingKind? _expanded;
  final _metricGroup = GlobalKey();
  bool _loading = true;
  int _headerRefreshRevision = 0;

  /// The day requested by the switcher, or null for "today" — the same
  /// null-means-today convention [_load] and [HomeData.load] already used
  /// before there was a switcher.
  String? _day;

  /// `availableDays()` — newest first — for [DayNav]. Refetched with every
  /// load: cheap, and a switcher stepping onto a day that just finished
  /// deriving must see it show up without a relaunch.
  List<String> _days = const [];

  /// The load THREW. Distinct from "there is nothing yet": a decode or a locked
  /// database is a read problem, and telling a user with three months of
  /// history that their band has never produced data is the wrong answer to it.
  bool _failed = false;

  /// Set the moment "Sync the band" is tapped, cleared once real progress has
  /// a signal of its own (`syncingNow`) or after [_tapGrace] with nothing —
  /// the bridge over the gap between the tap and the first record landing,
  /// where neither `busy` (skipped entirely on the common fast-reclaim path)
  /// nor `syncingNow` has moved yet and the button would otherwise look inert.
  bool _syncTapped = false;
  Timer? _syncTapTimer;
  static const _tapGrace = Duration(seconds: 20);

  void _tapSync(VoidCallback sync) {
    sync();
    setState(() => _syncTapped = true);
    _syncTapTimer?.cancel();
    _syncTapTimer = Timer(_tapGrace, () {
      if (mounted) setState(() => _syncTapped = false);
    });
  }

  @override
  void dispose() {
    _syncTapTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!isExpressive(context)) _expanded = null;
  }

  /// Handed its data (golden, gallery) — the screen just renders what it has.
  @override
  bool get revisionReloads => widget.data == null;

  /// Home used to load once post-frame and never listen, so the "Sync the
  /// band" button it renders could not change what the screen showed: the
  /// offload landed, the derive ran, and Home kept saying "Nothing derived
  /// yet" until the app was relaunched.
  @override
  void reload() => _load();

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final t = beginRead(#home);
    try {
      final day = _day;
      final l = AppLocalizations.of(context);
      final expressive = isExpressive(context);
      final d = day == null && expressive
          ? await HomeData.loadForWakingDay(repo, l)
          : day == null || day == todayLabel()
          ? await HomeData.load(repo, l)
          : await HomeData.loadForDay(repo, day, l);
      final days = await repo.availableDays();
      if (mounted && stillNewest(#home, t)) {
        setState(
          () => (_d = d, _days = days, _loading = false, _failed = false),
        );
        final shownDay = day ?? d.dayId;
        if (shownDay != null) {
          CoachEntryScope.maybeOf(context)?.onHomeDay(shownDay);
        }
      }
    } catch (_) {
      if (stillNewest(#home, t)) {
        setState(() => (_loading = false, _failed = true));
      }
    }
  }

  void _expandMetric(HomeRingKind kind) {
    setState(() => _expanded = kind);
    final group = _metricGroup.currentContext;
    if (group != null) {
      // At large text sizes the tapped lower card may have scrolled past the
      // group's header. Keep its Close and Full details controls reachable.
      unawaited(
        Scrollable.ensureVisible(
          group,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ),
      );
    }
  }

  /// Another day. The switcher never strands you off the record — [DayNav]
  /// already restricts the arrows to [_days] — so this just re-loads for it.
  void _goDay(String day) {
    setState(() {
      _day = day;
      _expanded = null;
      _loading = true;
    });
    _load();
  }

  /// The "nothing derived yet" card, upgraded with the one thing it used to
  /// withhold: whether anything is actually happening right now. Tapping Sync
  /// used to leave this card looking identical whether the band was mid-drain
  /// or the tap had silently gone nowhere — "I am not sure if it is actually
  /// syncing or not, no progress, no cue" was exactly that gap. `syncingNow` is
  /// the one signal that is honest across BOTH session paths (a fresh connect
  /// sets `busy`; the common fast-reclaim-from-background path never does), so
  /// it is what ends "connecting", not `busy`. `deriving`/`derivePending` catch
  /// the LAST mile — the backlog landed, `syncingNow` has gone quiet again, but
  /// this screen is still bare because the heavy derive it depends on hasn't
  /// finished. Without that phase the card would flash back to a bare "Nothing
  /// derived yet" for the minute or so a full sleep-stage + spectra pass takes.
  /// The syncing / analyzing / connecting phase card — valid whether or not
  /// [HomeData] itself has loaded yet, which is why it does not take one.
  /// Shared by the fully-bare first-run path (`d == null`) and the
  /// derived-but-empty bare-day path, so a first-run tap of "Sync the band"
  /// gets the same connecting/syncing feedback as every other one. Returns
  /// null when none of the three phases apply, so the caller falls through
  /// to its own "nothing yet" copy.
  Widget? _phaseStatusCard(BuildContext c, AppLocalizations? l) {
    final syncing = syncingNowOf(c);
    final deriving = derivingOf(c);
    // The tap latch is otherwise cleared only by its 20s grace timer — if
    // real progress lands before that timer fires, clear it here too so the
    // UI does not bounce back to "Connecting" once syncing/deriving goes
    // quiet again.
    if ((syncing || deriving) && _syncTapped) {
      _syncTapped = false;
      _syncTapTimer?.cancel();
    }
    final spinner = SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: P.of(c).ink3),
    );

    if (syncing) {
      return StatusCard(
        l?.homeSyncingTitle ?? 'Syncing with your band',
        l?.homeSyncingBody ??
            'Pulling data now — this can take a few minutes '
                'on a full backlog.',
        leading: spinner,
      );
    }
    if (deriving) {
      return StatusCard(
        l?.homeAnalyzingTitle ?? 'Crunching last night\'s numbers',
        l?.homeAnalyzingBody ??
            'The data is in — sleep, recovery and strain '
                'are next.',
        leading: spinner,
      );
    }
    if (_syncTapped) {
      return StatusCard(
        l?.homeConnectingTitle ?? 'Connecting to your band',
        l?.homeConnectingBody ?? 'Hang on — this usually takes a few seconds.',
        leading: spinner,
      );
    }
    return null;
  }

  Widget _bareStatusCard(
    BuildContext c,
    HomeData d,
    AppLocalizations? l, {
    required bool pastDay,
  }) {
    // A PAST day with nothing on it is a settled fact, not a sync problem —
    // "Sync the band" and the derive-phase cards below are both about THIS
    // install's live pipeline catching up, which has nothing to do with a day
    // the switcher stepped back onto.
    if (pastDay) {
      return const StatusCard(
        'No data for this day',
        'Nothing was recorded on this day.',
        fix: '',
        icon: LucideIcons.calendarOff,
      );
    }
    final phase = _phaseStatusCard(c, l);
    if (phase != null) return phase;

    final sync = syncOf(c);
    return StatusCard(
      d.heldOverNight == null
          ? (l?.homeNothingDerivedTitle ?? 'Nothing derived yet')
          : (l?.homeNothingTodayTitle ?? 'Nothing recorded for today'),
      d.heldOverNight == null
          ? (l?.homeNothingDerivedBody ?? 'No band recordings processed yet.')
          : (l?.homeNothingTodayBody(prettyDay(d.heldOverNight, l)) ??
                'The last night this app scored was '
                    '${prettyDay(d.heldOverNight, l)}. Nothing has reached it since.'),
      fix: sync == null ? '' : (l?.homeSyncBand ?? 'Sync the band'),
      icon: LucideIcons.watch,
      onFix: sync == null ? null : () => _tapSync(sync),
    );
  }

  /// Morning / afternoon / evening / night. One split at 18:00 greeted 00:30
  /// and 15:40 alike with "Good morning" beside a sun.
  ({String word, IconData icon, Color color}) _greeting(
    int h,
    AppLocalizations? l,
  ) {
    if (h < 5) {
      return (
        word: l?.homeGreetingStillUp ?? 'Still up',
        icon: LucideIcons.moon,
        color: C.indigo,
      );
    }
    if (h < 12) {
      return (
        word: l?.homeGreetingMorning ?? 'Good morning',
        icon: LucideIcons.sun,
        color: C.yellow,
      );
    }
    if (h < 18) {
      return (
        word: l?.homeGreetingAfternoon ?? 'Good afternoon',
        icon: LucideIcons.sun,
        color: C.orange,
      );
    }
    return (
      word: l?.homeGreetingEvening ?? 'Good evening',
      icon: LucideIcons.moon,
      color: C.indigo,
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final d = _d;
    final expressive = isExpressive(c);
    final g = _greeting(widget.hour ?? DateTime.now().hour, l);
    var showBriefing = true;
    try {
      showBriefing = c.select<AppState, bool>((a) => a.homeAiBriefingEnabled);
    } catch (_) {
      // Standalone gallery previews have no AppState.
    }

    if (d == null) {
      return _refreshable(
        ListView(
          padding: shellScrollPadding(c, pad),
          children: [
            if (expressive)
              ExpressiveHomeHeader(
                day: _day ?? todayLabel(),
                days: _days,
                onDay: _goDay,
                refreshRevision: _headerRefreshRevision,
              )
            else ...[
              const SizedBox(height: S.x8),
              // No day on screen ⇒ no `todayId`, so this renders the dated form.
              // Shown here TOO: a first run, a failed read and a sync in flight are
              // exactly when "how far are we?" is worth answering, and the header
              // this line normally sits under does not exist on this path.
              Align(
                alignment: Alignment.centerLeft,
                child: syncedThroughLine(c, null, l),
              ),
              // The battery reading lives on AppState.device, independent of
              // HomeData — a load failure or first run must not hide it too.
              if (batteryLine(c) case final battery?) ...[
                const SizedBox(height: 2),
                Align(alignment: Alignment.centerLeft, child: battery),
              ],
              const SizedBox(height: S.x3),
            ],
            if (!expressive) const DetectedActivitiesCard(),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_failed)
              StatusCard(
                l?.homeLoadFailedTitle ?? 'Today could not be read',
                l?.homeLoadFailedBody ??
                    'The stored day failed to load. Nothing was deleted — this is a '
                        'read that went wrong, not missing data.',
                fix: l?.homeTryAgain ?? 'Try again',
                icon: LucideIcons.databaseZap,
                onFix: () {
                  setState(() => (_loading = true, _failed = false));
                  _load();
                },
              )
            else
              Builder(
                builder: (c) {
                  final phase = _phaseStatusCard(c, l);
                  if (phase != null) return phase;
                  final sync = syncOf(c);
                  return StatusCard(
                    l?.homeNothingDerivedTitle ?? 'Nothing derived yet',
                    l?.homeNothingDerivedBody ??
                        'No band recordings processed yet.',
                    fix: sync == null
                        ? ''
                        : (l?.homeSyncBand ?? 'Sync the band'),
                    icon: LucideIcons.watch,
                    onFix: sync == null ? null : () => _tapSync(sync),
                  );
                },
              ),
            if (showBriefing) ...[
              const SizedBox(height: S.x3),
              _briefingDoor(c, _day ?? todayLabel()),
            ],
            // The alarm lives on AppState too, so a load failure must not hide it.
            if (_day == null || _day == todayLabel()) ...[
              if (expressive) ...[
                const SizedBox(height: S.x3),
                _expressiveAlarmCard(c),
              ] else if (alarmArmOfContext(c)
                  case final (DateTime?, AlarmArmState) a) ...[
                const SizedBox(height: S.x3),
                alarmDoor(c, a.$1, a.$2),
              ],
            ],
            if (expressive) ...[
              const SizedBox(height: S.x3),
              const DetectedActivitiesCard(),
            ],
          ],
        ),
      );
    }

    // Nothing measured at all. It used to be reachable ONLY by a load throwing
    // — a real first-run user got four stacked absence cards instead of the one
    // card written for this state.
    //
    // It is now also where a day of NO WEAR lands, because the overnight block
    // no longer borrows an older night to fill the rings with. Those are two
    // different days and the copy below splits them on the one fact that tells
    // them apart: whether this install has ever scored a night. "No band
    // recordings processed yet" said to someone with three months of history is
    // the first-run answer to a gap, and it is wrong.
    final bare =
        d.readiness.isEmpty &&
        d.sleepMin.isEmpty &&
        d.strain.isEmpty &&
        d.rhr.isEmpty &&
        d.steps.value == null &&
        d.calories.isEmpty;

    // Whether the switcher is showing today or a day stepped back onto —
    // gates the plan/live-workout copy below, which is about what to DO
    // today and reads as a stale instruction on a day already in the past.
    final shownDay = _day ?? (expressive ? d.dayId : null);
    final detailDay = shownDay == todayLabel() ? null : shownDay;
    final liveHome = _day == null || _day == todayLabel();
    final isToday = liveHome && detailDay == null;
    Widget metricDetail(HomeRingKind kind) => switch (kind) {
      HomeRingKind.recovery => ReadinessDetail(day: detailDay),
      HomeRingKind.strain => DayStrainDetail(day: detailDay),
      HomeRingKind.sleep => SleepDetail(
        day: detailDay,
        includeCurrentPlan: liveHome,
      ),
    };

    final stale = staleInsightsCard(d.insightsStale, syncOf(c), l);
    // Above the header, not below it: if the app had to rebuild the database
    // to start, that outranks anything else this screen has to say today.
    final rebuilt = dbRebuiltCard(dbRebuildOf(c), l);

    return _refreshable(
      ListView(
        padding: shellScrollPadding(c, pad),
        children: [
          if (rebuilt != null) ...[const SizedBox(height: S.x3), rebuilt],

          // ── the one observation Home is allowed to make ──
          //
          // OUTSIDE the derived / not-derived split, and above the rings, for two
          // separate reasons. It outranks them: when this fires it is what matters
          // today, which is the question this screen answers, and under them it
          // would read as a footnote to three numbers. And it does not depend on
          // them — the watch comes off the CROSSDAY rollup, so it can carry a real
          // state on a morning whose own bundle has not derived yet, which is
          // exactly the morning you would most want to be told.
          ...?_bodyWatch(c, d),
          // ── day and sync status ──
          if (expressive)
            ExpressiveHomeHeader(
              day: _day ?? d.dayId ?? todayLabel(),
              days: _days,
              onDay: _goDay,
              refreshRevision: _headerRefreshRevision,
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: S.x3, bottom: S.x5),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                d.name == null || d.name!.isEmpty
                                    ? g.word
                                    : '${g.word}, ${d.name}',
                                style: F.t2.copyWith(color: p.ink),
                              ),
                            ),
                            const SizedBox(width: S.x2),
                            Icon(g.icon, size: 17, color: p.on(g.color)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          prettyDay(d.dayId, l),
                          style: F.cap.copyWith(color: p.ink3),
                        ),
                        // How far the band's data reaches, always — the question "am I
                        // looking at today, or at last night?" used to be answerable
                        // only by opening Profile > Devices.
                        syncedThroughLine(c, d.dayId, l),
                        // Its own line, not squeezed into the sync line's row: at
                        // accessibility text sizes that row has no slack left, and
                        // `Expanded` would only shrink the sync text into extra wrapped
                        // lines to make room rather than ever actually overflow.
                        if (batteryLine(c) case final battery?) ...[
                          const SizedBox(height: 2),
                          battery,
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: S.x3),
                  Pressable(
                    semanticLabel:
                        l?.homeProfileSettings ?? 'Profile and settings',
                    onTap: () => go(c, const ProfileHome()),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.fill(C.domHome),
                      ),
                      child: Icon(
                        LucideIcons.settings,
                        size: 18,
                        color: p.inkOnFill,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          if (bare && !expressive) ...[const DetectedActivitiesCard()],
          if (!expressive) ...dayNavRow(_day ?? d.dayId, _days, _goDay),

          if (bare)
            // A live workout holds derivation, so a bare day with a session open
            // is the hold at work, not a sync problem — see [workoutHoldCard].
            // Only for TODAY: a live workout right now says nothing about why a
            // PAST day the switcher stepped onto has nothing on it.
            isToday && (widget.workoutLive ?? workoutLiveOf(c))
                ? workoutHoldCard(l)
                : _bareStatusCard(c, d, l, pastDay: !isToday)
          else ...[
            // ── the three rings ──
            //
            // Recovery, strain and sleep, each a door into its own screen. They
            // render as long as ONE of them has something to draw — a trio of
            // empty circles says less than the one written absence below, and the
            // empty state is a DOOR, not a dead end. The pipeline records why
            // readiness came back absent on every day it does — which input was
            // missing, how many of your own nights are behind each one — and that
            // diagnostic used to go nowhere but a Firebase breadcrumb. It belongs
            // one tap away, on the Readiness screen: a wall of per-input
            // diagnostics on Home makes the app read as broken.
            if (RingTrio.has(d))
              RingTrio(
                key: _metricGroup,
                d: d,
                expanded: _expanded,
                day: _day ?? d.dayId ?? todayLabel(),
                onExpand: expressive ? _expandMetric : null,
                onClose: () => setState(() => _expanded = null),
                onOpen: (k) => go(c, metricDetail(k)),
                detailBuilder: metricDetail,
              )
            else
              Builder(
                builder: (c) {
                  final need = needMessageFromNote(d.readiness.note, l: l);
                  // readinessInputShortfallNote/readinessUnstableBaselineNote off
                  // d.absentDiag are the SAME functions and the SAME stored
                  // diagnostic readiness_detail.dart's banner uses — not a second,
                  // independently-worded explanation — so this card and the detail
                  // screen can never say two different things about the same
                  // absence.
                  final shortfall = need == null
                      ? readinessInputShortfallNote(d.absentDiag) ??
                            readinessUnstableBaselineNote(
                              d.absentDiag?['note']?.toString(),
                            )
                      : null;
                  return StatusCard(
                    l?.homeReadinessNotScoredTitle ??
                        'Readiness is not scored today',
                    need != null
                        ? (l?.homeReadinessNeedBody(need) ??
                              '$need to know what normal looks like for you.')
                        // Was "Needs a night of beat-to-beat data, plus your own
                        // history to compare it to" — a cause, stated for every
                        // absence the note convention did not cover. The door below
                        // is what actually answers it.
                        : shortfall ??
                              whyFromNote(d.readiness.note, l: l) ??
                              (l?.homeReadinessNoReason ??
                                  'Nothing recorded says why.'),
                    fix: l?.homeSeeWhatWasMissing ?? 'See what was missing',
                    icon: LucideIcons.batteryCharging,
                    destination: ReadinessDetail(day: detailDay),
                  );
                },
              ),

            if (showBriefing) ...[
              const SizedBox(height: S.x3),
              _briefingDoor(c, _day ?? todayLabel()),
            ],

            if (expressive && liveHome) ...[
              const SizedBox(height: S.x3),
              _expressiveAlarmCard(c),
            ],
            const SizedBox(height: S.x3),
            const DetectedActivitiesCard(),
            const CommunityNudge(),

            // ── the rollup was withheld, not absent ──
            if (stale != null) ...[const SizedBox(height: S.x3), stale],

            // ── at a glance ──
            Section(l?.homeAtAGlance ?? 'At a glance', _glance(c, d)),

            // ── today's plan: only what the app can actually stand behind ──
            // Skipped on a past day — "3,000 steps left" or "aim for 11.4
            // strain" about a day already over is an instruction, not a fact.
            if (isToday)
              Section(l?.homeTodaysPlan ?? "Today's plan", _plan(c, p, d)),
          ],

          // ── the next alarm: a door, same as the one above ──
          if (bare && showBriefing) ...[
            const SizedBox(height: S.x3),
            _briefingDoor(c, _day ?? todayLabel()),
          ],
          if (bare && expressive) ...[
            if (liveHome) ...[
              const SizedBox(height: S.x3),
              _expressiveAlarmCard(c),
            ],
            const SizedBox(height: S.x3),
            const DetectedActivitiesCard(),
          ],
          if (liveHome && !expressive)
            if (alarmArmOfContext(c)
                case final (DateTime?, AlarmArmState) a) ...[
              const SizedBox(height: S.x3),
              alarmDoor(c, a.$1, a.$2),
            ],
        ],
      ),
    );
  }

  /// The illness watch, on Home, at amber as well as red.
  ///
  /// Returns null on every ordinary day — green, or no state at all because the
  /// CUSUM has not got its 7 nights yet. Absence here is silence, not a card
  /// explaining that nothing is wrong: "you are not getting sick" is not an
  /// observation worth a slot, and a watch that renders daily stops being read.
  ///
  /// The tap goes to the resting-heart-rate chart rather than Health's copy of
  /// this card, because the chart is the EVIDENCE — the watch reads that one
  /// series, so the honest answer to "why are you telling me this" is to show
  /// it. Health keeps its own fuller card; this is not a duplicate route to the
  /// same words, it is a shorter road to the number underneath them.
  static List<Widget>? _bodyWatch(BuildContext c, HomeData d) {
    final state = d.illnessState;
    if (state == null || state == 'green') return null;
    final l = AppLocalizations.of(c);

    final sameNight = d.illnessDay == null || d.illnessDay == d.dayId;
    final z = d.illnessZ;
    final zAbs = z == null ? '' : z.abs().toStringAsFixed(1);

    return [
      Observation(
        state == 'red'
            ? (l?.homeIllnessRedTitle ??
                  'Several nights in a row are away from your normal')
            : sameNight
            ? (l?.homeIllnessAmberSameNight ??
                  'Last night sat outside your normal range')
            : (l?.homeIllnessAmberOtherNight(prettyDay(d.illnessDay, l)) ??
                  '${prettyDay(d.illnessDay, l)} sat outside your normal range'),
        z == null
            ? (l?.homeIllnessBodyNoZ ??
                  'Your nocturnal resting heart rate has been running above your own '
                      'baseline. This reads one signal. It names a pattern, and it does '
                      'not name a cause.')
            : (z >= 0
                  ? (l?.homeIllnessBodyAbove(zAbs) ??
                        'Your nocturnal resting heart rate has been running above your own '
                            'baseline; that night sat $zAbs standardised deviations above it. '
                            'This reads one signal. It names a pattern, and it does not name '
                            'a cause.')
                  : (l?.homeIllnessBodyBelow(zAbs) ??
                        'Your nocturnal resting heart rate has been running above your own '
                            'baseline; that night sat $zAbs standardised deviations below it. '
                            'This reads one signal. It names a pattern, and it does not name '
                            'a cause.')),
        advice:
            l?.homeIllnessAdvice ??
            'Worth noting if it continues past a couple of days.',
        destination: const MetricDetail('resting_hr'),
      ),
      const SizedBox(height: S.x3),
    ];
  }

  Future<void> _refresh() async {
    if (isExpressive(context)) {
      setState(() => _headerRefreshRevision++);
      syncOf(context)?.call();
    }
    await _load();
  }

  /// Pull to reload. The screen also reloads itself on `insightsRevision`, but
  /// a derive that fails silently, an import, or anything that lands without
  /// bumping it still leaves the user a way to ask.
  Widget _refreshable(Widget list) => PopScope(
    canPop: _expanded == null || !isExpressive(context),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _expanded != null) setState(() => _expanded = null);
    },
    child: NotificationListener<ScrollStartNotification>(
      onNotification: (n) {
        if (_expanded != null &&
            n.depth == 0 &&
            n.dragDetails != null &&
            n.metrics.axis == Axis.vertical) {
          setState(() => _expanded = null);
        }
        return false;
      },
      child: RefreshIndicator(onRefresh: _refresh, child: list),
    ),
  );

  Widget _glance(BuildContext c, HomeData d) {
    final l = AppLocalizations.of(c);
    final cards = <Widget>[];
    final absent = <Widget>[];

    void add(Metric m, Widget Function() card, StatusCard? Function() gap) {
      if (m.isEmpty) {
        final s = gap();
        if (s != null) absent.add(s);
      } else {
        cards.add(card());
      }
    }

    // Resting heart rate comes off the SAME overnight block readiness does,
    // and it used to carry a date on its own line for the mornings that block
    // was held over from an older night. It cannot be an older night any more
    // — the loader refuses those — so every tile in this row is today's and
    // none of them needs a date.

    // Sleep is a RING now, duration and all — the card here was the same
    // number twice on one screen, and the ring is the one that says what the
    // duration was measured against.
    add(
      d.rhr,
      () => SignalCard(
        LucideIcons.heart,
        C.red,
        l?.homeHeartRate ?? 'Heart rate',
        '${d.rhr.value!.round()}',
        unit: 'bpm',
        sub: l?.homeRestingSub ?? 'Resting',
        destination: MetricDetail('resting_hr', day: d.dayId),
      ),
      // "no sleep was recorded" was stated as fact, unconditionally — and it
      // was rendered directly beside a Sleep card showing that night's
      // duration. Sleep duration and nocturnal RHR are gated separately: a
      // night staged from the accelerometer with no clean resting window
      // produces exactly that pair.
      // The else-branch used to name the gate — "no stretch of beats clean
      // enough" — which is one of several reasons a scored night yields no
      // resting rate, picked by a human writing copy. Only the branch the
      // screen can actually see is stated; the other defers to the note, or to
      // saying it does not know.
      () => StatusCard.forMetric(
        l?.homeNoRestingHr ?? 'No resting heart rate',
        d.rhr,
        l: l,
        why: d.sleepMin.isEmpty
            ? (l?.homeNoRestingHrWhy ??
                  'Resting heart rate is read from sleep, and no sleep was recorded.')
            : '',
      ),
    );
    // Steps keeps its tile whether or not a counter reported. Zero steps is a
    // real reading — an unmoved counter — and it renders as 0, not as absence.
    // When nothing counted at all the tile stays and says so in two words,
    // rather than the whole card being replaced by a paragraph about wrist
    // motion: the answer to "how many steps" is short either way.
    cards.add(
      SignalCard(
        LucideIcons.footprints,
        C.green,
        l?.homeSteps ?? 'Steps',
        d.steps.value == null
            ? (l?.homeStepsNone ?? 'None')
            : thousands(d.steps.value),
        // The sensor rides the line that is already there rather than adding a
        // row: the day is resolved per window now, so "8,412" can be the strap's
        // count, the phone's, or both, and the card has to say which. The split
        // behind a mixed day is on Nerd stats, one tap down.
        sub: d.steps.value == null
            ? (l?.homeStepsNotRecorded ?? 'NOT RECORDED')
            : [
                if (d.stepGoal > 0)
                  l?.homeStepsPercentGoal(
                        ((d.steps.value! / d.stepGoal) * 100)
                            .clamp(0, 999)
                            .round(),
                      ) ??
                      '${((d.steps.value! / d.stepGoal) * 100).clamp(0, 999).round()}% of goal',
                ?stepSensorLabel(d.steps, l),
              ].join(' · '),
        destination: MetricDetail('steps', day: d.dayId),
        trailing: d.steps.value == null || d.stepGoal <= 0
            ? null
            : SizedBox(
                width: 20,
                height: 20,
                child: CustomPaint(
                  painter: Ring(
                    d.steps.value! / d.stepGoal,
                    C.green,
                    P.of(c).track,
                    stroke: 3,
                    solid: true,
                  ),
                ),
              ),
      ),
    );
    add(
      d.calories,
      () => SignalCard(
        LucideIcons.flame,
        C.orange,
        l?.homeActiveEnergy ?? 'Active energy',
        thousands(d.calories.value),
        unit: 'kcal',
        sub: d.caloriesTotal.value == null
            ? (l?.homeCaloriesEstimated ?? 'Estimated')
            : (l?.homeCaloriesTotal(thousands(d.caloriesTotal.value)) ??
                  '${thousands(d.caloriesTotal.value)} total'),
        destination: MetricDetail('calories', day: d.dayId),
      ),
      // No `why:`. It said "Needs your weight and age" — and the measured run
      // printed that to a profile carrying both, because energy had gone absent
      // for an entirely different reason that the card never asked for.
      () => StatusCard.forMetric(
        l?.homeNoEnergyEstimate ?? 'No energy estimate',
        d.calories,
        l: l,
      ),
    );

    return Column(
      children: [
        for (var i = 0; i < cards.length; i += 2) ...[
          if (i > 0) const SizedBox(height: S.x3),
          // IntrinsicHeight, because `stretch` inside a ListView asks for an
          // infinite height. The two cards in a row must match: a short card
          // beside a tall one reads as a layout bug, not as less data.
          // An odd last card takes the whole width rather than half of it with a
          // hole beside it. Three cards is the ordinary count now that sleep is
          // a ring, so the gap would be there every day.
          if (i + 1 >= cards.length)
            cards[i]
          else
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cards[i]),
                  const SizedBox(width: S.x3),
                  Expanded(child: cards[i + 1]),
                ],
              ),
            ),
        ],
        for (final s in absent) ...[const SizedBox(height: S.x3), s],
      ],
    );
  }

  Widget _plan(BuildContext c, P p, HomeData d) {
    final l = AppLocalizations.of(c);
    final rows = <Widget>[];

    final stepsLeft = d.steps.value == null
        ? null
        : (d.stepGoal - d.steps.value!).round();
    if (stepsLeft != null && stepsLeft > 0) {
      rows.add(
        _row(
          p,
          LucideIcons.footprints,
          C.green,
          l?.homeStepsLeft(thousands(stepsLeft)) ??
              '${thousands(stepsLeft)} steps left',
          l?.homeMovement ?? 'Movement',
          l?.homeGoalSteps(thousands(d.stepGoal)) ??
              'Goal ${thousands(d.stepGoal)}',
          false,
        ),
      );
    } else if (stepsLeft != null) {
      rows.add(
        _row(
          p,
          LucideIcons.footprints,
          C.green,
          l?.homeStepGoalMet ?? 'Step goal met',
          l?.homeMovement ?? 'Movement',
          l?.actionDone ?? 'Done',
          true,
        ),
      );
    }

    final target = d.strainTarget;
    if (target != null && target['value'] is num) {
      final aim = target['value'] as num;
      // The strain ring is on this screen now, so a row still saying "aim for
      // 11.4" beside a ring reading 14.2 is a plan the day already overtook.
      // Same shape the step goal above it has always had.
      final met = (d.strain.value ?? -1) >= aim;
      rows.add(
        _row(
          p,
          LucideIcons.zap,
          C.purple,
          met
              ? (l?.homeStrainTargetMet ?? 'Strain target met')
              : (l?.homeAimForStrain(displayNumber(aim, l, decimals: 1)) ??
                    'Aim for ${aim.toStringAsFixed(1)} strain'),
          l?.homeTraining ?? 'Training',
          met
              ? (l?.actionDone ?? 'Done')
              : '${(target['low'] as num?)?.toStringAsFixed(1) ?? ''}–'
                    '${(target['high'] as num?)?.toStringAsFixed(1) ?? ''}',
          met,
        ),
      );
    }

    final need = d.sleepNeedMin.value;
    if (need != null) {
      rows.add(
        _row(
          p,
          LucideIcons.bedDouble,
          C.blue,
          l?.homeSleepNeedRow(hm(need)) ?? '${hm(need)} of sleep',
          l?.homeTonight ?? 'Tonight',
          d.bedtime.value == null
              ? (l?.homeNeed ?? 'Need')
              : (l?.homeBedTime(clock(d.bedtime.value)) ??
                    'Bed ${clock(d.bedtime.value)}'),
          false,
        ),
      );
    }

    final planBody = rows.isEmpty
        ? StatusCard.forMetric(
                l?.homeNoPlanTitle ?? 'No plan for today yet',
                d.sleepNeedMin,
                l: l,
                // "none are established yet" is the COLD-START reason, and it
                // is a wrong answer when the baselines exist and are being
                // withheld.
                why: d.insightsStale != null
                    ? (l?.homeNoPlanWhyStale ??
                          'The cross-day rollup they come from is being rebuilt.')
                    : (l?.homeNoPlanWhyNone ?? 'None are established yet.'),
              ) ??
              const SizedBox.shrink()
        : Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x2),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(color: p.line, height: 1),
                  rows[i],
                ],
              ],
            ),
          );

    return planBody;
  }

  /// The only quick way into [AiBriefingScreen] used to be the notification
  /// that fires when a briefing is ready — dismiss or miss it, and the
  /// screen was two non-obvious taps deep behind Coach's overflow menu
  /// instead (see EDGE-14). Shown unconditionally, not gated on AI/BYOK
  /// being configured: the screen itself already has a graceful
  /// "no model set up" state with its own way to fix that, so gating here
  /// would just duplicate that door rather than simplify anything.
  /// Re-run on every call rather than cached by the caller: Home is kept
  /// alive by the shell's `IndexedStack` (see revision.dart), so a build can
  /// sit for hours without rerunning. Resolving once at build time and
  /// capturing the result in the row's `onTap` closure would let a stale
  /// morning/evening decision — or a briefing written in the background
  /// after that build — survive across the 17:00 boundary until Home
  /// happens to rebuild for an unrelated reason.
  ({BriefingPeriod period, Briefing? briefing}) _resolveBriefingNow(
    String day,
  ) {
    final period = currentBriefingPeriod(DateTime.now());
    return resolveBriefingToShow(
      period,
      BriefingStore.read(period, day: day),
      BriefingStore.read(BriefingPeriod.morning, day: day),
    );
  }

  Widget _briefingDoor(BuildContext c, String day) {
    final l = AppLocalizations.of(c);
    final resolved = _resolveBriefingNow(day);
    final cached = resolved.briefing;
    final unread = cached != null && !BriefingStore.isRead(cached);
    // Listen only to the briefing identity/read state. AppState also ticks for
    // live HR; those unrelated updates must not redraw this card every second.
    try {
      c.select<AppState, (String?, bool)>((_) {
        final b = _resolveBriefingNow(day).briefing;
        return (b?.id, b != null && !BriefingStore.isRead(b));
      });
    } catch (_) {
      // Gallery and golden screens do not have an AppState.
    }
    return _BriefingEntry(
      unread: unread,
      title: l?.homeBriefingTitle ?? 'AI briefing',
      summary:
          (cached == null
              ? null
              : cached.calledModel
              ? cached.oneLiner
              : (l?.aiBriefingNothingStoodOut ?? cached.oneLiner)) ??
          (day != todayLabel()
              ? (l?.homeBriefingSubtitlePastEmpty ??
                    'No saved summary for this day')
              : (l?.homeBriefingSubtitleEmpty ??
                    'Tap to write today\'s summary')),
      onNavigate: (open) async {
        // Resolved fresh at tap time via _resolveBriefingNow, not read from
        // the value above — see that method's doc for why.
        //
        // Writing a briefing (BriefingStore.write, in briefing_engine.dart)
        // does not bump AppState.insightsRevision, so RevisionReload's
        // automatic reload never fires for it — awaiting the route and
        // reloading on return is the only way this row picks up a briefing
        // written during the visit instead of showing stale/empty text until
        // some UNRELATED revision bump happens to refresh Home.
        final screen = AiBriefingScreen(
          period: _resolveBriefingNow(day).period,
          day: day,
        );
        await open<void>(screen);
        if (mounted) {
          // Keep the entry mounted while its palette settles. A full Home
          // load is unnecessary: briefing generation changes its own cache.
          setState(() {});
        }
      },
    );
  }

  Widget _row(
    P p,
    IconData i,
    Color col,
    String title,
    String kind,
    String meta,
    bool done,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: S.x3),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: p.wash(col), borderRadius: R.rSm),
          child: Icon(i, size: 16, color: p.on(col)),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(kind, style: F.over.copyWith(color: p.ink3)),
              const SizedBox(height: 2),
              Text(title, style: F.body.copyWith(color: p.ink)),
            ],
          ),
        ),
        const SizedBox(width: S.x2),
        Text(
          meta,
          textAlign: TextAlign.right,
          style: F.cap.copyWith(
            color: done ? p.on(C.green) : p.ink3,
            fontWeight: done ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    ),
  );
}
