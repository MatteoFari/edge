import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/weight_store.dart';
import 'package:openstrap_edge/health/health_weight_import.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Bridge implements WeightBridge {
  WeightAccess access = const WeightAccess(
    available: true,
    weight: true,
    background: true,
  );
  int reads = 0, requests = 0;
  Future<WeightAccess> Function(String)? requestFn;
  final snapshots = <bool>[];
  final tokens = <String?>[];
  final scheduled = <bool>[];
  Future<Map<dynamic, dynamic>> Function()? readFn;
  @override
  Future<WeightAccess> status() async => access;
  @override
  Future<WeightAccess> request(String kind) async {
    requests++;
    return requestFn == null ? access : requestFn!(kind);
  }

  @override
  Future<void> schedule(bool enabled) async {
    scheduled.add(enabled);
  }

  @override
  Future<Map<dynamic, dynamic>> read({
    String? token,
    bool snapshot = false,
  }) async {
    reads++;
    snapshots.add(snapshot);
    tokens.add(token);
    return readFn == null ? payload() : readFn!();
  }
}

Map<dynamic, dynamic> payload({
  String token = 'next',
  List<Map<String, Object?>>? records,
  List<String> deleted = const [],
}) => {
  'records':
      records ??
      [
        WeightReading(
          id: 'r1',
          time: _readingDate,
          kg: 71,
          source: 'Scale app',
          sourceId: 'scale.app',
        ).toRow(),
      ],
  'deleted': deleted,
  'token': token,
  'historyGranted': false,
  'snapshotStartMs': DateTime(2026, 9, 8).millisecondsSinceEpoch,
  'snapshotEndMs': DateTime(2026, 10, 8).millisecondsSinceEpoch,
};
final _readingDate = DateTime(2026, 10, 7);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late _Bridge bridge;
  late WeightImportRunner runner;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    HeadlessSyncGate.resetForTest();
    ResetGate.resetForTest();
    SharedPreferences.setMockInitialValues({});
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await WeightStore.create(db);
    bridge = _Bridge();
    runner = WeightImportRunner(
      bridge: bridge,
      openDb: () async => db,
      now: () => DateTime(2026, 10, 8),
    );
  });
  tearDown(() async {
    await db.close();
    HeadlessSyncGate.resetForTest();
    ResetGate.resetForTest();
  });

  Future<void> enable() async => (await SharedPreferences.getInstance())
      .setBool(kAutoWeightImportPref, true);

  test(
    'defaults off and never asks or reads on foreground/background wake',
    () async {
      expect(await runner.enabled(), isFalse);
      expect(await runner.refresh(), WeightImportOutcome.disabled);
      expect(await runner.background(), isTrue);
      expect(bridge.requests, 0);
      expect(bridge.reads, 0);
    },
  );

  test(
    'enabling requests weight permission only on tap and denial leaves off',
    () async {
      bridge.access = const WeightAccess(available: true);
      expect(await runner.setEnabled(true), WeightImportOutcome.denied);
      expect(await runner.enabled(), isFalse);
      expect(bridge.reads, 0);
      bridge.access = const WeightAccess(available: true, weight: true);
      expect(await runner.setEnabled(true), WeightImportOutcome.success);
      expect(await runner.enabled(), isTrue);
      expect(bridge.requests, 2);
      expect(bridge.scheduled, [true]);
    },
  );

  test(
    'disabling during a permission request prevents re-enabling after reset',
    () async {
      final granted = Completer<WeightAccess>();
      bridge.requestFn = (_) => granted.future;
      final enabling = runner.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      await runner.disableAndWait();
      granted.complete(bridge.access);
      expect(await enabling, WeightImportOutcome.disabled);
      expect(await runner.enabled(), isFalse);
      expect(bridge.reads, 0);
    },
  );

  test(
    'restore pause cancels old read, preserves opt-in, and clears throttle',
    () async {
      await enable();
      final response = Completer<Map<dynamic, dynamic>>();
      bridge.readFn = () => response.future;
      final importing = runner.refresh();
      while (bridge.reads == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      var restored = false;
      final restore = runner.pauseWhile(() async {
        restored = true;
      });
      response.complete(payload());
      expect(await importing, WeightImportOutcome.disabled);
      await restore;
      expect(restored, isTrue);
      expect(await runner.enabled(), isTrue);
      expect(await db.query('imported_weight'), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getInt(kWeightImportAttemptMs),
        isNull,
      );
    },
  );

  test(
    'unpaired daily background import runs through gate and retries a busy wake',
    () async {
      await enable();
      final release = Completer<void>();
      final held = HeadlessSyncGate.tryRun('ble', () => release.future);
      expect(await runner.background(), isFalse);
      expect(bridge.reads, 0);
      release.complete();
      await held;
      expect(await runner.background(), isTrue);
      expect(bridge.reads, 1);
      expect(HeadlessSyncGate.busy, isFalse);
      expect(await db.query('imported_weight'), hasLength(1));
    },
  );

  test(
    'background denial skips nonprompting while a foreground refresh still works',
    () async {
      await enable();
      bridge.access = const WeightAccess(available: true, weight: true);
      expect(await runner.background(), isTrue);
      expect(bridge.reads, 0);
      expect(await runner.refresh(), WeightImportOutcome.success);
      expect(bridge.requests, 0);
    },
  );

  test(
    'foreground throttle applies after empty successful reads, Refresh bypasses',
    () async {
      await enable();
      bridge.readFn = () async => payload(records: []);
      expect(await runner.refresh(), WeightImportOutcome.success);
      expect(await runner.refresh(), WeightImportOutcome.throttled);
      expect(await runner.refresh(force: true), WeightImportOutcome.success);
      expect(bridge.reads, 2);
      expect(
        (await WeightStore(db).syncState())!['last_success_ms'],
        isNotNull,
      );
    },
  );

  test(
    'permission removal/read failure preserve history and successful cursor',
    () async {
      await enable();
      await runner.refresh();
      bridge.access = const WeightAccess(available: true);
      expect(await runner.refresh(force: true), WeightImportOutcome.denied);
      bridge.access = const WeightAccess(available: true, weight: true);
      bridge.readFn = () async =>
          throw PlatformException(code: 'permission_denied');
      expect(await runner.refresh(force: true), WeightImportOutcome.denied);
      bridge.readFn = () async => throw StateError('store locked');
      expect(await runner.refresh(force: true), WeightImportOutcome.failed);
      expect(await db.query('imported_weight'), hasLength(1));
      expect((await WeightStore(db).syncState())!['token'], 'next');
    },
  );

  test(
    'expired tokens recover by complete snapshot without duplicates',
    () async {
      await enable();
      await runner.refresh();
      var expired = true;
      bridge.readFn = () async {
        if (expired) {
          expired = false;
          return {'expired': true};
        }
        return payload(token: 'fresh');
      };
      expect(await runner.refresh(force: true), WeightImportOutcome.success);
      expect(bridge.snapshots, [true, false, true]);
      expect(bridge.tokens, [null, 'next', null]);
      expect(await db.query('imported_weight'), hasLength(1));
      expect((await WeightStore(db).syncState())!['token'], 'fresh');
    },
  );

  test(
    'partial snapshot failures never reconcile away existing history',
    () async {
      await enable();
      await runner.refresh();
      bridge.access = const WeightAccess(
        available: true,
        weight: true,
        history: true,
      );
      bridge.readFn = () async => {
        'records': [],
        'deleted': [],
        'token': 'incomplete',
      };
      expect(await runner.refresh(force: true), WeightImportOutcome.failed);
      expect(await db.query('imported_weight'), hasLength(1));
      expect((await WeightStore(db).syncState())!['token'], 'next');
    },
  );

  test(
    'concurrent imports coalesce; disable waits and cancels the pending save',
    () async {
      await enable();
      final response = Completer<Map<dynamic, dynamic>>();
      bridge.readFn = () => response.future;
      final first = runner.refresh();
      final second = runner.refresh(force: true);
      expect(identical(first, second), isTrue);
      while (bridge.reads == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final disable = runner.disableAndWait();
      response.complete(payload());
      expect(await first, WeightImportOutcome.disabled);
      await disable;
      expect(await db.query('imported_weight'), isEmpty);
      expect(await WeightStore(db).syncState(), isNull);
      expect(bridge.scheduled, [false]);
    },
  );

  test(
    'reset refuses a completed source read and clears the gate on failure',
    () async {
      await enable();
      bridge.readFn = () async {
        ResetGate.enter();
        return payload();
      };
      expect(await runner.refresh(), WeightImportOutcome.disabled);
      expect(await db.query('imported_weight'), isEmpty);
      ResetGate.leave();
      bridge.readFn = () async => throw StateError('read failed');
      expect(await runner.background(), isTrue); // prior attempt is throttled
      expect(HeadlessSyncGate.busy, isFalse);
    },
  );

  test(
    'invalid edited reading drops its previous value instead of clamping it',
    () async {
      await enable();
      await runner.refresh();
      bridge.readFn = () async => payload(
        records: [
          {
            'record_id': 'r1',
            'time_ms': DateTime(2026, 10, 7).millisecondsSinceEpoch,
            'kg': double.nan,
            'source': 'Scale app',
            'source_id': 'scale.app',
          },
        ],
      );
      expect(await runner.refresh(force: true), WeightImportOutcome.success);
      expect(await db.query('imported_weight'), isEmpty);
    },
  );
}
