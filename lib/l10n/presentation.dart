// Localization at the display boundary. Canonical keys and user-created text
// remain unchanged in storage, analytics, exports and model payloads.
import 'package:intl/intl.dart';

import '../data/journal_fields.dart';
import '../compute/findings.dart';
import '../state/units_controller.dart';
import 'app_localizations.dart';

extension JournalFieldPresentation on JournalFieldSpec {
  String localizedLabel(AppLocalizations? l) =>
      custom ? label : (l?.journalFieldName(key, label) ?? label);

  String localizedUnit(AppLocalizations? l) =>
      !custom && unit == 'units' ? (l?.unitAlcohol ?? unit) : unit;

  String localizedValue(double value, AppLocalizations? l) {
    final number = displayNumber(value, l,
        decimals: isRating || value == value.roundToDouble() ? 0 : 1);
    final shownUnit = localizedUnit(l);
    return shownUnit.isEmpty ? number : '$number $shownUnit';
  }
}

extension UnitsPresentation on UnitsController {
  String localizedWeight(num? kg, AppLocalizations? l) {
    if (kg == null) return '—';
    final value = weightValue(kg);
    return '${displayNumber(isImperial ? value.round() : value, l, decimals: !isImperial && value != value.roundToDouble() ? 1 : 0)} $weightUnit';
  }

  String localizedWeightLabel(AppLocalizations? l) =>
      l?.fieldWeightUnit(weightUnit) ?? weightLabel;
  String localizedHeightLabel(AppLocalizations? l) =>
      l?.fieldHeightUnit(isImperial ? 'in' : 'cm') ?? heightLabel;
}

String displayNumber(num value, AppLocalizations? l, {int decimals = 0}) =>
    NumberFormat(
      decimals == 0 ? '#,##0' : '#,##0.${'0' * decimals}',
      l?.localeName ?? 'en',
    ).format(value);

extension FindingPresentation on Finding {
  String localizedTitle(AppLocalizations? l) =>
      l?.findingTitle(kind.name, title) ?? title;
  String localizedDetail(AppLocalizations? l) => l?.findingDetail(
        kind == FindingKind.rhrShift ? (risen == false ? 'rhrFallen' : 'rhrRisen') : kind.name,
        detail,
      ) ?? detail;
}

String journalTagLabel(String tag, AppLocalizations? l) =>
    l?.journalTag(tag.replaceAll(' ', '_'), tag) ?? tag;

String activityStatLabel(String name, AppLocalizations? l) =>
    l?.activityStatName(name == 'Time' ? 'elapsed' : name.toLowerCase().replaceAll(' ', '_'), name) ?? name;

// The sweep's factual templates are rendered in the selected locale. Its
// evidence, ranking, numbers and stored/generated briefing text are untouched.
String sweepReading(String text, AppLocalizations? l) {
  if (l == null || l.localeName != 'it') return text;
  for (final name in ['resting heart rate', 'sleep efficiency', 'time asleep', 'readiness', 'strain', 'steps', 'HRV']) {
    if (text.startsWith('$name ')) {
      final label = l.sweepMetricName(name.toLowerCase().replaceAll(' ', '_'), name);
      return '$label ${text.substring(name.length + 1).replaceAllMapped(RegExp(r'(\d+)\.(\d+)'), (m) => '${m[1]},${m[2]}')}';
    }
  }
  return text;
}

String sweepFindingText(String text, AppLocalizations? l) {
  if (l == null || l.localeName != 'it') return text;
  final match = RegExp(r'^(.+) — (.+) \(usually (.+)\)$').firstMatch(text);
  if (match == null) return text;
  var position = match[2]!;
  final extreme = RegExp(r'^the (highest|lowest) in (\d+) days$').firstMatch(position);
  if (extreme != null) {
    position = extreme[1] == 'highest' ? l.sweepHighest(extreme[2]!) : l.sweepLowest(extreme[2]!);
  } else if (position == 'above your usual range') {
    position = l.sweepAboveUsual;
  } else if (position == 'below your usual range') {
    position = l.sweepBelowUsual;
  }
  final range = match[3]!.replaceAllMapped(RegExp(r'(\d+)\.(\d+)'), (m) => '${m[1]},${m[2]}');
  return l.sweepFindingSentence(sweepReading(match[1]!, l), position, range);
}
