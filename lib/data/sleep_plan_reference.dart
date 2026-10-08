const sleepPlanSettlingMarginSec = 60 * 60;

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
      observed <= inBed &&
      observed == inBed &&
      onset is num &&
      onset.isFinite &&
      wake is num &&
      wake.isFinite &&
      wake > onset &&
      edge is num &&
      edge.isFinite &&
      edge >= wake / 1000 + sleepPlanSettlingMarginSec;
}
