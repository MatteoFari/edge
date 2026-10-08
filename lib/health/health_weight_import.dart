import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../data/db.dart';
import '../data/weight_store.dart';
import '../sync/headless_gate.dart';
import '../sync/reset_gate.dart';

const kAutoWeightImportPref = 'health_auto_import_weight';
const kWeightImportAttemptMs = 'health_weight_import_attempt_ms';
const kWeightImportStatus = 'health_weight_import_status';
const kWeightImportInterval = Duration(hours: 6);

class WeightAccess {
  const WeightAccess({
    this.available = false,
    this.weight = false,
    this.backgroundAvailable = false,
    this.background = false,
    this.historyAvailable = false,
    this.history = false,
  });
  final bool available,
      weight,
      backgroundAvailable,
      background,
      historyAvailable,
      history;
  factory WeightAccess.fromMap(Map<dynamic, dynamic> map) => WeightAccess(
    available: map['available'] == true,
    weight: map['weightGranted'] == true,
    backgroundAvailable: map['backgroundAvailable'] == true,
    background: map['backgroundGranted'] == true,
    historyAvailable: map['historyAvailable'] == true,
    history: map['historyGranted'] == true,
  );
}

abstract class WeightBridge {
  Future<WeightAccess> status();
  Future<WeightAccess> request(String kind);
  Future<Map<dynamic, dynamic>> read({String? token, bool snapshot = false});
  Future<void> schedule(bool enabled);
}

class HealthConnectWeightBridge implements WeightBridge {
  static const channel = MethodChannel('openstrap/weight_import');
  @override
  Future<WeightAccess> status() async => WeightAccess.fromMap(
    await channel.invokeMapMethod<dynamic, dynamic>('status') ?? const {},
  );
  @override
  Future<WeightAccess> request(String kind) async => WeightAccess.fromMap(
    await channel.invokeMapMethod<dynamic, dynamic>('request', {
          'kind': kind,
        }) ??
        const {},
  );
  @override
  Future<Map<dynamic, dynamic>> read({
    String? token,
    bool snapshot = false,
  }) async =>
      await channel.invokeMapMethod<dynamic, dynamic>('read', {
        'token': token,
        'snapshot': snapshot,
      }) ??
      (throw StateError('Empty weight response'));
  @override
  Future<void> schedule(bool enabled) =>
      channel.invokeMethod<void>('schedule', {'enabled': enabled});
}

enum WeightImportOutcome {
  success,
  disabled,
  throttled,
  denied,
  optionalDenied,
  unavailable,
  failed,
  busy,
}

/// One in-flight import in the shared engine. Foreground opens are throttled;
/// Refresh is explicit. Nothing here depends on a paired band or AppState.
class WeightImportRunner {
  WeightImportRunner({
    required this.bridge,
    required this.openDb,
    this.supported = true,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final WeightBridge bridge;
  final Future<Database> Function() openDb;
  final bool supported;
  final DateTime Function() now;
  Future<WeightImportOutcome>? _running;
  int _generation = 0;
  int _pauses = 0;

  Future<bool> enabled() async =>
      supported &&
      ((await SharedPreferences.getInstance()).getBool(kAutoWeightImportPref) ??
          false);

  Future<WeightImportOutcome> setEnabled(bool enabled) async {
    if (!enabled) {
      await disableAndWait();
      return WeightImportOutcome.disabled;
    }
    if (!supported) return WeightImportOutcome.unavailable;
    final generation = _generation;
    final access = await bridge.request('weight');
    if (generation != _generation || ResetGate.active || _pauses > 0) {
      return WeightImportOutcome.disabled;
    }
    if (!access.available) return WeightImportOutcome.unavailable;
    if (!access.weight) return WeightImportOutcome.denied;
    await (await SharedPreferences.getInstance()).setBool(
      kAutoWeightImportPref,
      true,
    );
    await bridge.schedule(true);
    return refresh(force: true);
  }

  Future<void> disableAndWait() async {
    _generation++;
    await (await SharedPreferences.getInstance()).setBool(
      kAutoWeightImportPref,
      false,
    );
    try {
      if (supported) await bridge.schedule(false);
    } catch (error) {
      debugPrint('[weight_import] cancel schedule: $error');
    }
    await _running;
  }

  Future<T> pauseWhile<T>(Future<T> Function() body) async {
    _generation++;
    _pauses++;
    try {
      await _running;
      final result = await body();
      // The next foreground read must reconcile restored records, even when
      // the previous automatic pass was inside the throttle interval.
      await (await SharedPreferences.getInstance()).remove(
        kWeightImportAttemptMs,
      );
      return result;
    } finally {
      _pauses--;
    }
  }

  Future<WeightAccess> requestOptional(String kind) async {
    final access = await bridge.request(kind);
    await bridge.schedule(await enabled());
    return access;
  }

  Future<WeightImportOutcome> refresh({bool force = false}) {
    if (_running case final running?) return running;
    final generation = _generation;
    final work = _refresh(force, generation);
    _running = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_running, work)) _running = null;
      }),
    );
    return work;
  }

  Future<WeightImportOutcome> _refresh(bool force, int generation) async {
    WeightImportOutcome result;
    try {
      if (!supported) return WeightImportOutcome.unavailable;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (!await enabled() || ResetGate.active || _pauses > 0) {
        return WeightImportOutcome.disabled;
      }
      final access = await bridge.status();
      if (!access.available) {
        result = WeightImportOutcome.unavailable;
      } else if (!access.weight) {
        result = WeightImportOutcome.denied;
      } else {
        final at = now();
        final last = prefs.getInt(kWeightImportAttemptMs);
        if (!force &&
            last != null &&
            at.millisecondsSinceEpoch >= last &&
            at.difference(DateTime.fromMillisecondsSinceEpoch(last)) <
                kWeightImportInterval) {
          return WeightImportOutcome.throttled;
        }
        await prefs.setInt(kWeightImportAttemptMs, at.millisecondsSinceEpoch);
        final store = WeightStore(await openDb());
        final state = await store.syncState();
        var snapshot =
            state == null || access.history != (state['history_granted'] == 1);
        var payload = await bridge.read(
          token: state?['token'] as String?,
          snapshot: snapshot,
        );
        if (payload['expired'] == true) {
          snapshot = true;
          payload = await bridge.read(snapshot: true);
        }
        if (payload['expired'] == true) {
          throw StateError('Expired replacement token');
        }
        final raw = payload['records'];
        final deletes = payload['deleted'];
        final token = payload['token'];
        if (raw is! List ||
            deletes is! List ||
            token is! String ||
            token.isEmpty) {
          throw StateError('Incomplete weight response');
        }
        if (snapshot &&
            (payload['snapshotStartMs'] is! num ||
                payload['snapshotEndMs'] is! num)) {
          throw StateError('Incomplete weight snapshot');
        }
        final readings = <WeightReading>[];
        final deleted = deletes.whereType<String>().toList();
        for (final row in raw) {
          if (row is! Map) throw StateError('Invalid weight record');
          final reading = WeightReading.fromRow(row);
          if (reading != null) {
            readings.add(reading);
          } else if (row['record_id'] case final String id when id.isNotEmpty) {
            // An edit to an invalid value must not leave the stale valid
            // value displayed. Drop it, without fabricating a replacement.
            deleted.add(id);
          }
        }
        if (generation != _generation || ResetGate.active || !await enabled()) {
          return WeightImportOutcome.disabled;
        }
        await store.apply(
          readings: readings,
          deleted: deleted,
          token: token,
          successfulAt: now(),
          historyGranted: payload['historyGranted'] == true,
          snapshotStartMs: (payload['snapshotStartMs'] as num?)?.toInt(),
          snapshotEndMs: (payload['snapshotEndMs'] as num?)?.toInt(),
          canWrite: () =>
              generation == _generation && !ResetGate.active && _pauses == 0,
        );
        result = WeightImportOutcome.success;
      }
    } on PlatformException catch (error) {
      result = error.code == 'permission_denied'
          ? WeightImportOutcome.denied
          : WeightImportOutcome.failed;
    } catch (error) {
      debugPrint('[weight_import] failed: $error');
      result = generation != _generation || ResetGate.active
          ? WeightImportOutcome.disabled
          : WeightImportOutcome.failed;
    }
    try {
      await (await SharedPreferences.getInstance()).setString(
        kWeightImportStatus,
        result.name,
      );
    } catch (_) {
      /* status must never turn a successful save into a failure */
    }
    return result;
  }

  Future<bool> background() async {
    if (!supported || ResetGate.active || !await enabled()) return true;
    try {
      final access = await bridge.status();
      if (!access.weight || !access.background) return true;
      final result = await HeadlessSyncGate.tryRun(
        'weight-import',
        () => refresh(),
      );
      return result != null && result != WeightImportOutcome.failed;
    } catch (_) {
      return false;
    }
  }
}

class AutoWeightImport {
  AutoWeightImport._();
  static bool _started = false;
  static final runner = WeightImportRunner(
    bridge: HealthConnectWeightBridge(),
    openDb: () => LocalDb.instance,
    supported: Platform.isAndroid,
  );

  /// Register once on the existing engine, including headless launches.
  /// Native WorkManager wakes never create a separate Dart isolate.
  static Future<void> start() async {
    if (!Platform.isAndroid || _started) return;
    HealthConnectWeightBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'backgroundImport') return runner.background();
      throw MissingPluginException('Unknown weight import callback');
    });
    try {
      await HealthConnectWeightBridge.channel.invokeMethod<void>('ready');
      await runner.bridge.schedule(await runner.enabled());
      _started = true;
    } catch (error) {
      debugPrint('[weight_import] startup: $error');
      try {
        await (await SharedPreferences.getInstance()).setString(
          kWeightImportStatus,
          WeightImportOutcome.failed.name,
        );
      } catch (_) {}
    }
  }

  static Future<void> onForeground() async {
    await runner.refresh();
  }

  static Future<void> disableAndWait() => runner.disableAndWait();
  static Future<T> pauseWhile<T>(Future<T> Function() body) =>
      runner.pauseWhile(body);
}
