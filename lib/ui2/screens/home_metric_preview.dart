import 'package:flutter/material.dart';

import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../activity/day_strain.dart';
import '../ui2.dart';
import 'home_screen.dart' show HomeRingKind, denseDays, pointsOf, clockOfTs;
import 'sleep_detail.dart' show SleepData, sleepStageRows;

/// A small read of the same persisted data used by the full detail screens.
class HomeMetricPreviewData {
  final String day;
  final List<double?> recovery;
  final Map<String, dynamic> baselines;
  final SleepData? sleep;
  final DayStrainData? strain;

  const HomeMetricPreviewData({
    required this.day,
    this.recovery = const [],
    this.baselines = const {},
    this.sleep,
    this.strain,
  });

  static Future<HomeMetricPreviewData> load(
    LocalRepository repo,
    HomeRingKind kind,
    String day,
  ) async {
    switch (kind) {
      case HomeRingKind.recovery:
        final chart = await repo.getChart('recovery');
        final days = await repo.availableDays();
        final heart = days.contains(day)
            ? await repo.getDayHeart(day)
            : const <String, dynamic>{};
        return HomeMetricPreviewData(
          day: day,
          recovery: denseDays(pointsOf(chart), 7, end: DateTime.parse(day)),
          baselines: heart['baselines'] is Map
              ? Map<String, dynamic>.from(heart['baselines'] as Map)
              : const {},
        );
      case HomeRingKind.sleep:
        return HomeMetricPreviewData(
          day: day,
          sleep: await SleepData.loadNight(repo, want: day),
        );
      case HomeRingKind.strain:
        final data = await DayStrainData.load(repo, want: day);
        // A today read can serve an older settled bundle. Never give that
        // trace today's label in this selected-day summary.
        return HomeMetricPreviewData(
          day: day,
          strain: data.day == null || dayLabelOf(data.day!) == day
              ? data
              : const DayStrainData(),
        );
    }
  }
}

Widget buildHomeMetricPreview(
  BuildContext c,
  HomeMetricPreviewData d,
  HomeRingKind kind,
) => switch (kind) {
  HomeRingKind.recovery => _RecoveryPreview(d),
  HomeRingKind.sleep => _SleepPreview(d.sleep ?? const SleepData()),
  HomeRingKind.strain => _StrainPreview(d.strain ?? const DayStrainData()),
};

class _RecoveryPreview extends StatelessWidget {
  final HomeMetricPreviewData d;
  const _RecoveryPreview(this.d);
  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c);
    final end = DateTime.parse(d.day);
    final first = DateTime(end.year, end.month, end.day - 6);
    final axis = AxisSpec(min: 0, max: 100, format: axisInt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChartFrame(
          title: l?.homeMetricRecoveryTrend ?? 'Last 7 days',
          unit: '/100',
          height: S.x16 + S.x6,
          yAxis: axis,
          series: d.recovery,
          xLabels: ['${first.day}/${first.month}', '${end.day}/${end.month}'],
          empty: d.recovery.any((v) => v != null) ? null : const NoData(),
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: LineChart(d.recovery, p.on(C.green), axis: axis),
            ),
          ),
        ),
        const SizedBox(height: S.x3),
        Wrap(
          spacing: S.x4,
          runSpacing: S.x2,
          children: [
            for (final (key, label, unit) in [
              ('hrv', l?.homeDriverHrv ?? 'HRV', 'ms'),
              ('resting_hr', l?.homeDriverRhr ?? 'Resting heart rate', 'bpm'),
            ])
              if (d.baselines[key] case final Map b)
                if (b['value'] case final num value)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: F.cap.copyWith(color: p.ink2)),
                      Text(
                        '${value.round()} $unit',
                        style: F.n17.copyWith(color: p.ink),
                      ),
                      if (b['baseline'] case final num usual)
                        Text(
                          '${l?.homeMetricUsual ?? 'Usual'} ${usual.round()} $unit',
                          style: F.over.copyWith(color: p.ink3),
                        ),
                    ],
                  ),
          ],
        ),
      ],
    );
  }
}

class _SleepPreview extends StatelessWidget {
  final SleepData d;
  const _SleepPreview(this.d);
  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c);
    final n = d.night, stages = d.stages;
    final rows = sleepStageRows(c, n);
    final start = (n['onset_ts'] as num?)?.toInt();
    final end = (n['wake_ts'] as num?)?.toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChartFrame(
          title: l?.sleepDetailHypnogramLabel ?? 'Hypnogram',
          unit: '',
          height: S.x16 + S.x4,
          xLabels: [
            if (start != null) clockOfTs(start),
            if (end != null) clockOfTs(end),
          ],
          empty: stages.any((s) => s != null) ? null : const NoData(),
          legend: rows.length < 4 ? Hypnogram.legend(p) : const [],
          child: RepaintBoundary(
            child: Row(
              children: [
                for (final (run, columns) in SleepData.stageRuns(stages))
                  Expanded(
                    flex: columns,
                    child: run == null
                        ? const SizedBox.expand()
                        : CustomPaint(
                            size: Size.infinite,
                            painter: Hypnogram(run, p),
                          ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: S.x2),
        Wrap(
          spacing: S.x4,
          runSpacing: S.x2,
          children: [
            for (final (label, duration, color) in rows)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: S.x2,
                    height: S.x2,
                    decoration: BoxDecoration(
                      color: p.on(color),
                      borderRadius: R.rSm,
                    ),
                  ),
                  const SizedBox(width: S.x1),
                  Flexible(
                    child: Text(
                      '$label $duration',
                      style: F.over.copyWith(color: p.ink2),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _StrainPreview extends StatelessWidget {
  final DayStrainData d;
  const _StrainPreview(this.d);
  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c);
    final axis = AxisSpec.of(d.curve.whereType<double>(), floor: 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChartFrame(
          title: l?.dayStrainChartTitle ?? 'STRAIN THROUGH THE DAY',
          unit: '0–21',
          height: S.x16 + S.x6,
          yAxis: axis,
          series: d.curve,
          xLabels: d.timeLabels,
          empty: d.hasCurve ? null : const NoData(),
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: LineChart(d.curve, p.on(C.purple), axis: axis),
            ),
          ),
        ),
        const SizedBox(height: S.x2),
        if (d.zoneMin case final List<int> zones)
          Wrap(
            spacing: S.x3,
            runSpacing: S.x1,
            children: [
              for (var i = 0; i < zones.length; i++)
                Text(
                  'Z${i + 1} · ${zones[i]} min',
                  style: F.over.copyWith(color: p.ink2),
                ),
            ],
          ),
        if (d.coveragePct != null) ...[
          const SizedBox(height: S.x2),
          Text(
            l?.dayStrainLowCoverageTitle(d.coveragePct!) ??
                'The band saw ${d.coveragePct}% of this day',
            style: F.over.copyWith(color: p.ink3),
          ),
        ],
      ],
    );
  }
}
