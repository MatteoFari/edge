import 'package:intl/intl.dart';

import '../coach/coach_engine.dart';
import '../data/journal_fields.dart';
import 'app_localizations.dart';
import 'presentation.dart';

/// Dialog copy only. Action payloads and model/tool messages remain untouched.
({String title, String summary}) localizeCoachAction(
  ActionRequest request,
  AppLocalizations? l,
) {
  final original = (title: request.title, summary: request.summary);
  if (l == null || l.localeName != 'it') return original;
  final a = request.args;
  String value(Object? v) => _number(v, l);
  String date(Object? v) => _date(v, l);
  String activity() {
    final raw = a['type']?.toString();
    if (raw == null) return l.workoutScreenTitle.toLowerCase();
    return l.activityName(raw.toLowerCase().replaceAll(' ', '_'), raw);
  }

  // These two tools already resolve their day before constructing the request.
  // Read that effective day rather than resolving "today" a second time.
  final resolvedDay = RegExp(
    r'\b\d{4}-\d{2}-\d{2}\b',
  ).firstMatch(request.summary)?.group(0);
  final summary = switch (request.tool) {
    'remember_preference' => request.summary,
    'log_journal' => l.coachActionJournal(
      date(resolvedDay ?? a['date']),
      a['tags'] is List
          ? '[${(a['tags'] as List).map((v) => journalTagLabel(v.toString(), l)).join(', ')}]'
          : (a['tags'] ?? const []).toString(),
      (a['note'] ?? '').toString(),
    ),
    'log_period' => l.coachActionPeriod(date(resolvedDay ?? a['date'])),
    'start_workout' => l.coachActionStartWorkout(activity()),
    'end_workout' => l.coachActionEndWorkout,
    'log_food' => l.coachActionFood(
      '${a['label']}',
      _meal('${a['meal']}', l),
      date(a['date']),
      a['kcal'] == null ? '' : ' (${value(a['kcal'])} kcal)',
    ),
    'log_journal_fields' => l.coachActionJournalFields(
      _fields(a['fields'], l),
      date(a['date']),
    ),
    'add_completed_workout' => l.coachActionCompletedWorkout(
      value(a['duration_min']),
      activity(),
      '${a['start_time']}',
      date(a['date']),
    ),
    'add_medication' => l.coachActionMedication(
      '${a['name']}',
      '${a['time']}',
      _days(a['weekdays'], l),
    ),
    'mark_medication' => l.coachActionMedicationDose(
      '${a['name']}',
      date(a['date']),
      l.coachActionDoseState('${a['state']}', '${a['state']}'),
    ),
    'set_step_goal' => l.coachActionStepGoal(value(a['goal'])),
    _ => null,
  };
  if (summary == null) return original;
  return (
    title: request.tool == 'remember_preference'
        ? l.coachMemoryConfirm
        : l.coachActionTitle(request.tool, request.title),
    summary: summary,
  );
}

String _number(Object? value, AppLocalizations l) {
  // Strings may be user-authored text or identifiers. Preserve them verbatim.
  if (value is! num || !value.isFinite) return '$value';
  // Keep the provider's full decimal precision. A fixed display precision
  // could change the amount the user is being asked to approve.
  final separator = NumberFormat.decimalPattern(
    l.localeName,
  ).symbols.DECIMAL_SEP;
  return value.toString().replaceAll('.', separator);
}

String _date(Object? value, AppLocalizations l) {
  if (value == null || value.toString().isEmpty || value == 'today') {
    return l.coachChatToday.toLowerCase();
  }
  final raw = value.toString();
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return raw;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final check = DateTime.utc(year, month, day);
  if (check.year != year || check.month != month || check.day != day) {
    return raw;
  }
  final months = [
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
  ];
  return '$day ${months[month - 1]} $year';
}

String _meal(String value, AppLocalizations l) => switch (value) {
  'breakfast' => l.logFoodBreakfast.toLowerCase(),
  'lunch' => l.logFoodLunch.toLowerCase(),
  'dinner' => l.logFoodDinner.toLowerCase(),
  'snack' => l.logFoodSnack.toLowerCase(),
  _ => value,
};

String _fields(Object? fields, AppLocalizations l) {
  if (fields is! Map || fields.isEmpty) return l.coachActionNoFields;
  return fields.entries
      .map((entry) {
        final key = entry.key.toString();
        final spec = kJournalFields.where((f) => f.key == key).firstOrNull;
        final label = spec?.localizedLabel(l) ?? key;
        final unit = spec?.localizedUnit(l) ?? '';
        return '$label${unit.isEmpty ? '' : ' ($unit)'} ${_number(entry.value, l)}';
      })
      .join(', ');
}

String _days(Object? days, AppLocalizations l) {
  if (days is! List || days.isEmpty || days.length == 7) {
    return l.alarmEveryDay.toLowerCase();
  }
  final names = [
    l.wellnessMon,
    l.wellnessTue,
    l.wellnessWed,
    l.wellnessThu,
    l.wellnessFri,
    l.wellnessSat,
    l.wellnessSun,
  ];
  return days
      .map(
        (d) => d is num && d >= 1 && d <= 7
            ? names[d.toInt() - 1].toLowerCase()
            : '?',
      )
      .join(', ');
}
