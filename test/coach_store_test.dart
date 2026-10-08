import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String previousName;
  late PathProviderPlatform previousPaths;
  late Database db;
  late CoachStore store;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    dir = await Directory.systemTemp.createTemp('coach_store_');
    previousName = LocalDb.dbName;
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    LocalDb.dbName = p.join(dir.path, 'coach.db');
    db = await LocalDb.instance;
    store = CoachStore(db, 'local');
  });
  tearDown(() async {
    await LocalDb.close();
    LocalDb.dbName = previousName;
    PathProviderPlatform.instance = previousPaths;
    await dir.delete(recursive: true);
  });

  Future<File> legacy(String id, {String text = 'old message'}) async {
    final f = File(p.join(dir.path, 'coach_s_local_$id.json'));
    await f.writeAsString(
      jsonEncode({
        'title': 'Chat $id',
        'createdAt': 1,
        'updatedAt': 2,
        'history': [
          {'role': 'user', 'content': text},
        ],
        'transcript': [
          {'kind': 'user', 'text': text},
        ],
        'draft': 'draft $id',
        'scrollOffset': 42.0,
      }),
    );
    return f;
  }

  test(
    'migration preserves every conversation, draft and scroll and is idempotent',
    () async {
      for (var i = 0; i < 42; i++) {
        await legacy(
          '$i',
          text: i == 0 ? 'needle deep in the transcript' : 'text $i',
        );
      }
      await File(p.join(dir.path, 'coach_idx_local.json')).writeAsString('[]');
      await store.migrateLegacy();
      await store.migrateLegacy();
      expect(await store.list(), hasLength(42));
      expect(await store.list(search: 'needle'), hasLength(1));
      final first = await store.read('0');
      expect(first!['draft'], 'draft 0');
      expect(first['scroll_offset'], 42.0);
      expect(
        await File(p.join(dir.path, 'coach_s_local_0.json')).exists(),
        false,
      );
      expect((await CoachStore(db, 'another').list()), isEmpty);
    },
  );
  test(
    'search includes accented Italian titles and message case-insensitively',
    () async {
      await legacy('accent', text: 'Perché dormo meglio?');
      await store.migrateLegacy();
      expect(await store.list(search: 'PERCHÉ'), hasLength(1));
      await store.rename('accent', 'PERCHÉ ALLENARMI');
      expect(await store.list(search: 'perché allenarmi'), hasLength(1));
    },
  );

  test(
    'a malformed legacy source remains available and surfaces a retryable error',
    () async {
      final f = File(p.join(dir.path, 'coach_s_local_bad.json'));
      await f.writeAsString('{broken');
      expect(await store.migrateLegacy(), hasLength(1));
      expect(await f.exists(), true);
      await legacy('bad');
      await store.migrateLegacy();
      expect(await store.read('bad'), isNotNull);
    },
  );
  test(
    'corrupt and conflicting originals survive while healthy chats migrate and backups retain the raw source',
    () async {
      final bad = File(p.join(dir.path, 'coach_s_local_broken.json'));
      await bad.writeAsString('{broken');
      await legacy('healthy');
      final conflict = await legacy('conflict', text: 'original');
      await store.migrateLegacy();
      final row = await store.read('conflict');
      await store.save({
        ...row!,
        'transcript_json': '[{"kind":"user","text":"different restored chat"}]',
      });
      await conflict.writeAsString(
        jsonEncode({
          'title': 'Conflict',
          'history': [
            {'role': 'user', 'content': 'original'},
          ],
          'transcript': [
            {'kind': 'user', 'text': 'original'},
          ],
          'draft': 'draft conflict',
        }),
      );
      final issues = await store.migrateLegacy();
      expect(issues, hasLength(2));
      expect(await store.read('healthy'), isNotNull);
      expect(await conflict.exists(), true);
      expect(await bad.exists(), true);
      final backup = await LocalDb.exportCopy();
      final snapshot = await databaseFactory.openDatabase(
        backup,
        options: OpenDatabaseOptions(readOnly: true),
      );
      expect(
        (await snapshot.query(
          'coach_legacy',
          where: 'filename = ?',
          whereArgs: ['coach_s_local_broken.json'],
        )).single['raw_json'],
        '{broken',
      );
      expect(
        await snapshot.query(
          'coach_chat',
          where: 'id = ?',
          whereArgs: ['healthy'],
        ),
        hasLength(1),
      );
      await snapshot.close();
    },
  );

  test(
    'schema 60 upgrades additively and same-version repair recreates tables',
    () async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(LocalDb.dbName);
      final seed = await databaseFactory.openDatabase(
        LocalDb.dbName,
        options: OpenDatabaseOptions(version: 60, onCreate: (db, _) async {}),
      );
      await seed.close();
      LocalDb.lastRebuild = null;
      db = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);
      expect(await CoachStore(db, 'local').list(), isEmpty);
      await db.execute('DROP TABLE coach_memory');
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(await CoachStore(db, 'local').memories(), isEmpty);
    },
  );
  test(
    'backup round trip includes unvisited legacy chats, preferences and memory; reset removes originals',
    () async {
      await legacy('backup');
      await store.savePreferences(
        const CoachPreferences(
          focus: 'sleep',
          replyLength: 'brief',
          customInstructions: 'Use simple words',
          memoryEnabled: true,
        ),
      );
      await store.saveMemory('I prefer outdoor runs');
      final backup = await LocalDb.exportCopy();
      expect(await store.read('backup'), isNotNull);
      await LocalDb.wipeAll();
      store = CoachStore(db, 'local');
      expect(await store.list(), isEmpty);
      await LocalDb.importFromDbFile(backup);
      expect((await store.read('backup'))!['draft'], 'draft backup');
      expect(
        (await store.preferences()).customInstructions,
        'Use simple words',
      );
      expect((await store.memories()).single.text, 'I prefer outdoor runs');
      await legacy('deleted');
      await LocalDb.wipeAll();
      store = CoachStore(db, 'local');
      await store.migrateLegacy();
      expect(await store.list(), isEmpty);
      expect((await store.preferences()).memoryEnabled, false);
    },
  );
  test(
    'custom instructions and preference bounds reject invalid data',
    () async {
      expect((await store.preferences()).memoryEnabled, false);
      await expectLater(
        store.savePreferences(CoachPreferences(customInstructions: 'x' * 2001)),
        throwsArgumentError,
      );
      await store.savePreferences(
        CoachPreferences(customInstructions: 'x' * 2000),
      );
      expect((await store.preferences()).customInstructions.length, 2000);
      await store.savePreferences(const CoachPreferences());
      expect((await store.preferences()).customInstructions, isEmpty);
      await expectLater(store.saveMemory('x' * 501), throwsArgumentError);
    },
  );
  test(
    'reset invalidates a chat save awaiting off-isolate normalization',
    () async {
      await legacy('old-writer');
      await store.migrateLegacy();
      final row = await store.read('old-writer');
      final saving = store.save(row!);
      final rejected = expectLater(saving, throwsStateError);
      await CoachStore.beforeReset(db);
      await rejected;
      await db.delete('coach_chat');
      await expectLater(store.save(row), throwsStateError);
      expect(await CoachStore(db, 'local').list(), isEmpty);
    },
  );
  test(
    'explicit deletion also removes a retained conflicting original so it cannot resurrect',
    () async {
      final original = await legacy('delete-me');
      await store.migrateLegacy();
      final row = await store.read('delete-me');
      await store.save({...row!, 'draft': 'Newer draft'});
      await legacy('delete-me');
      expect(await store.migrateLegacy(), hasLength(1));
      expect(await original.exists(), true);
      await store.delete('delete-me');
      expect(await original.exists(), false);
      expect(await db.query('coach_legacy'), isEmpty);
      await store.migrateLegacy();
      expect(await store.read('delete-me'), isNull);
    },
  );
}
