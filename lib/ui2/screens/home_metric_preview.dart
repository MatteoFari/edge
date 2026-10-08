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
  final Map<String, dynamic> resp;
  final SleepData? sleep;
  final DayStrainData? strain;

  const HomeMetricPreviewData({
    required this.day,
    this.recovery = const [],
    this.baselines = const {},
    this.resp = const {},
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
          resp: heart['resp'] is Map
              ? Map<String, dynamic>.from(heart['resp'] as Map)
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
    final drivers = <Widget>[
      for (final (key, label, unit, decimals) in [
        ('hrv', l?.homeDriverHrv ?? 'HRV', 'ms', 0),
        ('resting_hr', l?.homeDriverRhr ?? 'Resting heart rate', 'bpm', 0),
        ('resp', l?.homeDriverResp ?? 'Breathing rate', 'br/min', 1),
      ])
        if (_driver(key) case final Map b)
          if (b['value'] case final num value)
            if (value.isFinite)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: F.cap.copyWith(color: p.ink2)),
                  Text(
                    '${_reading(value, decimals)} $unit',
                    style: F.n17.copyWith(color: p.ink),
                  ),
                  if (b['baseline'] case final num usual)
                    if (usual.isFinite)
                      Text(
                        '${l?.homeMetricUsual ?? 'Usual'} ${_reading(usual, decimals)} $unit',
                        style: F.over.copyWith(color: p.ink3),
                      ),
                ],
              ),
    ];
    final title = l?.homeMetricRecoveryTrend ?? 'Last 7 days';
    final xLabels = ['${first.day}/${first.month}', '${end.day}/${end.month}'];
    final hasHistory = d.recovery.any((v) => v != null);
    Widget chart(double height, {bool showYAxis = true}) => ChartFrame(
      title: title,
      unit: '/100',
      height: height,
      yAxis: showYAxis ? axis : null,
      series: d.recovery,
      xLabels: xLabels,
      empty: hasHistory ? null : const NoData(),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: LineChart(d.recovery, p.on(C.green), axis: axis),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (c, box) {
        final compact = !bigText(c) && box.maxWidth >= 300;
        final metrics = compact
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < drivers.length; i++) ...[
                    if (i > 0) const SizedBox(width: S.x4),
                    Expanded(child: drivers[i]),
                  ],
                ],
              )
            : Wrap(spacing: S.x4, runSpacing: S.x2, children: drivers);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The driver rows keep their natural text height. The chart takes
            // the remaining space above them instead of pushing a reading
            // below the preview viewport.
            if (box.hasBoundedHeight)
              Flexible(
                child: LayoutBuilder(
                  builder: (c, chartBox) {
                    final scaler = MediaQuery.textScalerOf(c);
                    Size measure(
                      String text,
                      TextStyle style,
                      double width, {
                      int? maxLines,
                    }) {
                      final painter = TextPainter(
                        text: TextSpan(
                          text: text,
                          style: DefaultTextStyle.of(c).style.merge(style),
                        ),
                        textDirection: Directionality.of(c),
                        textScaler: scaler,
                        maxLines: maxLines,
                      )..layout(maxWidth: width);
                      final size = painter.size;
                      painter.dispose();
                      return size;
                    }

                    final unit = measure('/100', F.over, box.maxWidth);
                    final header = measure(
                      title,
                      F.cap.copyWith(fontWeight: FontWeight.w600),
                      bigText(c)
                          ? box.maxWidth
                          : (box.maxWidth - unit.width - S.x2).clamp(
                              0.0,
                              box.maxWidth,
                            ),
                      maxLines: 2,
                    );
                    final headerHeight = bigText(c)
                        ? header.height + unit.height
                        : (header.height > unit.height
                              ? header.height
                              : unit.height);
                    final tickHeight = measure(
                      '100',
                      F.over,
                      box.maxWidth,
                    ).height;
                    final overhead =
                        headerHeight +
                        S.x3 +
                        (hasHistory ? S.x1 + tickHeight : 0);
                    final minPlot = hasHistory
                        ? tickHeight
                        : measure('No data yet', F.cap, box.maxWidth).height;
                    final available = chartBox.maxHeight - overhead;
                    if (available < minPlot) return const SizedBox.shrink();
                    final height = available.clamp(0.0, S.x16 + S.x6);
                    return SizedBox(
                      height: overhead + height,
                      child: chart(height, showYAxis: height >= tickHeight * 2),
                    );
                  },
                ),
              )
            else
              chart(S.x16 + S.x6),
            if (drivers.isNotEmpty) ...[const SizedBox(height: S.x3), metrics],
          ],
        );
      },
    );
  }

  Map? _driver(String key) {
    // The selected experiment remains separate from the standard readiness
    // input. Withheld experiments never borrow its value or personal baseline.
    if (key == 'resp' && d.resp['experimental'] == true) {
      return {'value': d.resp['value']};
    }
    final block = d.baselines[key];
    return block is Map ? block : null;
  }

  String _reading(num value, int decimals) => decimals == 0
      ? value.round().toString()
      : value.toStringAsFixed(decimals);
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
