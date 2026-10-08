import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/db.dart';
import '../sync/reset_gate.dart';

/// User preferences only. None of these fields is a health measurement.
class CoachPreferences {
  const CoachPreferences({
    this.focus = 'general',
    this.replyLength = 'balanced',
    this.customInstructions = '',
    this.memoryEnabled = false,
  });
  final String focus, replyLength, customInstructions;
  final bool memoryEnabled;
  Map<String, Object?> row(String owner) => {
    'owner': owner,
    'focus': focus,
    'reply_length': replyLength,
    'custom_instructions': customInstructions,
    'memory_enabled': memoryEnabled ? 1 : 0,
  };
  static CoachPreferences fromRow(Map<String, Object?> r) => CoachPreferences(
    focus: r['focus'] as String? ?? 'general',
    replyLength: r['reply_length'] as String? ?? 'balanced',
    customInstructions: r['custom_instructions'] as String? ?? '',
    memoryEnabled: r['memory_enabled'] == 1,
  );
}

class CoachMemory {
  const CoachMemory(this.id, this.text);
  final String id, text;
}

/// Durable local conversations. The provider key is deliberately absent.
class CoachStore {
  // Persistence and search policies remain active under reduced motion.
  static const draftSaveDebounce = Duration(milliseconds: 350);
  static const searchDebounce = Duration(milliseconds: 200);
  CoachStore(this.db, this.owner) : _generation = _generations[db] ?? 0;
  final Database db;
  final String owner;
  final int _generation;
  static final _generations = Expando<int>();
  static final _resetListeners = Expando<Set<Future<void> Function()>>();
  void addResetListener(Future<void> Function() listener) =>
      (_resetListeners[db] ??= {}).add(listener);
  void removeResetListener(Future<void> Function() listener) =>
      _resetListeners[db]?.remove(listener);
  void _checkWritable() {
    if (ResetGate.active || _generation != (_generations[db] ?? 0)) {
      throw StateError('Coach data was deleted');
    }
  }

  static Future<void> beforeReset(Database db) async {
    _generations[db] = (_generations[db] ?? 0) + 1;
    for (final listener in [...?_resetListeners[db]]) {
      await listener();
    }
  }

  static int _serial = 0;
  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_serial++}';
  static Future<CoachStore> open(String owner) async =>
      CoachStore(await LocalDb.instance, owner);

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS coach_chat ('
      'owner TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, '
      'created_ms INTEGER NOT NULL, updated_ms INTEGER NOT NULL, preview TEXT NOT NULL, '
      'search_text TEXT NOT NULL, history_json TEXT NOT NULL, transcript_json TEXT NOT NULL, '
      'draft TEXT NOT NULL DEFAULT \'\', scroll_offset REAL NOT NULL DEFAULT 0, '
      'retry_json TEXT, PRIMARY KEY(owner,id))',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS coach_chat_recent ON coach_chat(owner,updated_ms DESC)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS coach_preferences ('
      'owner TEXT PRIMARY KEY NOT NULL, focus TEXT NOT NULL, reply_length TEXT NOT NULL, '
      'custom_instructions TEXT NOT NULL, memory_enabled INTEGER NOT NULL DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS coach_legacy ('
      'owner TEXT NOT NULL, filename TEXT NOT NULL, raw_json TEXT NOT NULL, error TEXT NOT NULL, '
      'PRIMARY KEY(owner,filename))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS coach_memory ('
      'owner TEXT NOT NULL, id TEXT NOT NULL, text TEXT NOT NULL, updated_ms INTEGER NOT NULL, '
      'PRIMARY KEY(owner,id))',
    );
  }

  Future<List<Map<String, Object?>>> list({String search = ''}) => db.query(
    'coach_chat',
    columns: ['id', 'title', 'updated_ms', 'preview'],
    where:
        'owner = ?${search.trim().isEmpty ? '' : ' AND instr(search_text, ?) > 0'}',
    whereArgs: [
      owner,
      if (search.trim().isNotEmpty) search.trim().toLowerCase(),
    ],
    orderBy: 'updated_ms DESC',
  );
  Future<Map<String, Object?>?> read(String id) async {
    final rows = await db.query(
      'coach_chat',
      where: 'owner = ? AND id = ?',
      whereArgs: [owner, id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> save(Map<String, Object?> row) async {
    _checkWritable();
    final normalized = await _normalizeSearchOffThread(row);
    _checkWritable();
    await db.insert('coach_chat', {
      ...normalized,
      'owner': owner,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, Object?>> _normalizeSearchOffThread(
    Map<String, Object?> row,
  ) => Isolate.run(
    () => {...row, 'search_text': (row['search_text'] as String).toLowerCase()},
  );
  Future<void> delete(String id) => _serializedLegacy(db, () async {
    _checkWritable();
    final filename = 'coach_s_${owner}_$id.json';
    // A retained conflicting original belongs to this same chat identity.
    // Explicit deletion must remove it too, or the next migration resurrects it.
    try {
      final dir = await getApplicationDocumentsDirectory();
      _checkWritable();
      if (await dir.exists()) {
        await for (final entry in dir.list()) {
          if (entry is File && p.basename(entry.path) == filename) {
            _checkWritable();
            await entry.delete();
          }
        }
      }
    } on MissingPluginException {
      // Database-only callers have no legacy documents directory.
    }
    _checkWritable();
    await db.transaction((txn) async {
      await txn.delete(
        'coach_legacy',
        where: 'owner = ? AND filename = ?',
        whereArgs: [owner, filename],
      );
      await txn.delete(
        'coach_chat',
        where: 'owner = ? AND id = ?',
        whereArgs: [owner, id],
      );
    });
  });

  Future<void> rename(String id, String title) async {
    _checkWritable();
    final t = title.trim();
    if (t.isEmpty || t.length > 120) {
      throw ArgumentError('Chat title must be 1–120 characters');
    }
    // One SQL statement changes only the title, leaving an arriving transcript
    // or draft intact. Keep the current search body after its first newline.
    await db.rawUpdate(
      'UPDATE coach_chat SET title = ?, search_text = ? || char(10) || '
      'substr(search_text, instr(search_text,char(10)) + 1) WHERE owner = ? AND id = ?',
      [t, t.toLowerCase(), owner, id],
    );
  }

  Future<CoachPreferences> preferences() async {
    final rows = await db.query(
      'coach_preferences',
      where: 'owner = ?',
      whereArgs: [owner],
    );
    return rows.isEmpty
        ? const CoachPreferences()
        : CoachPreferences.fromRow(rows.first);
  }

  Future<void> savePreferences(CoachPreferences prefs) async {
    _checkWritable();
    if (prefs.customInstructions.length > 2000 ||
        !const {
          'general',
          'sleep',
          'training',
          'recovery',
        }.contains(prefs.focus) ||
        !const {'brief', 'balanced', 'detailed'}.contains(prefs.replyLength)) {
      throw ArgumentError('Invalid Coach preferences');
    }
    await db.insert(
      'coach_preferences',
      prefs.row(owner),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<CoachMemory>> memories() async => [
    for (final r in await db.query(
      'coach_memory',
      where: 'owner = ?',
      whereArgs: [owner],
      orderBy: 'updated_ms DESC',
    ))
      CoachMemory(r['id'] as String, r['text'] as String),
  ];

  /// Called only after a native confirmation or the user's explicit Save.
  Future<void> saveMemory(String text, {String? id}) async {
    _checkWritable();
    final t = text.trim();
    if (t.isEmpty || t.length > 500) {
      throw ArgumentError('Preference must be 1–500 characters');
    }
    await db.transaction((txn) async {
      _checkWritable();
      final rows = await txn.rawQuery(
        'SELECT COUNT(*) AS n FROM coach_memory WHERE owner = ?',
        [owner],
      );
      if (id == null && (rows.first['n'] as num).toInt() >= 30) {
        throw StateError('Keep at most 30 preferences');
      }
      _checkWritable();
      await txn.insert('coach_memory', {
        'owner': owner,
        'id': id ?? newId(),
        'text': t,
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> removeMemory(String id) async {
    _checkWritable();
    await db.delete(
      'coach_memory',
      where: 'owner = ? AND id = ?',
      whereArgs: [owner, id],
    );
  }

  Future<List<String>> migrateLegacy({Directory? directory}) =>
      migrateAllLegacy(db, directory: directory, onlyOwner: owner);
  static final _legacyQueues = Expando<Future<void>>();
  static Future<T> _serializedLegacy<T>(
    Database db,
    Future<T> Function() operation,
  ) {
    final result = (_legacyQueues[db] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    _legacyQueues[db] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// File parsing/encoding is off the UI isolate. Healthy chats keep migrating
  /// when a source is damaged. Exact unreadable JSON is retained in the backed
  /// up legacy ledger as well as in its original file, with a visible warning.
  static Future<List<String>> migrateAllLegacy(
    Database db, {
    Directory? directory,
    String? onlyOwner,
  }) => _serializedLegacy(
    db,
    () => _migrate(db, directory: directory, onlyOwner: onlyOwner),
  );
  static Future<List<String>> _migrate(
    Database db, {
    Directory? directory,
    String? onlyOwner,
  }) async {
    final generation = _generations[db] ?? 0;
    void checkReset() {
      if (ResetGate.active || generation != (_generations[db] ?? 0)) {
        throw StateError('Coach data was deleted');
      }
    }

    checkReset();
    final dir = directory ?? await getApplicationDocumentsDirectory();
    checkReset();
    if (!await dir.exists()) return [];
    final indexes = <File>[], issues = <String>[];
    final unverified = <String>{};
    var batch = 0;
    await for (final entry in dir.list()) {
      checkReset();
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('coach_idx_') && name.endsWith('.json')) {
        if (onlyOwner == null || name == 'coach_idx_$onlyOwner.json') {
          indexes.add(entry);
        }
        continue;
      }
      if (!name.startsWith('coach_s_') || !name.endsWith('.json')) continue;
      final stem = name.substring(8, name.length - 5),
          split = stem.lastIndexOf('_');
      if (split <= 0) continue;
      final owner = stem.substring(0, split), id = stem.substring(split + 1);
      if (onlyOwner != null && owner != onlyOwner) continue;
      final path = entry.path;
      final parsed = await Isolate.run(() => _parseLegacy(path, id));
      checkReset();
      final row = parsed['row'] as Map<String, Object?>?;
      var error = parsed['error'] as String?;
      final store = CoachStore(db, owner);
      if (row != null) {
        final existing = await store.read(id);
        if (existing == null) await store.save(row);
        final verified = await store.read(id);
        if (verified?['history_json'] == row['history_json'] &&
            verified?['transcript_json'] == row['transcript_json'] &&
            verified?['draft'] == row['draft']) {
          checkReset();
          await db.delete(
            'coach_legacy',
            where: 'owner = ? AND filename = ?',
            whereArgs: [owner, name],
          );
          await entry.delete();
        } else {
          error =
              'A conversation with this ID contains different data; the original was retained.';
        }
      }
      if (error != null) {
        checkReset();
        issues.add(name);
        unverified.add(owner);
        await db.insert('coach_legacy', {
          'owner': owner,
          'filename': name,
          'raw_json': parsed['raw'] ?? '',
          'error': error,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (++batch == 8) {
        batch = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    for (final file in indexes) {
      final owner = p
          .basename(file.path)
          .substring(10, p.basename(file.path).length - 5);
      if (!unverified.contains(owner) && await file.exists()) {
        await file.delete();
      }
    }
    return issues;
  }

  static Map<String, Object?> _parseLegacy(String path, String id) {
    String raw = '';
    try {
      raw = File(path).readAsStringSync();
      final j = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final history = j['history'] as List? ?? [],
          transcript = j['transcript'] as List? ?? [];
      if (history.any((e) => e is! Map) || transcript.any((e) => e is! Map)) {
        throw const FormatException('Invalid conversation entries');
      }
      final title = (j['title'] ?? '').toString();
      final texts = transcript
          .cast<Map>()
          .map((r) => (r['text'] ?? '').toString())
          .join('\n');
      return {
        'raw': raw,
        'row': <String, Object?>{
          'id': id,
          'title': title,
          'created_ms': (j['createdAt'] as num?)?.toInt() ?? 0,
          'updated_ms':
              (j['updatedAt'] as num?)?.toInt() ??
              File(path).statSync().modified.millisecondsSinceEpoch,
          'preview': texts.length > 80
              ? texts.substring(texts.length - 80)
              : texts,
          'search_text': '$title\n$texts',
          'history_json': jsonEncode(history),
          'transcript_json': jsonEncode(transcript),
          'draft': (j['draft'] ?? '').toString(),
          'scroll_offset': (j['scrollOffset'] as num?)?.toDouble() ?? 0,
        },
      };
    } catch (e) {
      return {'raw': raw, 'error': '$e'};
    }
  }

  static Future<void> deleteLegacy(Database db, {Directory? directory}) =>
      _serializedLegacy(db, () async {
        final Directory dir;
        try {
          dir = directory ?? await getApplicationDocumentsDirectory();
        } on MissingPluginException {
          return;
        }
        if (!await dir.exists()) return;
        await for (final entry in dir.list()) {
          final name = p.basename(entry.path);
          if (entry is File &&
              name.endsWith('.json') &&
              (name.startsWith('coach_s_') || name.startsWith('coach_idx_'))) {
            await entry.delete();
          }
        }
      });
}
