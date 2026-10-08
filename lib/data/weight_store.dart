import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'day_label.dart';

/// Weight is display-only. This ledger is deliberately separate from profile
/// weight and journal_metric, neither calorie nor recovery inputs read it.
class WeightReading {
  const WeightReading({
    required this.id,
    required this.time,
    required this.kg,
    required this.source,
    required this.sourceId,
    this.manual = false,
  });

  final String id, source, sourceId;
  final DateTime time;
  final double kg;
  final bool manual;
  String get day => dayLabelOf(time.toLocal());

  static WeightReading? fromRow(Map<dynamic, dynamic> row) {
    final id = row['record_id'];
    final ms = row['time_ms'];
    final kg = row['kg'];
    final source = row['source'];
    final origin = row['source_id'];
    if (id is! String ||
        id.isEmpty ||
        ms is! num ||
        !ms.isFinite ||
        ms.abs() > 8640000000000000 ||
        kg is! num ||
        !kg.isFinite ||
        kg <= 0 ||
        kg > 1000 ||
        source is! String ||
        source.trim().isEmpty ||
        origin is! String ||
        origin.isEmpty) {
      return null;
    }
    return WeightReading(
      id: id,
      time: DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
      kg: kg.toDouble(),
      source: source,
      sourceId: origin,
    );
  }

  Map<String, Object?> toRow() => {
    'record_id': id,
    'time_ms': time.millisecondsSinceEpoch,
    'kg': kg,
    'source': source,
    'source_id': sourceId,
  };
}

/// Latest valid record per local calendar day. A valid manual entry always
/// wins, without deleting or changing any readings from other sources.
Map<String, WeightReading> weightReadingsByDay(
  Iterable<WeightReading> imported,
  Iterable<WeightReading> manual,
) {
  final out = <String, WeightReading>{};
  for (final row in [...imported, ...manual]) {
    if (!row.kg.isFinite || row.kg <= 0) continue;
    final old = out[row.day];
    if (old == null ||
        (!old.manual && row.manual) ||
        old.manual == row.manual &&
            (row.time.isAfter(old.time) ||
                row.time == old.time && row.id.compareTo(old.id) > 0)) {
      out[row.day] = row;
    }
  }
  return Map.fromEntries(
    out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

class WeightStore {
  const WeightStore(this.db);
  final Database db;

  static final _changes = ValueNotifier<int>(0);

  /// One shared invalidation signal for committed manual/imported weight data.
  /// Writers publish only after their transaction succeeds.
  static ValueListenable<int> get changes => _changes;
  static void notifyCommitted() => _changes.value++;

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS imported_weight (
      record_id TEXT PRIMARY KEY, time_ms INTEGER NOT NULL,
      kg REAL NOT NULL, source TEXT NOT NULL, source_id TEXT NOT NULL
    )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imported_weight_time '
      'ON imported_weight(time_ms)',
    );
    // Device-specific Health Connect tokens are scratch state, never restored
    // from another phone's backup. The readings themselves are durable.
    await db.execute('''CREATE TABLE IF NOT EXISTS weight_import_sync (
      id INTEGER PRIMARY KEY CHECK(id = 1), token TEXT,
      last_success_ms INTEGER, history_granted INTEGER NOT NULL DEFAULT 0
    )''');
  }

  Future<Map<String, Object?>?> syncState() async {
    final rows = await db.query('weight_import_sync', where: 'id = 1');
    return rows.isEmpty ? null : rows.first;
  }

  /// The latest known day may predate the chart window. Keep its date/source
  /// visible without expanding or filling the plotted window.
  Future<WeightReading?> latest() async {
    final imported = await db.query(
      'imported_weight',
      orderBy: 'time_ms DESC, record_id DESC',
      limit: 1,
    );
    final manual = await db.query(
      'journal_metric',
      where: 'field = ? AND value > 0 AND value <= ?',
      whereArgs: ['weight_kg', double.maxFinite],
      orderBy: 'date DESC',
      limit: 1,
    );
    final journal = <WeightReading>[];
    if (manual.isNotEmpty) {
      final row = manual.single;
      final date = DateTime.tryParse('${row['date']}');
      final kg = row['value'] as num;
      if (date != null && kg.isFinite) {
        journal.add(
          WeightReading(
            id: 'manual:${row['date']}',
            time: date,
            kg: kg.toDouble(),
            source: '',
            sourceId: 'manual',
            manual: true,
          ),
        );
      }
    }
    final days = weightReadingsByDay(
      imported.map(WeightReading.fromRow).whereType<WeightReading>(),
      journal,
    );
    return days.isEmpty ? null : days.values.last;
  }

  /// Commit records and the next token together. A retry after a failed save
  /// repeats the same source changes, never skips unsaved edits/deletions.
  Future<void> apply({
    required List<WeightReading> readings,
    required List<String> deleted,
    required String token,
    required DateTime successfulAt,
    required bool historyGranted,
    int? snapshotStartMs,
    int? snapshotEndMs,
    bool Function()? canWrite,
  }) async {
    if (token.isEmpty) throw StateError('Missing weight changes token');
    await db.transaction((txn) async {
      if (canWrite != null && !canWrite()) throw StateError('Import cancelled');
      if (snapshotStartMs != null && snapshotEndMs != null) {
        // Only a COMPLETE, permission-checked snapshot reaches here. Rows
        // outside the readable window survive history denial/token expiry.
        await txn.delete(
          'imported_weight',
          where: 'time_ms >= ? AND time_ms < ?',
          whereArgs: [snapshotStartMs, snapshotEndMs],
        );
      }
      final batch = txn.batch();
      for (final id in deleted.toSet()) {
        batch.delete(
          'imported_weight',
          where: 'record_id = ?',
          whereArgs: [id],
        );
      }
      for (final reading in readings) {
        batch.insert(
          'imported_weight',
          reading.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      batch.insert('weight_import_sync', {
        'id': 1,
        'token': token,
        'last_success_ms': successfulAt.millisecondsSinceEpoch,
        'history_granted': historyGranted ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
      if (canWrite != null && !canWrite()) throw StateError('Import cancelled');
    });
    notifyCommitted();
  }

  Future<Map<String, WeightReading>> byDay({required DateTime since}) async {
    final first = DateTime(since.year, since.month, since.day);
    final imported = await db.query(
      'imported_weight',
      where: 'time_ms >= ?',
      whereArgs: [first.millisecondsSinceEpoch],
      orderBy: 'time_ms ASC, record_id ASC',
    );
    final journal = await db.query(
      'journal_metric',
      where: 'field = ? AND date >= ?',
      whereArgs: ['weight_kg', dayLabelOf(first)],
    );
    final manual = <WeightReading>[];
    for (final row in journal) {
      final date = DateTime.tryParse('${row['date']}');
      final kg = row['value'];
      if (date == null || kg is! num || !kg.isFinite || kg <= 0) continue;
      final minute = (row['at_min'] as num?)?.toInt() ?? 0;
      manual.add(
        WeightReading(
          id: 'manual:${row['date']}',
          time: DateTime(date.year, date.month, date.day, 0, minute),
          kg: kg.toDouble(),
          source: '',
          sourceId: 'manual',
          manual: true,
        ),
      );
    }
    return weightReadingsByDay(
      imported.map(WeightReading.fromRow).whereType<WeightReading>(),
      manual,
    );
  }
}
