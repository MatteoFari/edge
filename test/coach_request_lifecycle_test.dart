import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/coach/coach_store.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Repo extends LocalRepository {
  int writes = 0;
  Completer<void>? writeStarted, finishWrite;
  @override
  Future<Map<String, dynamic>> setStepGoal(int goal) async {
    writes++;
    writeStarted?.complete();
    await finishWrite?.future;
    return {};
  }
}

class _HoldingStore extends CoachStore {
  _HoldingStore(super.db, super.owner);
  int saves = 0;
  int? holdAt;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> save(Map<String, Object?> row) async {
    if (++saves == holdAt) {
      entered.complete();
      await release.future;
    }
    await super.save(row);
  }
}

http.Response answer(String text) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': text},
      },
    ],
  }),
  200,
);
http.Response tool(String id) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {
          'role': 'assistant',
          'content': 'I will save your step goal.',
          'tool_calls': [
            {
              'id': id,
              'function': {
                'name': 'set_step_goal',
                'arguments': '{"goal":9000}',
              },
            },
          ],
        },
      },
    ],
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoachConfig cfg;
  late Database db;
  late _Repo repo;
  late CoachStore store;
  setUpAll(() {
    sqfliteFfiInit();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'm');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await CoachStore.create(db);
    store = CoachStore(db, 'local');
    repo = _Repo();
  });
  tearDown(() async {
    cfg.dispose();
    await db.close();
  });
  Future<void> send(
    CoachEngine engine, {
    bool retry = false,
    Future<bool> Function(ActionRequest)? confirm,
    void Function(String?)? status,
  }) => engine.send(
    'Please set my goal',
    retry: retry,
    onItem: (_) {},
    onStatus: status ?? (_) {},
    confirm: confirm ?? (_) async => true,
  );

  test(
    'switching while a provider is in flight preserves original reply and both drafts',
    () async {
      final held = Completer<http.Response>();
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((_) => held.future),
      );
      addTearDown(engine.dispose);
      engine.newSession();
      final origin = engine.sessionId;
      engine.updateDraft('old draft', scrollOffset: 40);
      await engine.persist();
      final sending = send(engine);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      engine.newSession();
      final next = engine.sessionId;
      engine.updateDraft('next draft', scrollOffset: 90);
      await engine.persist();
      held.complete(answer('original answer'));
      await sending;
      expect(engine.sessionId, next);
      expect(engine.transcript, isEmpty);
      expect(engine.draft, 'next draft');
      await engine.openSession(origin);
      expect(engine.transcript.last.text, 'original answer');
      expect(engine.scrollOffset, 40);
      await engine.openSession(next);
      expect(engine.draft, 'next draft');
      expect(engine.scrollOffset, 90);
    },
  );
  test(
    'rename during a final arriving reply preserves transcript and draft',
    () async {
      final held = _HoldingStore(db, 'local')..holdAt = 2;
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: held,
        client: MockClient((_) async => answer('arriving answer')),
      );
      addTearDown(engine.dispose);
      engine.newSession();
      final id = engine.sessionId;
      final sending = send(engine);
      await held.entered.future;
      final renaming = engine.renameSession(id, 'Renamed while arriving');
      engine.updateDraft('next question');
      held.release.complete();
      await sending;
      await renaming;
      await engine.persist();
      final saved = await store.read(id);
      expect(saved!['title'], 'Renamed while arriving');
      expect(saved['transcript_json'], contains('arriving answer'));
      expect(saved['draft'], 'next question');
    },
  );
  test(
    'delete cannot race final persistence; pending draft saves never resurrect deleted chats',
    () async {
      final held = _HoldingStore(db, 'local')..holdAt = 2;
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: held,
        client: MockClient((_) async => answer('answer')),
      );
      addTearDown(engine.dispose);
      engine.newSession();
      final id = engine.sessionId;
      final sending = send(engine);
      await held.entered.future;
      expect(engine.isSending, true);
      await expectLater(engine.deleteSession(id), throwsStateError);
      held.release.complete();
      await sending;
      engine.updateDraft('queued draft');
      final saving = engine.persist();
      final deleting = engine.deleteSession(id);
      await saving;
      await deleting;
      expect(await store.read(id), isNull);
    },
  );

  test(
    'same-chat double send is rejected synchronously and Stop clears its single guard',
    () async {
      final held = Completer<http.Response>();
      var calls = 0;
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((_) {
          calls++;
          return held.future;
        }),
      );
      addTearDown(engine.dispose);
      final first = send(engine);
      final cancelled = expectLater(first, throwsA(isA<CoachCancelled>()));
      await expectLater(send(engine), throwsStateError);
      expect(
        engine.transcript.where((e) => e.kind == CoachItemKind.user),
        hasLength(1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      engine.stop();
      await cancelled;
      expect(engine.isSending, false);
      expect(calls, lessThanOrEqualTo(1));
      held.complete(answer('late'));
    },
  );
  test(
    'preparing a captured origin while another chat is selected cannot route its prompt to the selected chat',
    () async {
      final requests = <Map<String, dynamic>>[];
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((r) async {
          requests.add(jsonDecode(r.body));
          return answer('original reply');
        }),
      );
      addTearDown(engine.dispose);
      engine.newSession();
      final origin = engine.sessionId;
      engine.updateDraft('origin draft');
      await engine.persist();
      final preparing = engine.reloadPreferences();
      engine.newSession();
      final selected = engine.sessionId;
      engine.updateDraft('selected draft');
      await preparing;
      await engine.send(
        'origin question',
        sessionId: origin,
        onItem: (_) {},
        onStatus: (_) {},
        confirm: (_) async => false,
      );
      expect(engine.sessionId, selected);
      expect(engine.transcript, isEmpty);
      expect(engine.draft, 'selected draft');
      await engine.openSession(origin);
      expect(engine.transcript.last.text, 'original reply');
      expect(
        (requests.single['messages'] as List).lastWhere(
          (m) => m['role'] == 'user',
        )['content'],
        contains('origin question'),
      );
    },
  );

  test(
    'Stop during a confirmed write saves the receipt before Retry and never repeats it',
    () async {
      var calls = 0;
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((_) async {
          calls++;
          return calls <= 2 ? tool('call_$calls') : answer('done');
        }),
      );
      addTearDown(engine.dispose);
      repo.writeStarted = Completer();
      repo.finishWrite = Completer();
      final sending = send(engine);
      final cancellation = expectLater(sending, throwsA(isA<CoachCancelled>()));
      await repo.writeStarted!.future;
      engine.stop();
      repo.finishWrite!.complete();
      await cancellation;
      expect(repo.writes, 1);
      expect(engine.isSending, false);
      expect(engine.canRetry, true);
      final saved = await store.read(engine.sessionId);
      expect(saved!['history_json'], contains('Step goal updated.'));
      expect(saved['retry_json'], contains('Step goal updated.'));
      await send(engine, retry: true);
      expect(repo.writes, 1);
      expect(engine.transcript.last.text, 'done');
    },
  );
  test(
    'Retry after provider failure retains partial replies and skips completed writes',
    () async {
      var calls = 0, confirms = 0;
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((_) async {
          calls++;
          if (calls == 1) return tool('first');
          if (calls == 2) throw http.ClientException('network failed');
          if (calls == 3) return tool('repeat');
          return answer('finished');
        }),
      );
      addTearDown(engine.dispose);
      await expectLater(
        send(
          engine,
          confirm: (_) async {
            confirms++;
            return true;
          },
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(
        engine.transcript.any((e) => e.text == 'I will save your step goal.'),
        true,
      );
      expect(engine.draft, 'Please set my goal');
      await send(
        engine,
        retry: true,
        confirm: (_) async {
          confirms++;
          return true;
        },
      );
      expect(repo.writes, 1);
      expect(confirms, 1);
    },
  );
  test(
    'Stop aborts a pending provider request and clears flags without discarding the turn',
    () async {
      final held = Completer<http.Response>();
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((_) => held.future),
      );
      addTearDown(engine.dispose);
      final sending = send(engine);
      final result = expectLater(sending, throwsA(isA<CoachCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      engine.stop();
      await result;
      expect(engine.isSending, false);
      expect(engine.canRetry, true);
      expect(engine.transcript.first.text, 'Please set my goal');
      held.complete(answer('late answer'));
      await Future<void>.delayed(Duration.zero);
      expect(engine.transcript.length, 1);
    },
  );
  test(
    'reset aborts requests waiting on native confirmation and invalidates old writers',
    () async {
      final nativePrompt = Completer<void>(), confirmation = Completer<bool>();
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((_) async => tool('reset-confirm')),
      );
      addTearDown(engine.dispose);
      final sending = send(
        engine,
        confirm: (_) {
          nativePrompt.complete();
          return confirmation.future;
        },
      );
      final cancelled = expectLater(sending, throwsA(isA<CoachCancelled>()));
      await nativePrompt.future;
      await CoachStore.beforeReset(db);
      await cancelled;
      expect(engine.isSending, false);
      expect(engine.transcript, isEmpty);
      expect(repo.writes, 0);
      await expectLater(
        store.savePreferences(const CoachPreferences()),
        throwsStateError,
      );
      confirmation.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(repo.writes, 0);
    },
  );
  test(
    'reset waits an already confirmed write and cannot repersist a deleted conversation',
    () async {
      repo.writeStarted = Completer();
      repo.finishWrite = Completer();
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((_) async => tool('reset-write')),
      );
      addTearDown(engine.dispose);
      final sending = send(engine);
      final cancelled = expectLater(sending, throwsA(isA<CoachCancelled>()));
      await repo.writeStarted!.future;
      var resetFinished = false;
      final reset = CoachStore.beforeReset(db).then((_) async {
        for (final table in [
          'coach_chat',
          'coach_preferences',
          'coach_memory',
          'coach_legacy',
        ]) {
          await db.delete(table);
        }
        resetFinished = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(resetFinished, false);
      repo.finishWrite!.complete();
      await reset;
      await cancelled;
      expect(await CoachStore(db, 'local').list(), isEmpty);
      expect(engine.transcript, isEmpty);
      await engine.persist();
      expect(await CoachStore(db, 'local').list(), isEmpty);
    },
  );

  test(
    'custom instructions are user preferences below the unchanged tool contract; memory starts off',
    () async {
      final requests = <Map<String, dynamic>>[];
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: MockClient((r) async {
          requests.add(jsonDecode(r.body));
          return answer('answer');
        }),
      );
      addTearDown(engine.dispose);
      await store.savePreferences(
        const CoachPreferences(
          customInstructions: 'Prefer concise Italian',
          memoryEnabled: false,
        ),
      );
      await store.saveMemory('Outdoor runs');
      await engine.reloadPreferences();
      await send(engine);
      final messages = requests.last['messages'] as List;
      expect(messages.first['role'], 'system');
      expect(
        messages.first['content'],
        isNot(contains('Prefer concise Italian')),
      );
      expect(messages[1]['role'], 'user');
      expect(messages[1]['content'], contains('Prefer concise Italian'));
      expect(messages[1]['content'], isNot(contains('Outdoor runs')));
      await store.savePreferences(const CoachPreferences(memoryEnabled: true));
      await engine.reloadPreferences();
      await send(engine);
      expect(
        (requests.last['messages'] as List).lastWhere(
          (m) => m['role'] == 'user',
        )['content'],
        contains('Outdoor runs'),
      );
    },
  );
  test(
    'memory tool requires enablement and explicit native confirmation',
    () async {
      var calls = 0, confirmed = 0;
      final client = MockClient((_) async {
        if (calls++ % 2 == 1) return answer('done');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'tool_calls': [
                    {
                      'id': 'remember_$calls',
                      'function': {
                        'name': 'remember_preference',
                        'arguments': '{"text":"I prefer outdoor runs"}',
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      await send(
        engine,
        confirm: (_) async {
          confirmed++;
          return true;
        },
      );
      expect(confirmed, 0);
      expect(await store.memories(), isEmpty);
      await store.savePreferences(const CoachPreferences(memoryEnabled: true));
      await engine.reloadPreferences();
      await send(
        engine,
        confirm: (_) async {
          confirmed++;
          return false;
        },
      );
      expect(await store.memories(), isEmpty);
      await send(
        engine,
        confirm: (_) async {
          confirmed++;
          return true;
        },
      );
      expect(confirmed, 2);
      expect((await store.memories()).single.text, 'I prefer outdoor runs');
    },
  );
}
