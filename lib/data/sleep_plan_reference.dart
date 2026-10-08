const sleepPlanSettlingMarginSec = 60 * 60;
// Admission tolerance for isolated missing samples, not sleep imputation.
// Both bounds must hold; unknown or substantial gaps remain incomplete.
const sleepPlanMaxGapSec = 30;
const sleepPlanMaxGapFraction = 0.005;

/// Pending corrections may have outlived their recordings. A fresh plan can
/// use the remaining history only when it explicitly excluded those nights.
/// The source-context check still guards changes to the correction revisions.
bool sleepPlanOverridesHandled(Map context, Object? planning) {
  final pending = context['pending_overrides'];
  if (pending is! List) return false;
  if (pending.isEmpty) return true;
  final excluded = planning is Map ? planning['excluded_days'] : null;
  if (excluded is! List) return false;
  return pending.every(
    (entry) =>
        entry is List &&
        entry.length == 2 &&
        entry.first is String &&
        excluded.contains(entry.first),
  );
}

/// The prospective target saved before this night began. It is a planning
/// estimate, not a measurement of biological sleep need. Missing legacy
/// snapshots stay missing instead of borrowing the current recommendation.
Map<String, dynamic>? sleepPlanReference(
  Object? value,
  int? onsetSec, {
  required String nightDay,
}) {
  if (value is! Map || onsetSec == null || onsetSec <= 0) return null;
  final need = value['need_sec'];
  final built = value['built_at_epoch'];
  final committed = value['committed_at_epoch'];
  if (need is! num ||
      !need.isFinite ||
      need <= 0 ||
      need > 24 * 3600 ||
      built is! num ||
      !built.isFinite ||
      built <= 0 ||
      committed is! num ||
      !committed.isFinite ||
      committed < built ||
      committed >= onsetSec ||
      onsetSec - committed > 48 * 3600 ||
      value['target_day'] != nightDay ||
      value['model'] != 'observed_sleep_target_v1') {
    return null;
  }
  return Map<String, dynamic>.from(value);
}

double? nightSleepTargetSec(Map<String, dynamic> bundle) {
  final sleep = bundle['sleep'];
  final window = sleep is Map ? sleep['window'] : null;
  final value = window is Map ? window['value'] : null;
  final onsetMs = value is Map ? value['onset_ms'] : null;
  final onset = onsetMs is num ? (onsetMs / 1000).round() : null;
  final day = bundle['date'];
  if (day is! String) return null;
  return (sleepPlanReference(
            bundle['sleep_plan_reference'],
            onset,
            nightDay: day,
          )?['need_sec']
          as num?)
      ?.toDouble();
}

/// A conservative admission check for comparisons, not another sleep detector.
/// Unknown coverage, missing bounds, unfinished compute or a draining night
/// cannot establish an observed shortfall. Retained bundles keep this result.
bool sleepPlanNightComplete(
  Map<String, dynamic> bundle, {
  required bool partial,
  bool settledLegacy = false,
}) {
  final sleep = bundle['sleep'];
  final accounting = sleep is Map ? sleep['accounting'] : null;
  final a = accounting is Map ? accounting['value'] : null;
  final window = sleep is Map ? sleep['window'] : null;
  final w = window is Map ? window['value'] : null;
  if (partial || a is! Map || w is! Map) return false;
  final tst = a['tst_sec'], inBed = a['in_bed_sec'];
  final observed = a['observed_in_bed_sec'];
  final onset = w['onset_ms'], wake = w['offset_ms'];
  final edge = bundle['data_edge_sec'];
  return tst is num &&
      tst.isFinite &&
      tst > 0 &&
      inBed is num &&
      inBed.isFinite &&
      inBed > 0 &&
      tst <= inBed &&
      observed is num &&
      observed.isFinite &&
      observed > 0 &&
      observed <= inBed &&
      tst <= observed &&
      inBed - observed <= sleepPlanMaxGapSec &&
      (inBed - observed) / inBed <= sleepPlanMaxGapFraction &&
      onset is num &&
      onset.isFinite &&
      wake is num &&
      wake.isFinite &&
      wake > onset &&
      ((edge is num &&
              edge.isFinite &&
              edge >= wake / 1000 + sleepPlanSettlingMarginSec) ||
          (edge == null && settledLegacy));
}
