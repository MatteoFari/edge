import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/coach/coach_store.dart';
import 'package:openstrap_edge/coach/coach_stream.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Repo extends LocalRepository {
  int writes = 0;
  @override
  Future<Map<String, dynamic>> setStepGoal(int goal) async {
    writes++;
    return {};
  }
}

class _Client extends http.BaseClient {
  _Client(this.reply);
  final Future<http.StreamedResponse> Function(int, http.Request) reply;
  final List<Map<String, dynamic>> bodies = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final req = request as http.Request;
    bodies.add(jsonDecode(req.body));
    return reply(bodies.length, req);
  }
}

String delta(Map<String, dynamic> data, {String? reason}) =>
    'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': data, 'finish_reason': reason},
      ],
    })}\n\n';
http.StreamedResponse sse(Stream<List<int>> data) => http.StreamedResponse(
  data,
  200,
  headers: {'content-type': 'text/event-stream'},
);
http.StreamedResponse complete(String text) => http.StreamedResponse(
  Stream.value(
    utf8.encode(
      jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': text},
          },
        ],
      }),
    ),
  ),
  200,
  headers: {'content-type': 'application/json'},
);

// Representative Gemini OpenAI-compatibility fixtures. These are synthetic;
// no user request, provider response, or credential is recorded here.
Map<String, dynamic> geminiCall(
  String id,
  String name,
  Object arguments, {
  String? signature,
}) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': arguments},
  if (signature != null)
    'extra_content': {
      'google': {'thought_signature': signature},
    },
};
http.StreamedResponse toolCompletion(String id, int goal) =>
    http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': [
                    geminiCall(id, 'set_step_goal', '{"goal":$goal}'),
                  ],
                },
              },
            ],
          }),
        ),
      ),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoachConfig cfg;
  late Database db;
  late CoachStore store;
  late _Repo repo;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
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
    CoachEngine e, {
    void Function(CoachItem)? item,
    Future<bool> Function(ActionRequest)? confirm,
  }) => e.send(
    'Explain my day',
    onItem: item ?? (_) {},
    onStatus: (_) {},
    confirm: confirm ?? (_) async => false,
  );

  test(
    'real SSE deltas update one reply and preserve UTF-8 characters split across bytes',
    () async {
      final wire =
          '${delta({'content': 'Perché '})}${delta({'content': 'dormo bene?'})}${delta({}, reason: 'stop')}data: [DONE]\n\n';
      final bytes = utf8.encode(wire), observed = <String>[];
      final client = _Client(
        (_, _) async => sse(
          Stream.fromIterable([
            for (var i = 0; i < bytes.length; i += 3)
              bytes.sublist(i, (i + 3).clamp(0, bytes.length)),
          ]),
        ),
      );
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      await send(
        engine,
        item: (it) {
          if (it.kind == CoachItemKind.assistant) observed.add(it.text!);
        },
      );
      expect(observed, contains('Perché '));
      expect(
        engine.transcript.where((e) => e.kind == CoachItemKind.assistant),
        hasLength(1),
      );
      expect(engine.transcript.last.text, 'Perché dormo bene?');
      expect(client.bodies.single['stream'], true);
    },
  );
  test(
    'tool name and argument deltas assemble fully before confirmation or writing',
    () async {
      final controller = StreamController<List<int>>(),
          nativeCalls = <ActionRequest>[];
      final client = _Client(
        (n, _) async =>
            n == 1 ? sse(controller.stream) : complete('Goal saved'),
      );
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      final sending = send(
        engine,
        confirm: (req) async {
          nativeCalls.add(req);
          return true;
        },
      );
      controller.add(
        utf8.encode(
          delta({
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'function': {'name': 'set_', 'arguments': '{"go'},
              },
            ],
          }),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(nativeCalls, isEmpty);
      expect(repo.writes, 0);
      controller.add(
        utf8.encode(
          delta({
            'tool_calls': [
              {
                'index': 0,
                'function': {'name': 'step_goal', 'arguments': 'al":9000}'},
              },
            ],
          }),
        ),
      );
      controller.add(
        utf8.encode('${delta({}, reason: 'tool_calls')}data: [DONE]\n\n'),
      );
      await controller.close();
      await sending;
      expect(nativeCalls.single.args, {'goal': 9000});
      expect(repo.writes, 1);
      expect(engine.transcript.last.text, 'Goal saved');
    },
  );
  test(
    'Stop keeps actual partial text and never executes an unfinished streamed tool',
    () async {
      final controller = StreamController<List<int>>(),
          seen = Completer<void>();
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: _Client((_, _) async => sse(controller.stream)),
      );
      addTearDown(engine.dispose);
      final sending = send(
        engine,
        item: (it) {
          if (it.kind == CoachItemKind.assistant && !seen.isCompleted) {
            seen.complete();
          }
        },
        confirm: (_) async => true,
      );
      final cancelled = expectLater(sending, throwsA(isA<CoachCancelled>()));
      controller.add(
        utf8.encode(
          delta({
            'content': 'A real partial answer',
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'function': {'name': 'set_step_goal', 'arguments': '{"goal":'},
              },
            ],
          }),
        ),
      );
      await seen.future;
      engine.stop();
      await cancelled;
      await controller.close();
      expect(repo.writes, 0);
      expect(engine.transcript.last.text, 'A real partial answer');
      expect(engine.canRetry, true);
      expect(
        (await store.read(engine.sessionId))!['transcript_json'],
        contains('A real partial answer'),
      );
    },
  );
  test(
    'an interrupted stream retains partial text and does not fallback or execute incomplete tools',
    () async {
      final client = _Client(
        (_, _) async =>
            sse(Stream.value(utf8.encode(delta({'content': 'Partial'})))),
      );
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      await expectLater(send(engine), throwsA(isA<CoachException>()));
      expect(client.bodies, hasLength(1));
      expect(engine.transcript.any((e) => e.text == 'Partial'), true);
      expect(repo.writes, 0);
    },
  );
  test(
    'only explicit unsupported streaming falls back; other provider errors are not resent',
    () async {
      final client = _Client(
        (n, _) async => n == 1
            ? http.StreamedResponse(
                Stream.value(
                  utf8.encode(
                    '{"error":{"message":"stream is not supported"}}',
                  ),
                ),
                400,
              )
            : complete('Completion reply'),
      );
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      await send(engine);
      expect(client.bodies, hasLength(2));
      expect(client.bodies.first['stream'], true);
      expect(client.bodies.last.containsKey('stream'), false);
      expect(engine.transcript.last.text, 'Completion reply');
      final rejected = _Client(
        (_, _) async => http.StreamedResponse(
          Stream.value(utf8.encode('{"error":{"message":"Invalid model"}}')),
          400,
        ),
      );
      final another = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: rejected,
      );
      addTearDown(another.dispose);
      await expectLater(send(another), throwsA(isA<CoachException>()));
      expect(rejected.bodies, hasLength(1));
    },
  );
  test(
    'providers ignoring stream return a completed JSON reply without a duplicate request',
    () async {
      final client = _Client((_, _) async => complete('One completion'));
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      await send(engine);
      expect(client.bodies, hasLength(1));
      expect(engine.transcript.last.text, 'One completion');
    },
  );
  test(
    'partial replies checkpoint the original chat while the stream is still pending',
    () async {
      final controller = StreamController<List<int>>(),
          seen = Completer<void>();
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: _Client((_, _) async => sse(controller.stream)),
      );
      addTearDown(engine.dispose);
      final original = engine.sessionId;
      final sending = send(
        engine,
        item: (it) {
          if (it.kind == CoachItemKind.assistant && !seen.isCompleted) {
            seen.complete();
          }
        },
      );
      controller.add(utf8.encode(delta({'content': 'First real words'})));
      await seen.future;
      engine.newSession();
      engine.updateDraft('Independent draft');
      await engine.persist();
      Map<String, Object?>? saved;
      for (var i = 0; i < 60; i++) {
        saved = await CoachStore(db, 'local').read(original);
        if ((saved?['transcript_json'] as String? ?? '').contains(
          'First real words',
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(saved!['transcript_json'], contains('First real words'));
      final reopened = CoachEngine(
        config: cfg,
        api: repo,
        store: CoachStore(db, 'local'),
      );
      addTearDown(reopened.dispose);
      await reopened.openSession(original);
      expect(reopened.transcript.last.text, 'First real words');
      expect(engine.draft, 'Independent draft');
      controller.add(
        utf8.encode(
          '${delta({'content': ' and the final words.'})}${delta({}, reason: 'stop')}data: [DONE]\n\n',
        ),
      );
      await controller.close();
      await sending;
      await reopened.openSession(engine.sessionId);
      expect(reopened.draft, 'Independent draft');
      final finalRow = await store.read(original);
      final transcript =
          jsonDecode(finalRow!['transcript_json'] as String) as List;
      expect(transcript.where((e) => e['kind'] == 'assistant'), hasLength(1));
      expect(transcript.last['text'], 'First real words and the final words.');
    },
  );
  test(
    'the byte limit rejects a pending stream without a newline before line buffering',
    () async {
      final controller = StreamController<List<int>>();
      final reading = readCoachStream(
        sse(controller.stream),
        onText: (_) {},
        checkCancelled: () {},
      );
      final rejected = expectLater(
        reading,
        throwsA(isA<CoachStreamException>()),
      );
      controller.add(List.filled(4 * 1024 * 1024, 32));
      controller.add([32]);
      await rejected;
      await controller.close();
    },
  );
  test('the final received delta survives a length-limited stream', () async {
    final engine = CoachEngine(
      config: cfg,
      api: repo,
      store: store,
      client: _Client(
        (_, _) async => sse(
          Stream.value(
            utf8.encode(
              delta({'content': 'Received before the limit'}, reason: 'length'),
            ),
          ),
        ),
      ),
    );
    addTearDown(engine.dispose);
    await expectLater(send(engine), throwsA(isA<CoachException>()));
    expect(
      engine.transcript.any((e) => e.text == 'Received before the limit'),
      true,
    );
  });
  test(
    'Gemini indexless parallel calls assemble by stable ID in any chunk order',
    () async {
      final wire =
          '${delta({
            'extra_content': {
              'google': {'thought_signature': 'message-signature'},
            },
            'tool_calls': [geminiCall('gemini-read', 'run_sql', '{"sql":"SELECT ', signature: 'call-signature'), geminiCall('gemini-write', 'set_step_goal', '{"goal":9')],
          })}${delta({
            'tool_calls': [
              geminiCall('gemini-write', 'set_step_goal', '000}'),
              {
                'id': 'gemini-read',
                'function': {'arguments': 'date FROM v_daily LIMIT 1"}'},
              },
            ],
          })}${delta({
            'tool_calls': [geminiCall('gemini-write', 'set_step_goal', '{"goal":9000}')],
          }, reason: 'tool_calls')}data: [DONE]\n\n';
      final reply = await readCoachStream(
        sse(Stream.value(utf8.encode(wire))),
        onText: (_) {},
        checkCancelled: () {},
      );
      final calls = reply['tool_calls'] as List;
      expect(calls.map((c) => c['id']), ['gemini-read', 'gemini-write']);
      expect(calls.first['function']['name'], 'run_sql');
      expect(jsonDecode(calls.first['function']['arguments']), {
        'sql': 'SELECT date FROM v_daily LIMIT 1',
      });
      expect(calls.last['function']['name'], 'set_step_goal');
      expect(jsonDecode(calls.last['function']['arguments']), {'goal': 9000});
      expect(calls.first['extra_content'], {
        'google': {'thought_signature': 'call-signature'},
      });
      expect(reply['extra_content'], {
        'google': {'thought_signature': 'message-signature'},
      });
    },
  );
  test(
    'Gemini permits an unnamed ID-free continuation only for a single known call',
    () async {
      await cfg.save(
        baseUrl: 'http://127.0.0.1:11434/v1',
        model: 'models/gemini-3.5-flash-lite',
      );
      final controller = StreamController<List<int>>(),
          prompts = <ActionRequest>[];
      final client = _Client(
        (n, _) async =>
            n == 1 ? sse(controller.stream) : complete('Goal saved'),
      );
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      final sending = send(
        engine,
        confirm: (req) async {
          prompts.add(req);
          return true;
        },
      );
      controller.add(
        utf8.encode(
          delta({
            'extra_content': {
              'google': {'thought_signature': 'assistant-signature'},
            },
            'tool_calls': [
              geminiCall(
                'gemini-call',
                'set_step_goal',
                '{"goal":9',
                signature: 'opaque-signature',
              ),
            ],
          }),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(prompts, isEmpty);
      expect(repo.writes, 0);
      controller.add(
        utf8.encode(
          '${delta({
            'tool_calls': [
              {
                'function': {'arguments': '000}'},
              },
            ],
          })}${delta({}, reason: 'tool_calls')}data: [DONE]\n\n',
        ),
      );
      await controller.close();
      await sending;
      expect(prompts.single.args, {'goal': 9000});
      expect(repo.writes, 1);
      final message = (client.bodies.last['messages'] as List).firstWhere(
        (m) => m['role'] == 'assistant',
      );
      expect(message['tool_calls'].single['id'], 'gemini-call');
      expect(message['tool_calls'].single['extra_content'], {
        'google': {'thought_signature': 'opaque-signature'},
      });
      expect(message['extra_content'], {
        'google': {'thought_signature': 'assistant-signature'},
      });
      final row = await store.read(engine.sessionId);
      expect(row!['history_json'], contains('opaque-signature'));
      expect(row['history_json'], contains('assistant-signature'));
    },
  );
  String ambiguousGemini({bool partialText = false}) =>
      '${delta({
        if (partialText) 'content': 'Actual streamed text',
        'tool_calls': [geminiCall('first-call', 'set_step_goal', '{"goal":9000}'), geminiCall('second-call', 'set_step_goal', '{"goal":8000}')],
      })}${delta({
        'tool_calls': [
          {
            'function': {'arguments': '0}'},
          },
        ],
      })}';
  test(
    'ambiguous Gemini continuations fall back before any streamed tool executes',
    () async {
      var prompts = 0;
      final client = _Client((n, _) async {
        if (n == 1) return sse(Stream.value(utf8.encode(ambiguousGemini())));
        if (n == 2) {
          expect(repo.writes, 0);
          expect(prompts, 0);
          return toolCompletion('ordinary-call', 9000);
        }
        return complete('Goal saved once');
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
          prompts++;
          return true;
        },
      );
      expect(client.bodies, hasLength(3));
      expect(client.bodies[0]['stream'], true);
      expect(client.bodies[1].containsKey('stream'), false);
      expect(prompts, 1);
      expect(repo.writes, 1);
      expect(engine.transcript.last.text, 'Goal saved once');
      expect(
        engine.debugHistory
            .where((m) => m['tool_calls'] != null)
            .single['tool_calls']
            .single['id'],
        'ordinary-call',
      );
    },
  );
  test(
    'Gemini fallback after a completed write carries its result and never repeats it',
    () async {
      var prompts = 0;
      final client = _Client((n, _) async {
        if (n == 1) {
          return sse(
            Stream.value(
              utf8.encode(
                '${delta({
                  'tool_calls': [geminiCall('first-write', 'set_step_goal', '{"goal":9000}')],
                }, reason: 'tool_calls')}data: [DONE]\n\n',
              ),
            ),
          );
        }
        if (n == 2) return sse(Stream.value(utf8.encode(ambiguousGemini())));
        if (n == 3) {
          expect(repo.writes, 1);
          return toolCompletion('repeated-write', 9000);
        }
        return complete('Already saved');
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
          prompts++;
          return true;
        },
      );
      expect(repo.writes, 1);
      expect(prompts, 1);
      expect(client.bodies, hasLength(4));
      expect(client.bodies[2].containsKey('stream'), false);
      expect(
        (client.bodies[2]['messages'] as List).where(
          (m) => m['role'] == 'tool' && m['tool_call_id'] == 'first-write',
        ),
        hasLength(1),
      );
      expect(
        engine.debugHistory
            .where((m) => m['role'] == 'tool')
            .map((m) => m['content'])
            .toSet(),
        hasLength(1),
      );
    },
  );
  test(
    'an anonymous call after one complete Gemini call also falls back before actions',
    () async {
      final client = _Client((n, _) async {
        if (n == 1) {
          return sse(
            Stream.value(
              utf8.encode(
                '${delta({
                  'tool_calls': [geminiCall('known-call', 'set_step_goal', '{"goal":9000}')],
                })}${delta({
                  'tool_calls': [
                    {
                      'function': {'name': 'set_step_goal', 'arguments': '{"goal":8000}'},
                    },
                  ],
                })}',
              ),
            ),
          );
        }
        expect(repo.writes, 0);
        return complete('Ordinary response');
      });
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      await send(engine, confirm: (_) async => true);
      expect(repo.writes, 0);
      expect(client.bodies, hasLength(2));
      expect(client.bodies.last.containsKey('stream'), false);
      expect(engine.transcript.last.text, 'Ordinary response');
    },
  );
  test(
    'a pending Gemini fallback stays on its originating chat when chats switch',
    () async {
      final fallbackStarted = Completer<void>(),
          fallback = Completer<http.StreamedResponse>();
      final client = _Client((n, _) async {
        if (n == 1) {
          return sse(
            Stream.value(utf8.encode(ambiguousGemini(partialText: true))),
          );
        }
        fallbackStarted.complete();
        return fallback.future;
      });
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      final origin = engine.sessionId, sending = send(engine);
      await fallbackStarted.future;
      engine.newSession();
      engine.updateDraft('Another chat draft');
      await engine.persist();
      fallback.complete(complete('Origin reply'));
      await sending;
      expect(engine.draft, 'Another chat draft');
      expect(engine.transcript, isEmpty);
      expect(repo.writes, 0);
      final row = await store.read(origin),
          transcript = jsonDecode(row!['transcript_json'] as String) as List;
      expect(
        transcript.where((m) => m['kind'] == 'assistant').single['text'],
        'Origin reply',
      );
    },
  );
  test(
    'Stop during Gemini fallback keeps its real partial and prevents later actions',
    () async {
      final fallbackStarted = Completer<void>(),
          fallback = Completer<http.StreamedResponse>();
      final client = _Client((n, _) async {
        if (n == 1) {
          return sse(
            Stream.value(utf8.encode(ambiguousGemini(partialText: true))),
          );
        }
        fallbackStarted.complete();
        return fallback.future;
      });
      final engine = CoachEngine(
        config: cfg,
        api: repo,
        store: store,
        client: client,
      );
      addTearDown(engine.dispose);
      final sending = send(engine, confirm: (_) async => true),
          cancelled = expectLater(sending, throwsA(isA<CoachCancelled>()));
      await fallbackStarted.future;
      engine.stop();
      await cancelled;
      fallback.complete(toolCompletion('late-call', 9000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(repo.writes, 0);
      expect(engine.isSending, false);
      expect(engine.transcript.last.text, 'Actual streamed text');
      expect(
        (await store.read(engine.sessionId))!['transcript_json'],
        contains('Actual streamed text'),
      );
    },
  );
}
