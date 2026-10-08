import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/journal_fields.dart';
import '../../data/weight_store.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import '../profile/weight_import_settings.dart';
import 'home_screen.dart' show unitsOf;
import 'metric_detail.dart' show detailScaffold;

const kWeightTrendDays = 180;

Future<Map<String, WeightReading>> loadWeightHistory() async {
  final now = DateTime.now();
  final store = WeightStore(await LocalDb.instance);
  final history = await store.byDay(
    since: DateTime(now.year, now.month, now.day - (kWeightTrendDays - 1)),
  );
  if (history.isNotEmpty) return history;
  final latest = await store.latest();
  return latest == null ? history : {latest.day: latest};
}

String weightSource(BuildContext c, WeightReading reading) => reading.manual
    ? (AppLocalizations.of(c)?.weightManualSource ?? 'Entered by you')
    : reading.source;

/// Shared Journal / Health chart. Gaps, units and the existing seven-day EWMA
/// remain the same; the daily read seam additionally admits source records.
class WeightTrendScreen extends StatefulWidget {
  const WeightTrendScreen({super.key, this.load = loadWeightHistory});
  final Future<Map<String, WeightReading>> Function() load;
  @override
  State<WeightTrendScreen> createState() => _WeightTrendScreenState();
}

class _WeightTrendScreenState extends State<WeightTrendScreen> {
  Map<String, WeightReading> _byDay = const {};
  bool _loading = true, _failed = false;
  int _loadGeneration = 0;
  @override
  void initState() {
    super.initState();
    WeightStore.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    WeightStore.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final rows = await widget.load();
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _byDay = rows;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final title = l?.journalComposeWeightLabel ?? 'Weight';
    final p = P.of(c);
    if (_loading) {
      return detailScaffold(c, title, const [
        SizedBox(height: S.x8),
        Center(child: CircularProgressIndicator()),
      ]);
    }
    if (_failed) {
      return detailScaffold(c, title, [
        StatusCard(
          title,
          l?.weightReadFailed ?? 'Weight history could not be read. Try again.',
          icon: LucideIcons.scale,
        ),
        const SizedBox(height: S.x3),
        BigButton(
          l?.logWorkoutTryAgain ?? 'Try again',
          onTap: _load,
          soft: true,
        ),
      ]);
    }
    final u = unitsOf(c);
    final trend = weightTrendEwma({
      for (final e in _byDay.entries) e.key: e.value.kg,
    });
    final days = trend.keys.toList()..sort();
    final latest = days.isEmpty ? null : _byDay[days.last];
    final first = days.isEmpty ? null : DateTime.parse(days.first);
    final span = first == null
        ? 0
        : calendarDaysBetween(first, DateTime.parse(days.last));
    double show(double kg) =>
        u == null ? kg : (double.tryParse(u.weightField(kg)) ?? kg);
    final vals = <double?>[
      if (first != null)
        for (var i = 0; i <= span; i++)
          if (trend[dayLabelOf(
                DateTime(first.year, first.month, first.day + i),
              )]
              case final v?)
            show(v)
          else
            null,
    ];
    final axis = AxisSpec.of(
      vals.whereType<double>().toList(),
      format: axisFixed,
    );
    return detailScaffold(c, title, [
      const SizedBox(height: S.x2),
      if (latest != null) ...[
        Surface(
          child: MetricRow(
            LucideIcons.scale,
            C.blue,
            title,
            displayNumber(show(latest.kg), l, decimals: 1),
            unit: u?.isImperial == true ? 'lb' : 'kg',
            sub:
                l?.weightLatestReading(l.localeName == 'it' ? MaterialLocalizations.of(c).formatMediumDate(DateTime.parse(latest.day)) : latest.day, weightSource(c, latest)) ??
                '${latest.day} · ${weightSource(c, latest)}',
          ),
        ),
        const SizedBox(height: S.x3),
      ],
      if (trend.length < 2)
        StatusCard(
          l?.journalComposeNotEnoughEntriesTitle ??
              'Not enough entries for a trend',
          l?.journalComposeNotEnoughEntriesBody ??
              'The line needs at least two days. Nothing is filled in between them.',
          icon: LucideIcons.scale,
        )
      else
        Surface(
          child: ChartFrame(
            title: l?.journalComposeSevenDayTrend ?? 'Seven-day trend',
            unit: u?.isImperial == true ? 'lb' : 'kg',
            height: 140,
            yAxis: axis,
            xLabels: [days.first, days.last],
            series: vals,
            footnote:
                l?.weightTrendSources ?? 'Days without readings stay empty.',
            empty: axis == null ? const NoData() : null,
            child: axis == null
                ? const SizedBox.shrink()
                : RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: LineChart(
                        vals,
                        p.on(C.blue),
                        fill: false,
                        t: animate(c, 1),
                        axis: axis,
                      ),
                    ),
                  ),
          ),
        ),
      const SizedBox(height: S.x4),
      Text(
        l?.journalComposeWeightTrendExplainer(trend.length) ??
            'The seven-day smoothed trend shows only days with readings. The band does not measure weight.',
        style: F.over.copyWith(color: p.ink3, height: 1.5),
      ),
      const SizedBox(height: S.x4),
      const WeightImportSettings(),
    ]);
  }
}

/// Weight appears even without band data; it reads only the independent ledger.
class WeightExploreRow extends StatefulWidget {
  const WeightExploreRow({super.key, this.load = loadWeightHistory});
  final Future<Map<String, WeightReading>> Function() load;
  @override
  State<WeightExploreRow> createState() => _WeightExploreRowState();
}

class _WeightExploreRowState extends State<WeightExploreRow> {
  late Future<Map<String, WeightReading>> _history;
  @override
  void initState() {
    super.initState();
    _history = widget.load();
    WeightStore.changes.addListener(_reload);
  }

  void _reload() {
    if (mounted) {
      setState(() {
        _history = widget.load();
      });
    }
  }

  @override
  void dispose() {
    WeightStore.changes.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => FutureBuilder<Map<String, WeightReading>>(
    future: _history,
    builder: (c, snapshot) {
      final l = AppLocalizations.of(c);
      final rows = snapshot.data ?? const <String, WeightReading>{};
      final days = rows.keys.toList()..sort();
      final latest = days.isEmpty ? null : rows[days.last];
      final u = unitsOf(c);
      return Surface(
        child: MetricRow(
          LucideIcons.scale,
          C.blue,
          l?.journalComposeWeightLabel ?? 'Weight',
          latest == null
              ? '—'
              : displayNumber(u?.weightValue(latest.kg) ?? latest.kg, l, decimals: u?.isImperial == true ? 0 : 1),
          unit: u?.isImperial == true ? 'lb' : 'kg',
          sub: snapshot.hasError
              ? (l?.weightReadFailed ??
                    'Weight history could not be read. Try again.')
              : latest == null
              ? (l?.weightTrendSources ?? 'Days without readings stay empty.')
              : (l?.weightLatestReading(l.localeName == 'it' ? MaterialLocalizations.of(c).formatMediumDate(DateTime.parse(latest.day)) : latest.day, weightSource(c, latest)) ??
                    '${latest.day} · ${weightSource(c, latest)}'),
          destination: const WeightTrendScreen(),
        ),
      );
    },
  );
}
