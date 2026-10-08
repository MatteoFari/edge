import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/weight_store.dart';
import '../../health/health_weight_import.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';

class WeightImportSettings extends StatefulWidget {
  const WeightImportSettings({super.key, this.runner});
  final WeightImportRunner? runner;
  @override
  State<WeightImportSettings> createState() => _WeightImportSettingsState();
}

class _WeightImportSettingsState extends State<WeightImportSettings> {
  WeightImportRunner get runner => widget.runner ?? AutoWeightImport.runner;
  bool _enabled = false, _busy = false, _loaded = false, _accessKnown = false;
  WeightAccess _access = const WeightAccess();
  DateTime? _lastSuccess;
  WeightImportOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!runner.supported) return;
    try {
      final enabled = await runner.enabled();
      final access = await runner.bridge.status();
      final state = await WeightStore(await runner.openDb()).syncState();
      final ms = state?['last_success_ms'] as num?;
      final prefs = await SharedPreferences.getInstance();
      final status = prefs.getString(kWeightImportStatus);
      if (!mounted) return;
      setState(() {
        _enabled = enabled;
        _access = access;
        _accessKnown = true;
        _loaded = true;
        _lastSuccess = ms == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(ms.toInt());
        _outcome = WeightImportOutcome.values
            .where((v) => v.name == status)
            .firstOrNull;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _outcome = WeightImportOutcome.failed;
        });
      }
    }
  }

  Future<void> _run(Future<WeightImportOutcome> Function() job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _outcome = null;
    });
    WeightImportOutcome result;
    try {
      result = await job();
    } catch (_) {
      result = WeightImportOutcome.failed;
    }
    await _load();
    if (mounted) {
      setState(() {
        _busy = false;
        _outcome = result;
      });
    }
  }

  Future<WeightImportOutcome> _optional(String kind) async {
    final access = await runner.requestOptional(kind);
    final granted = kind == 'history' ? access.history : access.background;
    if (!granted) return WeightImportOutcome.optionalDenied;
    return runner.refresh(force: true);
  }

  @override
  Widget build(BuildContext c) {
    if (!runner.supported) return const SizedBox.shrink();
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final local = _lastSuccess?.toLocal();
    final when = local == null
        ? ''
        : '${MaterialLocalizations.of(c).formatMediumDate(local)} '
              '${MaterialLocalizations.of(c).formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
    final outcome = _accessKnown && !_access.available
        ? WeightImportOutcome.unavailable
        : _enabled && _accessKnown && !_access.weight
        ? WeightImportOutcome.denied
        : _outcome;
    final status = switch (outcome) {
      WeightImportOutcome.optionalDenied =>
        l?.weightOptionalDenied ??
            'This optional access was not granted. Weight can still refresh while the app is open.',
      WeightImportOutcome.denied =>
        l?.weightImportDenied ??
            'Weight access was denied or removed. Your saved history is still here.',
      WeightImportOutcome.failed =>
        l?.weightImportFailed ??
            'Weight could not be imported. Your saved history is still here. Try Refresh.',
      WeightImportOutcome.unavailable =>
        l?.weightImportUnavailable ??
            'Health Connect is unavailable on this device.',
      _ => null,
    };
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              l?.weightAutoImport ?? 'Import weight automatically',
              style: F.body.copyWith(color: p.ink),
            ),
            subtitle: Text(
              l?.weightAutoImportBody ??
                  'Read scale entries from Health Connect. Imported readings stay separate from your journal and show their source.',
              style: F.over.copyWith(color: p.ink2),
            ),
            value: _enabled,
            onChanged: !_loaded || _busy
                ? null
                : (on) => _run(() => runner.setEnabled(on)),
          ),
          const SizedBox(height: S.x3),
          Text(
            local == null
                ? (l?.weightImportNever ?? 'No successful import yet')
                : (l?.weightLastImport(when) ??
                      'Last successful import: $when'),
            style: F.cap.copyWith(color: p.ink3),
          ),
          if (_enabled) ...[
            const SizedBox(height: S.x3),
            BigButton(
              l?.weightRefresh ?? 'Refresh',
              soft: true,
              onTap: _busy
                  ? null
                  : () => _run(
                      () => _access.weight
                          ? runner.refresh(force: true)
                          : runner.setEnabled(true),
                    ),
            ),
            if (_access.backgroundAvailable) ...[
              const SizedBox(height: S.x4),
              Text(
                l?.weightBackgroundReadBody ??
                    'Health Connect asks separately for background access. You can also refresh when the app is open.',
                style: F.over.copyWith(color: p.ink2),
              ),
              const SizedBox(height: S.x2),
              BigButton(
                l?.weightBackgroundRead ?? 'Allow daily background import',
                soft: true,
                onTap: _busy || _access.background
                    ? null
                    : () => _run(() => _optional('background')),
              ),
            ],
            if (_access.historyAvailable) ...[
              const SizedBox(height: S.x4),
              Text(
                l?.weightHistoryReadBody ??
                    'Health Connect asks separately for readings older than 30 days.',
                style: F.over.copyWith(color: p.ink2),
              ),
              const SizedBox(height: S.x2),
              BigButton(
                l?.weightHistoryRead ?? 'Allow older weight history',
                soft: true,
                onTap: _busy || _access.history
                    ? null
                    : () => _run(() => _optional('history')),
              ),
            ],
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: S.x3),
              child: Center(child: MotionLoadingIndicator()),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: S.x3),
              child: Text(status, style: F.over.copyWith(color: p.ink2)),
            ),
        ],
      ),
    );
  }
}
