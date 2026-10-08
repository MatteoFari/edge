/// Read-only shaping of stored respiration. The experimental series is
/// separate from resp_rate, which remains the readiness/health-export input.
Map<String, dynamic>? respiratoryDisplayMetric(Map<String, dynamic> bundle) {
  final scalars = bundle['scalars'] is Map
      ? bundle['scalars'] as Map
      : const {};
  final respiration = bundle['respiration'] is Map
      ? bundle['respiration'] as Map
      : const {};
  final experimental = respiration['experimental'] is Map;
  final env = (experimental ? respiration['experimental'] : respiration['rsa']);
  final envelope = env is Map ? env : const {};
  final raw = scalars[experimental ? 'resp_rate_experimental' : 'resp_rate'];
  final value = raw is num && raw.isFinite ? raw.toDouble() : null;
  final note = envelope['note']?.toString();
  if (!experimental && value == null && (note == null || note.isEmpty)) {
    return null;
  }
  return {
    'value': value == null ? null : double.parse(value.toStringAsFixed(1)),
    'confidence': value == null ? 0.0 : (envelope['confidence'] as num?) ?? 0.5,
    'tier': envelope['tier'],
    'inputs_used': envelope['inputs_used'],
    // Retain abstention reasons. Successful readings need no advisory copy;
    // the stored envelope still carries the experiment's provenance.
    'note': ?(experimental && value != null ? null : note),
    if (experimental) 'label': 'Breathing rate',
    'experimental': experimental,
    'chart_key': experimental ? 'resp_rate_experimental' : 'resp_rate',
  };
}

/// Only accepted windows are plotted. A withheld night may still contain
/// local windows; do not display them as a nightly curve without sufficient
/// representative evidence for the night itself.
List<Map<String, num>> experimentalRespiratoryCurve(
  Map<String, dynamic> bundle,
) {
  final respiration = bundle['respiration'];
  final env = respiration is Map ? respiration['experimental'] : null;
  final value = env is Map ? env['value'] : null;
  if (value is! Map || value['brpm'] is! num) return const [];
  final windows = value['windows'];
  if (windows is! List) return const [];
  return [
    for (final w in windows)
      if (w is Map &&
          w['brpm'] is num &&
          (w['brpm'] as num).isFinite &&
          w['start_sec'] is num &&
          w['end_sec'] is num)
        {
          't': (((w['start_sec'] as num) + (w['end_sec'] as num)) / 2).round(),
          'v': w['brpm'] as num,
        },
  ];
}
