// Translate known app-authored notification copy only at presentation time.
// IDs, routes, quiet-hour policy, recorded model output and user text stay intact.
import '../compute/findings.dart';
import '../l10n/app_localizations.dart';
import '../l10n/presentation.dart';
import 'notification_event.dart';

String _copyKey(String text) =>
    text.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').toLowerCase();

String notificationTitle(String text, AppLocalizations l) {
  for (final kind in FindingKind.values) {
    final finding = Finding(kind, '');
    if (text == finding.title) return finding.localizedTitle(l);
  }
  final count = RegExp(r'^(\d+) things to look at$').firstMatch(text);
  if (count != null) return l.notificationFindingsCount(count[1]!);
  return l.notificationTitle(_copyKey(text), text);
}

String notificationBody(String text, AppLocalizations l) {
  for (final kind in FindingKind.values) {
    for (final risen in [true, false]) {
      final finding = Finding(kind, '', risen: risen);
      if (text == finding.detail) return finding.localizedDetail(l);
    }
  }
  // An aggregate health alert uses the same six authored finding templates.
  if (text.startsWith('• ')) {
    return text.split('\n').map((line) {
      for (final kind in FindingKind.values) {
        final title = Finding(kind, '').title;
        final prefix = '• $title — ';
        if (line.startsWith(prefix)) {
          return '• ${notificationTitle(title, l)} — '
              '${notificationBody(line.substring(prefix.length), l)}';
        }
      }
      return line;
    }).join('\n');
  }
  final fixed = l.notificationBody(_copyKey(text), text);
  if (fixed != text) return fixed;
  RegExpMatch? m;
  m = RegExp(r'^Your bedtime is around (.+)\. Start slowing down\.$').firstMatch(text);
  if (m != null) return l.notificationWindDownBody(m[1]!);
  m = RegExp(r'^Your band is at (\d+)%\. Charge it soon\.$').firstMatch(text);
  if (m != null) return l.notificationLowBatteryBody(m[1]!);
  m = RegExp(r'^No new data for about (\d+) hours\. Open OpenStrap to reconnect — background sync may have stalled\.$').firstMatch(text);
  if (m != null) return l.notificationStaleBody(m[1]!);
  m = RegExp(r'^Nothing above resting effort has been recorded for (\d+) minutes\. If the session is over, finish it from the Workout tab\.$').firstMatch(text);
  if (m != null) return l.notificationWorkoutIdleBody(m[1]!);
  m = RegExp(r'^Recovery (\d+), slept (\d+)h (\d+)m\.$').firstMatch(text);
  if (m != null) return l.notificationRecoverySleepBody(m[1]!, m[2]!, m[3]!);
  m = RegExp(r'^Recovery (\d+)\.$').firstMatch(text);
  if (m != null) return l.notificationRecoveryBody(m[1]!);
  m = RegExp(r'^You hit about (\d+) steps — at or above your (\d+) goal\.$').firstMatch(text);
  if (m != null) return l.notificationStepGoalBody(m[1]!, m[2]!);
  m = RegExp(r'^Resting heart rate ran about (\d+) bpm (higher|lower) late in the week than early\.$').firstMatch(text);
  if (m != null) return m[2] == 'higher' ? l.notificationWeeklyRhrHigher(m[1]!) : l.notificationWeeklyRhrLower(m[1]!);
  m = RegExp(r'^This week flagged: (.+)\. Details live on Health\.$').firstMatch(text);
  if (m != null) {
    final parts = m[1]!.split(', ').map((part) {
      final item = RegExp(r'^(possible illness onset|unusual physiology|elevated skin temperature) ×(\d+)$').firstMatch(part);
      if (item == null) return part;
      return switch (item[1]) {
        'possible illness onset' => l.notificationWeeklyIllness(item[2]!),
        'unusual physiology' => l.notificationWeeklyAnomaly(item[2]!),
        _ => l.notificationWeeklyTemp(item[2]!),
      };
    }).join(', ');
    return l.notificationWeeklyFlagged(parts);
  }
  m = RegExp(r'^At ([\d.]+)%/h it runs out around (.+) — before you wake\. Charge it now to keep tonight.s sleep\.$').firstMatch(text);
  if (m != null) return l.notificationBatteryBefore(_rate(m[1]!, l), m[2]!);
  m = RegExp(r'^At ([\d.]+)%/h it runs out around (.+), just after your usual wake time — about (\d+)% left when you get up\. Charge it now to keep tonight.s sleep\.$').firstMatch(text);
  if (m != null) return l.notificationBatteryReserve(_rate(m[1]!, l), m[2]!, m[3]!);
  m = RegExp(r'^At ([\d.]+)%/h it runs out around (.+), after your usual wake time\.$').firstMatch(text);
  if (m != null) return l.notificationBatteryAfter(_rate(m[1]!, l), m[2]!);
  return text;
}

String _rate(String text, AppLocalizations l) {
  final value = double.tryParse(text);
  return value == null ? text : displayNumber(value, l, decimals: 1);
}

NotificationEvent localizeNotificationEvent(NotificationEvent event, AppLocalizations l) =>
    l.localeName == 'en' ? event : NotificationEvent(
      dedupeKey: event.dedupeKey,
      category: event.category,
      priority: event.priority,
      title: notificationTitle(event.title, l),
      body: notificationBody(event.body, l),
      date: event.date,
      route: event.route,
      osId: event.osId,
    );
