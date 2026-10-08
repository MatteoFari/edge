// CoachEngine — the agentic core. Talks to an OpenAI-compatible provider directly
// (BYOK), runs a tool-calling loop over read-only data tools + a plot tool + action
// tools (writes require user confirmation), and streams items back to the UI.
//
// Data flow: user asks → model calls data tools (we read via the LocalRepository
// seam) → model reasons → optionally calls plot_chart with a figure it built →
// optionally proposes an action (we confirm) → model returns the final text.
//
// CLOUD EXCISED: the data tools used to hit the authed backend via ApiClient. They
// now go through LocalRepository (lib/data/local_repository.dart) — the same
// surface, implemented on-device by the future analytics re-layer. The LLM call
// itself still uses `http` directly (BYOK, the user's own provider — not our backend).

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/day_label.dart';
import '../data/db.dart';
import '../data/local_repository.dart';
import '../sync/reset_gate.dart';
import 'coach_actions.dart';
import 'coach_config.dart';
import 'coach_db.dart';
import 'coach_prompt.dart';
import 'coach_store.dart';
import 'coach_stream.dart';

// ── value types ──────────────────────────────────────────────────────────────

/// A figure the model built from data it fetched; the app renders it animated.
class ChartSpec {
  final String type; // 'bar' | 'line' | 'area'
  final String title;
  final List<String> xLabels;
  final List<ChartSeries> series;
  final String unit;
  final String? note;
  ChartSpec({
    required this.type,
    required this.title,
    required this.xLabels,
    required this.series,
    this.unit = '',
    this.note,
  });

  // Some OpenAI-compatible models (e.g. minimax via NVIDIA NIM) wrap array params
  // as {"item":[...]} and emit numbers as strings. Be liberal in what we accept.
  static List<dynamic> _asList(dynamic v) {
    if (v is List) return v;
    if (v is Map && v['item'] is List) return v['item'] as List;
    if (v is Map && v['items'] is List) return v['items'] as List;
    return const [];
  }

  static double? _asNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) {
      final d = double.tryParse(v.trim());
      if (d != null) return d;
      // tolerate "62 ms", units glued on, etc. — take the first number found.
      final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v);
      return m == null ? null : double.tryParse(m.group(0)!);
    }
    if (v is Map) {
      return _asNum(v['value'] ?? v['y'] ?? v['v']); // {value:62}/{y:62}
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'title': title,
    'x_labels': xLabels,
    'unit': unit,
    'note': note,
    'series': series.map((s) => {'name': s.name, 'values': s.values}).toList(),
  };

  static ChartSpec? tryParse(Map<String, dynamic> j) {
    try {
      final rawSeries = _asList(j['series']);
      final series = rawSeries
          .whereType<Map>()
          .map((s) {
            final vals = _asList(
              s['values'] ?? s['data'] ?? s['y'],
            ).map(_asNum).toList();
            return ChartSeries(
              name: (s['name'] ?? s['label'] ?? '').toString(),
              values: vals,
            );
          })
          .where((s) => s.values.any((v) => v != null))
          .toList(); // drop all-null series
      if (series.isEmpty) return null;
      final xs = _asList(
        j['x_labels'] ?? j['labels'] ?? j['x'],
      ).map((e) => '$e').toList();
      return ChartSpec(
        type: (j['type'] ?? 'bar').toString(),
        title: (j['title'] ?? '').toString(),
        xLabels: xs,
        series: series,
        unit: (j['unit'] ?? j['y_unit'] ?? '').toString(),
        note: j['note']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

class ChartSeries {
  final String name;
  final List<double?> values;
  ChartSeries({required this.name, required this.values});
}

/// A write the model wants to perform — surfaced to the user for confirmation.
class ActionRequest {
  final String tool;
  final String title; // e.g. "Log a period"
  final String summary; // human description of exactly what will happen
  final Map<String, dynamic> args;
  ActionRequest({
    required this.tool,
    required this.title,
    required this.summary,
    required this.args,
  });
}

/// One rendered chat item.
enum CoachItemKind { user, assistant, chart, render, error }

class CoachItem {
  final CoachItemKind kind;
  final String? text;
  final ChartSpec? chart;

  /// Generic render spec ({type, title?, ...payload}) drawn by [CoachRender].
  final Map<String, dynamic>? render;
  CoachItem.user(this.text)
    : kind = CoachItemKind.user,
      chart = null,
      render = null;
  CoachItem.assistant(this.text)
    : kind = CoachItemKind.assistant,
      chart = null,
      render = null;
  CoachItem.error(this.text)
    : kind = CoachItemKind.error,
      chart = null,
      render = null;
  CoachItem.chart(this.chart)
    : kind = CoachItemKind.chart,
      text = null,
      render = null;
  CoachItem.render(this.render)
    : kind = CoachItemKind.render,
      text = null,
      chart = null;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'text': text,
    'chart': chart?.toJson(),
    'render': render,
  };

  static CoachItem fromJson(Map<String, dynamic> j) {
    final k = j['kind'];
    if (k == 'chart' && j['chart'] is Map) {
      final c = ChartSpec.tryParse((j['chart'] as Map).cast<String, dynamic>());
      if (c != null) return CoachItem.chart(c);
    }
    if (k == 'render' && j['render'] is Map) {
      return CoachItem.render((j['render'] as Map).cast<String, dynamic>());
    }
    final t = j['text']?.toString();
    if (k == 'user') return CoachItem.user(t);
    if (k == 'error') return CoachItem.error(t);
    return CoachItem.assistant(t);
  }
}

/// Lightweight index entry for a saved chat session (for the history list).
class CoachSessionMeta {
  final String id;
  final String title;
  final int updatedAt; // ms since epoch
  final String preview;
  CoachSessionMeta(this.id, this.title, this.updatedAt, this.preview);
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt,
    'preview': preview,
  };
  static CoachSessionMeta fromJson(Map<String, dynamic> j) => CoachSessionMeta(
    (j['id'] ?? '').toString(),
    (j['title'] ?? '').toString(),
    (j['updatedAt'] as num?)?.toInt() ?? 0,
    (j['preview'] ?? '').toString(),
  );
}

class _CoachSession {
  _CoachSession(this.id);
  final String id;
  String title = '', draft = '';
  int createdAt = 0;
  double scrollOffset = 0;
  final List<Map<String, dynamic>> history = [];
  final List<CoachItem> transcript = [];
  Map<String, dynamic>? retry;
  bool deleted = false;
}

class _CoachRequest {
  _CoachRequest(this.session, this.onStatus, {this.retrying = false});
  final _CoachSession session;
  final void Function(String?) onStatus;
  final Completer<void> abort = Completer<void>(), finished = Completer<void>();
  bool stopped = false;
  final bool retrying;
  String toolCallId = '';
  final Set<String> originalToolIds = {};
  void check() {
    if (stopped) throw CoachCancelled();
  }
}

class CoachCancelled implements Exception {}

// ── engine ───────────────────────────────────────────────────────────────────

class CoachEngine {
  final CoachConfig config;
  final LocalRepository api;
  final String storageKey; // per-user, so accounts don't share a transcript
  final http.Client _http;

  /// Count of [send] calls currently inside their provider call(s). A local
  /// model can take minutes to answer, and the screen that started the call
  /// is routinely gone before it finishes — navigated away, or the app
  /// backgrounded and the route rebuilt. [dispose] must not close [_http]
  /// while this is above zero: doing so aborts whichever request(s) are still
  /// in flight out from under them, and the failure lands in a screen state
  /// (the caller's `mounted` checks) that no longer exists to show it — total
  /// silence instead of an answer or a real error. A plain bool here would
  /// under-count: if two `send` calls overlap, the first to finish would flip
  /// it false and let a requested dispose close the client on the second.
  int _sending = 0;

  /// Set by [requestDispose] when it is called while [_sending] is above
  /// zero. The actual close happens once the last overlapping [send]'s
  /// `finally` sees the count reach zero, not before.
  bool _disposeRequested = false;

  // OpenAI-format running history (system is added per-request) — the context we
  // resend every turn so the model remembers the conversation.
  _CoachSession _current = _CoachSession(CoachStore.newId());
  int _sessionSelectionRevision = 0;
  final Map<String, _CoachSession> _sessions = {};
  final Map<String, _CoachRequest> _requests = {};
  final Set<String> _completionOnly = {};
  CoachStore? _store;
  final Map<String, Future<void>> _sessionWrites = {};
  List<String> migrationIssues = [];
  CoachPreferences preferences = const CoachPreferences();
  List<CoachMemory> memories = [];
  List<Map<String, dynamic>> get _history => _current.history;
  List<CoachItem> get transcript => _current.transcript;
  String get sessionId => _current.id;
  String get draft => _current.draft;
  double get scrollOffset => _current.scrollOffset;
  bool get canRetry => _current.retry != null && !isSending;
  bool get isSending => _requests.containsKey(sessionId);
  bool get hasCompletedWrites =>
      (_current.retry?['receipts'] as Map?)?.isNotEmpty ?? false;
  @visibleForTesting
  List<Map<String, dynamic>> get debugHistory => _history;
  @visibleForTesting
  void debugTrimHistory() => _trimHistory(_history);

  CoachEngine({
    required this.config,
    required this.api,
    this.storageKey = 'anon',
    http.Client? client,
    CoachStore? store,
  }) : _http = client ?? http.Client(),
       _store = store {
    store?.addResetListener(_resetForDeletion);
  }

  // ── prompt size ceilings ────────────────────────────────────────────────────
  //
  // The coach's tools read the on-device health database and every result is
  // resent, verbatim, on EVERY subsequent turn. Without a ceiling a model that
  // keeps widening its queries would eventually serialize the whole database
  // into a request bound for a third-party endpoint. Three bounds, all
  // independent of the provider's own context limit:
  //   • per tool result  — one query can't dominate the window;
  //   • rolling history  — the resent conversation is bounded in BYTES, not
  //     just in message count (60 × 16 KB was ~1 MB);
  //   • per request      — a hard fail-closed ceiling in [postChat].

  /// Max characters of any single tool result kept in the resent history.
  static const int kMaxToolResultChars = 16000;

  /// The ceiling for `get_ecg_reading` alone.
  ///
  /// The bound above exists because the MODEL widens its own queries — it can
  /// keep asking `run_sql` for more until one result dominates the window.
  /// `get_ecg_reading` is not that shape: it is a bound lookup of ONE reading
  /// by id, and its size is decided by the band (a completed reading is 30 s
  /// at 100 Hz), not by the model. Clipping it would not restrain a model, it
  /// would only decimate a waveform to make room for the prose describing it.
  static const int kMaxEcgToolResultChars = 24000;

  /// Max characters of running history resent on each turn.
  static const int kMaxHistoryChars = 120000;

  /// Hard ceiling on one serialized provider request body.
  static const int kMaxRequestBytes = 400 * 1024;

  static int _capFor(String tool) =>
      tool == 'get_ecg_reading' ? kMaxEcgToolResultChars : kMaxToolResultChars;

  static String _clipToolResult(String s, String tool) {
    final cap = _capFor(tool);
    return s.length <= cap
        ? s
        : '${s.substring(0, cap)}…(truncated — narrow the query)';
  }

  int _historyChars(List<Map<String, dynamic>> history) {
    var n = 0;
    for (final m in history) {
      n += jsonEncode(m).length;
    }
    return n;
  }

  /// Bound the resent history in bytes, dropping WHOLE turns from the oldest
  /// end so a `tool` message never outlives the assistant turn whose
  /// `tool_calls` it answers (providers 400 on an orphaned tool message).
  void _trimHistory(
    List<Map<String, dynamic>> history, {
    int reservedChars = 0,
  }) {
    while (_historyChars(history) + reservedChars > kMaxHistoryChars &&
        history.length > 1) {
      history.removeAt(0);
      while (history.length > 1 && history.first['role'] != 'user') {
        history.removeAt(0);
      }
    }
    // Both loops stop at `length > 1`, so one turn larger than the whole budget
    // can strand a lone `tool` at the head: [assistant(tool_calls), tool] drops
    // the assistant and then has nothing left to pair with. That orphan is the
    // exact shape this method exists to prevent, and providers 400 on it, so
    // enforce the invariant unconditionally rather than as a side effect of the
    // loop bounds.
    while (history.isNotEmpty && history.first['role'] == 'tool') {
      history.removeAt(0);
    }
  }

  void reset() {
    _history.clear();
    transcript.clear();
    _current.retry = null;
  }

  bool get hasHistory => _history.isNotEmpty;

  Future<CoachStore> get store async {
    if (_store == null) {
      _store = await CoachStore.open(storageKey);
      _store!.addResetListener(_resetForDeletion);
    }
    return _store!;
  }

  Future<void> _resetForDeletion() async {
    final requests = _requests.values.toList();
    for (final session in {_current, ..._sessions.values}) {
      session.deleted = true;
    }
    for (final request in requests) {
      request.stopped = true;
      if (!request.abort.isCompleted) request.abort.complete();
    }
    await Future.wait(requests.map((r) => r.finished.future));
    await Future.wait(_sessionWrites.values);
    _current.transcript.clear();
    _current.history.clear();
    _current.draft = '';
    _current.retry = null;
    _sessions.clear();
    preferences = const CoachPreferences();
    memories = [];
  }

  Future<List<CoachSessionMeta>> listSessions({String search = ''}) async => [
    for (final r in await (await store).list(search: search))
      CoachSessionMeta(
        r['id'] as String,
        r['title'] as String,
        (r['updated_ms'] as num).toInt(),
        r['preview'] as String,
      ),
  ];

  Future<void> restore() async {
    final st = await store;
    migrationIssues = await st.migrateLegacy();
    await reloadPreferences();
    final metas = await listSessions();
    if (metas.isEmpty) {
      newSession();
    } else {
      await openSession(metas.first.id);
    }
  }

  Future<void> reloadPreferences() async {
    final st = await store;
    preferences = await st.preferences();
    memories = await st.memories();
  }

  void newSession() {
    _sessionSelectionRevision++;
    _current = _CoachSession(CoachStore.newId());
    _sessions[_current.id] = _current;
  }

  Future<void> openSession(String id) async {
    final revision = ++_sessionSelectionRevision;
    final cached = _sessions[id];
    if (cached != null) {
      _current = cached;
      return;
    }
    final r = await (await store).read(id);
    if (r == null) throw StateError('Conversation no longer exists');
    final session = _CoachSession(id)
      ..title = r['title'] as String
      ..createdAt = (r['created_ms'] as num).toInt()
      ..draft = r['draft'] as String
      ..scrollOffset = (r['scroll_offset'] as num).toDouble();
    final parsed = await _decodeOffThread(r);
    session.history.addAll(parsed.$1);
    session.transcript.addAll(parsed.$2);
    session.retry = parsed.$3;
    _sessions[id] = session;
    if (revision == _sessionSelectionRevision) _current = session;
  }

  static Future<
    (List<Map<String, dynamic>>, List<CoachItem>, Map<String, dynamic>?)
  >
  _decodeOffThread(Map<String, Object?> row) =>
      Isolate.run(() => _decodeSessionRow(row));
  static Future<Map<String, Object?>> _encodeOffThread(
    _CoachSession session,
    int now,
  ) => Isolate.run(() => _encodeSessionRow(session, now));
  static (List<Map<String, dynamic>>, List<CoachItem>, Map<String, dynamic>?)
  _decodeSessionRow(Map<String, Object?> r) => (
    (jsonDecode(r['history_json'] as String) as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(),
    (jsonDecode(r['transcript_json'] as String) as List)
        .map((e) => CoachItem.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    r['retry_json'] is String
        ? (jsonDecode(r['retry_json'] as String) as Map).cast<String, dynamic>()
        : null,
  );
  Future<void> retryMigration() async {
    migrationIssues = await (await store).migrateLegacy();
  }

  Future<void> _serializeSession(String id, Future<void> Function() operation) {
    final done = (_sessionWrites[id] ?? Future.value()).then(
      (_) => operation(),
    );
    _sessionWrites[id] = done.catchError((_) {});
    return done;
  }

  void updateDraft(String text, {double? scrollOffset}) {
    _current.draft = text;
    if (scrollOffset != null && scrollOffset.isFinite) {
      _current.scrollOffset = scrollOffset.clamp(0, double.infinity);
    }
  }

  Future<void> persist() => _persistSession(_current);
  Future<void> _persistSession(_CoachSession session) =>
      _serializeSession(session.id, () async {
        if (session.deleted) return;
        if (session.transcript.isEmpty && session.draft.isEmpty) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (session.createdAt == 0) session.createdAt = now;
        if (session.title.isEmpty) {
          final user =
              session.transcript
                  .where((e) => e.kind == CoachItemKind.user)
                  .firstOrNull
                  ?.text
                  ?.trim() ??
              '';
          session.title = user.isEmpty
              ? ''
              : user.length > 40
              ? '${user.substring(0, 40)}…'
              : user;
        }
        final row = await _encodeOffThread(session, now);
        if (!session.deleted) await (await store).save(row);
      });
  static Map<String, Object?> _encodeSessionRow(
    _CoachSession session,
    int now,
  ) {
    final texts = session.transcript.map((e) => e.text ?? '').join('\n');
    final preview =
        session.transcript.reversed
            .where((e) => (e.text ?? '').isNotEmpty)
            .firstOrNull
            ?.text ??
        session.draft;
    return {
      'id': session.id,
      'title': session.title,
      'created_ms': session.createdAt,
      'updated_ms': now,
      'preview': preview.length > 80 ? preview.substring(0, 80) : preview,
      'search_text': '${session.title}\n$texts\n${session.draft}',
      'history_json': jsonEncode(session.history),
      'transcript_json': jsonEncode(
        session.transcript.map((e) => e.toJson()).toList(),
      ),
      'draft': session.draft,
      'scroll_offset': session.scrollOffset,
      'retry_json': session.retry == null ? null : jsonEncode(session.retry),
    };
  }

  Future<void> renameSession(String id, String title) =>
      _serializeSession(id, () async {
        final t = title.trim();
        if (t.isEmpty || t.length > 120) {
          throw ArgumentError('Chat title must be 1–120 characters');
        }
        await (await store).rename(id, t);
        _sessions[id]?.title = t;
        if (_current.id == id) _current.title = t;
      });
  Future<void> deleteSession(String id) async {
    if (_requests.containsKey(id)) {
      throw StateError('Stop the reply before deleting this conversation');
    }
    final session = _sessions[id];
    if (session != null) session.deleted = true;
    try {
      await _serializeSession(id, () async {
        if (_requests.containsKey(id)) {
          throw StateError('Reply is still being saved');
        }
        await (await store).delete(id);
      });
      _sessions.remove(id);
      if (id == sessionId) newSession();
    } catch (_) {
      if (session != null) session.deleted = false;
      rethrow;
    }
  }

  void stop() {
    final r = _requests[sessionId];
    if (r == null) return;
    r.stopped = true;
    if (!r.abort.isCompleted) r.abort.complete();
  }

  /// True when [base]'s host is anthropic.com or one of its subdomains. A
  /// domain-boundary check, not endsWith('anthropic.com'), so a lookalike
  /// host (evil-anthropic.com) never receives the key in Anthropic headers.
  static bool _isAnthropicHost(String base) {
    final host = (Uri.tryParse(base)?.host ?? '').toLowerCase();
    return host == 'anthropic.com' || host.endsWith('.anthropic.com');
  }

  /// Live model list from the provider's /models endpoint (OpenAI-compatible).
  /// Static so Settings can probe an as-yet-unsaved base URL + key.
  static Future<List<String>> fetchModels(String apiBase, String apiKey) async {
    var b = apiBase.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    // Anthropic's native Models API authenticates with x-api-key +
    // anthropic-version (a bearer token is rejected) and paginates with
    // has_more/last_id, but its response shape (data[].id) matches OpenAI's.
    final isAnthropic = _isAnthropicHost(b);
    final ids = <String>[];
    String? after;
    do {
      final uri = Uri.parse(
        isAnthropic
            ? '$b/models?limit=1000${after == null ? '' : '&after_id=$after'}'
            : '$b/models',
      );
      final resp = await http
          .get(
            uri,
            headers: isAnthropic
                ? {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'}
                : {'Authorization': 'Bearer $apiKey'},
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw CoachException(
          'Models request failed (${resp.statusCode}): ${_short(resp.body)}',
        );
      }
      final j = jsonDecode(resp.body);
      final data = (j['data'] as List?) ?? const [];
      ids.addAll(
        data
            .map((e) => (e as Map)['id']?.toString() ?? '')
            .where((s) => s.isNotEmpty),
      );
      after = (isAnthropic && j['has_more'] == true)
          ? j['last_id']?.toString()
          : null;
    } while (after != null);
    ids.sort();
    return ids;
  }

  static String _short(String s) => s.length > 200 ? s.substring(0, 200) : s;

  // LOCAL day label — the coach's SQL views (v_daily/v_metric/…) are keyed by
  // the device-local dates the derivation engine files days under, so "today"
  // must be local too (a UTC date here pointed the model one day back until
  // ~05:30 for a UTC+5:30 user).
  static String _today() => todayLabel();

  /// Run one user turn. Emits items via [onItem]; reports the current tool via
  /// [onStatus]; asks the user to confirm writes via [confirm] (returns true to
  /// proceed). Returns when the model produces its final answer (or hits the cap).
  Future<void> send(
    String userText, {
    String? viewingDay,
    viewingSection,
    sessionId,
    bool retry = false,
    required void Function(CoachItem) onItem,
    required void Function(String?) onStatus,
    required Future<bool> Function(ActionRequest) confirm,
  }) async {
    final session = sessionId == null ? _current : _sessions[sessionId];
    if (ResetGate.active || session == null || session.deleted) {
      throw StateError('Conversation no longer exists');
    }
    if (_requests.containsKey(session.id)) {
      throw StateError('A reply is already in progress in this conversation');
    }
    _sessions[session.id] = session;
    final request = _CoachRequest(session, onStatus, retrying: retry);
    if (retry) {
      final start = session.history.lastIndexWhere((m) => m['role'] == 'user');
      for (final message in session.history.skip(start < 0 ? 0 : start)) {
        for (final call in message['tool_calls'] as List? ?? []) {
          request.originalToolIds.add((call['id'] ?? '').toString());
        }
      }
    }
    // The screen prevents overlap within a chat. Existing engine callers may
    // overlap; each call still captures its own session before its first await.
    _requests[session.id] = request;
    _sending++;
    void emit(CoachItem it) {
      session.transcript.add(it);
      onItem(it);
    }

    Timer? checkpointTimer;
    Future<void>? checkpointSave;
    var checkpointDirty = false, checkpointsClosed = false;
    void checkpoint() {
      checkpointDirty = true;
      if (_store == null ||
          checkpointsClosed ||
          checkpointTimer != null ||
          checkpointSave != null) {
        return;
      }
      // Coalesce genuine deltas into at most one queued/in-flight save. A slow
      // disk must not accumulate a write for every token.
      checkpointTimer = Timer(const Duration(milliseconds: 500), () {
        checkpointTimer = null;
        checkpointDirty = false;
        checkpointSave = _persistSession(session)
            .catchError((Object _) {
              // The final save still reports persistence failures to the caller.
            })
            .whenComplete(() {
              checkpointSave = null;
              if (checkpointDirty && !checkpointsClosed) checkpoint();
            });
      });
    }

    try {
      if (!retry) {
        final day = viewingDay == null ? null : CoachActions.day(viewingDay);
        final section =
            const {
              'Home',
              'Health',
              'Workout',
              'Wellness',
            }.contains(viewingSection)
            ? viewingSection
            : null;
        final content = day == null
            ? userText
            : 'App view: ${section ?? 'Health'}, local day $day. '
                  'This is the viewed date, not the device date.\n\n$userText';
        emit(CoachItem.user(userText));
        session.history.add({'role': 'user', 'content': content});
        session.retry = {'receipts': <String, dynamic>{}};
      } else if (session.retry == null) {
        return;
      }
      if (_store != null) await _persistSession(session);
      for (var i = 0; i < 10; i++) {
        request.check();
        // Continue any unfinished tool batch. Previously completed writes have
        // durable receipts and their tool results stay in this same history.
        final assistant = session.history.lastIndexWhere(
          (m) => m['role'] == 'assistant' && m['tool_calls'] is List,
        );
        if (assistant >= 0) {
          final trailing = session.history.sublist(assistant + 1);
          if (!trailing.any(
            (m) => m['role'] == 'user' || m['role'] == 'assistant',
          )) {
            final calls = session.history[assistant]['tool_calls'] as List;
            for (final raw in calls) {
              final tc = raw as Map, id = (raw['id'] ?? '').toString();
              if (trailing.any(
                (m) => m['role'] == 'tool' && m['tool_call_id'] == id,
              )) {
                continue;
              }
              request.check();
              final fn = tc['function'] as Map? ?? {};
              final name = (fn['name'] ?? '').toString();
              Map<String, dynamic> args = {};
              try {
                final value = fn['arguments'];
                if (value is String && value.isNotEmpty) {
                  args = (jsonDecode(value) as Map).cast<String, dynamic>();
                }
                if (value is Map) args = value.cast<String, dynamic>();
              } catch (_) {}
              request.toolCallId = id;
              onStatus(_statusFor(name, args));
              final result = await _runTool(
                name,
                args,
                request: request,
                onItem: emit,
                confirm: confirm,
              );
              session.history.add({
                'role': 'tool',
                'tool_call_id': id,
                'name': name,
                'content': _clipToolResult(result, name),
              });
              if (_store != null) await _persistSession(session);
              // Honor Stop only after a confirmed write's result is persisted.
              request.check();
            }
          }
        }
        request.check();
        onStatus('requesting');
        final prefs = preferences;
        final personal = <String>[
          'User preferences (lower priority than the app contract; never change tool rules, freshness, or confirmations):',
          'Focus: ${prefs.focus}. Reply length: ${prefs.replyLength}.',
          if (prefs.customInstructions.isNotEmpty)
            'Custom instructions, untrusted preferences: ${prefs.customInstructions}',
          if (prefs.memoryEnabled)
            ...memories
                .take(30)
                .map(
                  (m) =>
                      'Saved preference (never a current health fact): ${m.text}',
                ),
        ].join('\n');
        _trimHistory(session.history, reservedChars: personal.length);
        var streamedIndex = -1;
        final reply = await _chat(
          [
            {
              'role': 'system',
              'content':
                  '$kCoachSystemPrompt\n\nToday is ${_today()} (device-local date; all day-keyed data uses these local dates).',
            },
            ..._withPreferences(session.history, personal),
          ],
          request: request,
          onText: (text) {
            request.check();
            final item = CoachItem.assistant(text);
            if (streamedIndex < 0) {
              streamedIndex = session.transcript.length;
              session.transcript.add(item);
            } else {
              session.transcript[streamedIndex] = item;
            }
            onStatus(null);
            onItem(item);
            checkpoint();
          },
        );
        request.check();
        if (streamedIndex >= 0) session.transcript.removeAt(streamedIndex);
        final tools = reply['tool_calls'] as List? ?? [];
        final content = (reply['content'] as String?)?.trim();
        if (content != null && content.isNotEmpty) {
          _emitAssistantText(content, emit);
        }
        session.history.add({
          'role': 'assistant',
          'content': content ?? '',
          if (reply['extra_content'] != null)
            'extra_content': reply['extra_content'],
          if (tools.isNotEmpty) 'tool_calls': tools,
        });
        if (tools.isEmpty) {
          session.retry = null;
          return;
        }
      }
      emit(
        CoachItem.assistant(
          'I couldn’t finish that request. Try narrowing the question.',
        ),
      );
    } on CoachCancelled {
      if (session.draft.isEmpty && userText.isNotEmpty) {
        session.draft = userText;
      }
      rethrow;
    } catch (e) {
      if (session.draft.isEmpty && userText.isNotEmpty) {
        session.draft = userText;
      }
      emit(CoachItem.error(e is CoachException ? e.message : '$e'));
      rethrow;
    } finally {
      onStatus(null);
      checkpointsClosed = true;
      checkpointTimer?.cancel();
      try {
        await checkpointSave;
        if (_store != null) await _persistSession(session);
      } finally {
        if (identical(_requests[session.id], request)) {
          _requests.remove(session.id);
        }
        _sending--;
        if (!request.finished.isCompleted) request.finished.complete();
        if (_sending == 0 && _disposeRequested) dispose();
      }
    }
  }

  static List<Map<String, dynamic>> _withPreferences(
    List<Map<String, dynamic>> history,
    String personal,
  ) {
    final messages = history.map((m) => Map<String, dynamic>.from(m)).toList();
    final index = messages.lastIndexWhere((m) => m['role'] == 'user');
    if (index >= 0) {
      messages[index]['content'] = '${messages[index]['content']}\n\n$personal';
    }
    return messages;
  }

  // Some providers (esp. ones with shaky tool-calling) sometimes answer with a
  // fenced JSON code block instead of actually calling plot_chart/render — that
  // renders as an unexplained grey code block in the UI (GptMarkdown's default
  // code-field styling), not a chart. Detect a chart/render JSON payload inside
  // any fence and draw it as a real figure instead; leave real code fences (rare,
  // the coach is told never to write code) or non-figure JSON untouched.
  static void _emitAssistantText(
    String content,
    void Function(CoachItem) emit,
  ) {
    final fence = RegExp(r'```[a-zA-Z0-9_-]*\n([\s\S]*?)```');
    final figures = <CoachItem>[];
    final cleaned = content.replaceAllMapped(fence, (m) {
      try {
        final decoded = jsonDecode((m.group(1) ?? '').trim());
        if (decoded is Map && decoded['type'] != null) {
          final j = decoded.cast<String, dynamic>();
          final type = j['type'].toString().toLowerCase();
          if ((type == 'bar' || type == 'line' || type == 'area') &&
              j['series'] != null) {
            final spec = ChartSpec.tryParse(j);
            if (spec != null) {
              figures.add(CoachItem.chart(spec));
              return '';
            }
          }
          figures.add(CoachItem.render(j));
          return '';
        }
      } catch (_) {
        // not JSON / not a figure — leave the fence as-is.
      }
      return m.group(0) ?? '';
    }).trim();
    if (cleaned.isNotEmpty) emit(CoachItem.assistant(cleaned));
    for (final f in figures) {
      emit(f);
    }
  }

  // ── provider call ────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> _chat(
    List<Map<String, dynamic>> messages, {
    required _CoachRequest request,
    required void Function(String) onText,
  }) async {
    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'tools': _toolDefs,
      'tool_choice': 'auto',
      'temperature': 0.3,
    };
    final provider = '${config.apiBase}|${config.model}';
    if (_completionOnly.contains(provider)) {
      return postChat(
        config,
        body,
        client: _http,
        abortTrigger: request.abort.future,
      );
    }
    final streaming = _streamChat(body, request: request, onText: onText);
    try {
      return await Future.any<Map<String, dynamic>>([
        streaming,
        request.abort.future.then<Map<String, dynamic>>(
          (_) => throw CoachCancelled(),
        ),
      ]).timeout(
        config.requestTimeout,
        onTimeout: () {
          if (!request.abort.isCompleted) request.abort.complete();
          throw CoachException(
            'The model did not finish within the configured request timeout. Retry when ready.',
          );
        },
      );
    } on CoachStreamException catch (e) {
      throw CoachException(e.message);
    }
  }

  Future<Map<String, dynamic>> _streamChat(
    Map<String, dynamic> body, {
    required _CoachRequest request,
    required void Function(String) onText,
  }) async {
    final streamingBody = {...body, 'stream': true};
    if (claudeRejectsSampling(config.model)) {
      streamingBody.remove('temperature');
      streamingBody.remove('top_p');
      streamingBody.remove('top_k');
    }
    final payload = jsonEncode(streamingBody);
    if (utf8.encode(payload).length > kMaxRequestBytes) {
      throw CoachException(
        'That request exceeds the data limit for this device. Start a new chat or ask a narrower question.',
      );
    }
    request.check();
    final httpRequest =
        http.AbortableRequest(
            'POST',
            Uri.parse('${config.apiBase}/chat/completions'),
            abortTrigger: request.abort.future,
          )
          ..headers.addAll({
            if (config.hasKey) 'Authorization': 'Bearer ${config.apiKey}',
            'content-type': 'application/json',
            'accept': 'text/event-stream, application/json',
          })
          ..body = payload;
    final response = await _http.send(httpRequest);
    request.check();
    if (response.statusCode != 200) {
      final error = await http.Response.fromStream(response);
      request.check();
      final message = _briefErr(error.body);
      // The failed attempt emitted no deltas and cannot have executed a tool.
      // Only an explicit rejection of streaming permits a completion retry.
      if (const {400, 422, 501}.contains(error.statusCode) &&
          _rejectsStream(message)) {
        _completionOnly.add('${config.apiBase}|${config.model}');
        return postChat(
          config,
          body,
          client: _http,
          abortTrigger: request.abort.future,
        );
      }
      throw CoachException('Provider error (${error.statusCode}): $message');
    }
    if ((response.headers['content-type'] ?? '').toLowerCase().contains(
      'text/event-stream',
    )) {
      try {
        return await readCoachStream(
          response,
          onText: onText,
          checkCancelled: request.check,
        );
      } on CoachStreamToolAssociationException {
        request.check();
        // No tools from this response have reached the engine. Reuse the
        // original messages, including receipts/results from earlier rounds,
        // and request one ordinary response rather than guess tool identity.
        return postChat(
          config,
          body,
          client: _http,
          abortTrigger: request.abort.future,
        );
      }
    }
    // Some compatible providers ignore stream:true and return a completed JSON
    // response. Consume that response exactly once; never resend it as a fallback.
    final complete = await http.Response.fromStream(response);
    request.check();
    final decoded = jsonDecode(utf8.decode(complete.bodyBytes));
    if (decoded is! Map ||
        decoded['choices'] is! List ||
        (decoded['choices'] as List).isEmpty) {
      throw CoachException('Unexpected response from provider.');
    }
    final first = (decoded['choices'] as List).first;
    if (first is! Map) {
      throw CoachException('Unexpected response from provider.');
    }
    final message = first['message'] ?? first['delta'];
    if (message is Map) return message.cast<String, dynamic>();
    if (first['text'] is String) return {'content': first['text']};
    throw CoachException('Provider returned an unsupported response shape.');
  }

  static bool _rejectsStream(String message) => RegExp(
    r'(stream(?:ing)?[\s\S]{0,100}(?:not supported|unsupported|not implemented|not allowed))|(?:(?:unsupported|unknown|unrecognized)[\s\S]{0,80}stream)',
    caseSensitive: false,
  ).hasMatch(message);

  /// True when [model] names a Claude version that rejects OpenAI sampling
  /// params (temperature/top_p/top_k) with a 400: Opus >= 4.7, Sonnet and
  /// Haiku >= 5, and the Fable/Mythos family. Claude is served under many
  /// provider namings — bare "claude-…", OpenRouter "anthropic/claude-…",
  /// Bedrock-style "anthropic.claude-…-v1:0" — with "-" or "." version
  /// separators, so match the id anywhere and parse family + version instead
  /// of keying off a prefix. Older Claude models still accept sampling and are
  /// deliberately excluded, as is every non-Claude model. Public for tests.
  static bool claudeRejectsSampling(String model) {
    final m = model.toLowerCase();
    final i = m.indexOf('claude');
    if (i < 0) return false;
    final id = m.substring(i);
    if (id.startsWith('claude-fable') || id.startsWith('claude-mythos')) {
      return true;
    }
    // Minor is capped at 2 digits with no digit following, so a date suffix
    // (claude-opus-4-20250514) never parses as a minor version.
    final v = RegExp(
      r'^claude-(opus|sonnet|haiku)[-.](\d+)(?:[-.](\d{1,2})(?!\d))?',
    ).firstMatch(id);
    // Legacy version-first ids (claude-3-5-sonnet-…) all accept sampling.
    if (v == null) return false;
    final major = int.parse(v.group(2)!);
    final minor = int.tryParse(v.group(3) ?? '') ?? 0;
    if (v.group(1) == 'opus') {
      return major > 4 || (major == 4 && minor >= 7);
    }
    return major >= 5; // sonnet, haiku
  }

  /// Shared completed-response path for daily briefings, journal chat, and
  /// Coach providers that explicitly reject streaming. Returns the first
  /// choice's `message` map. Throws [CoachException] on provider errors.
  static Future<Map<String, dynamic>> postChat(
    CoachConfig config,
    Map<String, dynamic> body, {
    http.Client? client,
    Future<void>? abortTrigger,
  }) async {
    final c = client ?? http.Client();
    // Recent Claude models reject sampling params with a 400, on Anthropic's
    // own endpoint and through any pass-through provider alike. Strip them for
    // exactly those model versions; older Claude models and every other
    // provider keep their sampling params untouched.
    if (claudeRejectsSampling(body['model'] as String? ?? '')) {
      body = {...body}
        ..remove('temperature')
        ..remove('top_p')
        ..remove('top_k');
    }
    // FAIL-CLOSED size ceiling. Nothing leaves the device until this passes —
    // the request is never truncated and silently sent, it is refused, so a
    // runaway tool loop cannot ship the health database to a third party.
    final payload = jsonEncode(body);
    if (utf8.encode(payload).length > kMaxRequestBytes) {
      throw CoachException(
        'That request grew to ${payload.length ~/ 1024} KB, over the '
        '${kMaxRequestBytes ~/ 1024} KB safety limit for data leaving this '
        'device. Start a new chat or ask a narrower question (aggregate with '
        'AVG/MIN/MAX/COUNT instead of selecting every row).',
      );
    }
    try {
      final request =
          http.AbortableRequest(
              'POST',
              Uri.parse('${config.apiBase}/chat/completions'),
              abortTrigger: abortTrigger,
            )
            ..headers.addAll({
              if (config.hasKey) 'Authorization': 'Bearer ${config.apiKey}',
              'content-type': 'application/json',
            })
            ..body = payload;
      final response = c
          .send(request)
          .then(http.Response.fromStream)
          .timeout(config.requestTimeout);
      final resp = abortTrigger == null
          ? await response
          : await Future.any<http.Response>([
              response,
              abortTrigger.then<http.Response>((_) => throw CoachCancelled()),
            ]);
      if (resp.statusCode != 200) {
        throw CoachException(
          'Provider error (${resp.statusCode}): ${_briefErr(resp.body)}',
        );
      }
      final Object? j;
      try {
        j = jsonDecode(utf8.decode(resp.bodyBytes));
      } catch (_) {
        throw CoachException(
          'Provider returned a non-JSON response. Check the API base URL — '
          'it must point at an OpenAI-compatible /chat/completions endpoint.',
        );
      }
      if (j is! Map) throw CoachException('Unexpected response from provider.');
      final choices = (j['choices'] as List?) ?? const [];
      if (choices.isEmpty) {
        throw CoachException('Empty response from provider.');
      }
      // Every shape below is a REAL thing OpenAI-compatible proxies return:
      // a streaming chunk (`delta` instead of `message`), the legacy
      // completions shape (`text`), or a bare string. Reaching for
      // `choices.first['message'] as Map<String,dynamic>` blind surfaced a raw
      // TypeError ("type 'Null' is not a subtype of type 'Map<String,
      // dynamic>'") instead of the documented CoachException, so the UI showed
      // a Dart type name to the user rather than an actionable message.
      final first = choices.first;
      if (first is! Map) {
        throw CoachException('Unexpected response from provider.');
      }
      final msg = first['message'] ?? first['delta'];
      if (msg is Map) return msg.cast<String, dynamic>();
      final text = first['text'];
      if (text is String) return <String, dynamic>{'content': text};
      throw CoachException(
        'Provider returned an unsupported response shape (no message/delta). '
        'Streaming-only endpoints are not supported — use a standard '
        'OpenAI-compatible /chat/completions endpoint.',
      );
    } finally {
      if (client == null) c.close();
    }
  }

  /// One-shot multi-turn text completion (no tools). Reuses [postChat] — the
  /// briefing + journal engines call this instead of owning an HTTP client.
  static Future<String> chatOnce({
    required CoachConfig config,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.4,
  }) async {
    final msg = await postChat(config, {
      'model': config.model,
      'messages': messages,
      'temperature': temperature,
    });
    return ((msg['content'] as String?) ?? '').trim();
  }

  /// One-shot "system + user → text" completion. The simplest reuse surface.
  static Future<String> completeText({
    required CoachConfig config,
    required String system,
    required String user,
    double temperature = 0.4,
  }) => chatOnce(
    config: config,
    temperature: temperature,
    messages: [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ],
  );

  static String _briefErr(String body) {
    try {
      final j = jsonDecode(body);
      return (j['error']?['message'] ?? body).toString();
    } catch (_) {
      return body.length > 300 ? body.substring(0, 300) : body;
    }
  }

  // ── tool execution ───────────────────────────────────────────────────────────
  Future<String> _runTool(
    String name,
    Map<String, dynamic> args, {
    required _CoachRequest request,
    required void Function(CoachItem) onItem,
    required Future<bool> Function(ActionRequest) confirm,
  }) async {
    try {
      switch (name) {
        // data — one read-only SQL tool over the derived views
        case 'run_sql':
          return await CoachDb.runCoachSql('${args['sql'] ?? ''}');

        // data — the two stores that are NOT in the SQL views. Widening
        // `coach_db`'s allow-list to reach them would trade a structural btree
        // gate for a text-level one; a typed read tool costs nothing.
        case 'get_nutrition':
          return await CoachActions.nutritionDay(
            await LocalDb.instance,
            args['date'],
          );
        case 'get_medications':
          return await CoachActions.medications(await LocalDb.instance);
        // data — one saved ECG reading, by id. Bound query + bounded payload;
        // the packet tables stay unreachable through run_sql.
        case 'get_ecg_reading':
          return await CoachActions.ecgReading(
            await LocalDb.instance,
            args['reading_id'],
          );

        // plot — legacy bar/line/area figure
        case 'plot_chart':
          final spec = ChartSpec.tryParse(args);
          if (spec == null) return 'Could not parse figure; check the schema.';
          onItem(CoachItem.chart(spec));
          return 'Chart rendered for the user.';

        // render — rich typed widget spec ({type, title?, ...payload})
        case 'render':
          if (args['type'] == null) return 'render needs a "type" field.';
          onItem(CoachItem.render(Map<String, dynamic>.from(args)));
          return 'Rendered "${args['type']}" for the user.';

        case 'remember_preference':
          final text = (args['text'] ?? '').toString().trim();
          if (text.isEmpty || text.length > 500) {
            return 'Preference must be 1–500 characters.';
          }
          if (!preferences.memoryEnabled) {
            return 'Memory is off. The user must enable it in Personalization first.';
          }
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Remember this preference?',
              summary: text,
              args: args,
            ),
            () async {
              await (await store).saveMemory(text);
              memories = await (await store).memories();
              return 'Preference saved.';
            },
          );
        // actions (confirmed)
        case 'log_journal':
          final journalDate = CoachActions.day(args['date']);
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Log journal',
              summary:
                  'Add journal for $journalDate: tags ${args['tags'] ?? []}, note "${args['note'] ?? ''}".',
              args: args,
            ),
            () async {
              await api.postJournal(
                journalDate,
                ((args['tags'] as List?) ?? const []).map((e) => '$e').toList(),
                '${args['note'] ?? ''}',
              );
              return 'Journal saved.';
            },
          );
        case 'log_period':
          final periodDate = CoachActions.day(args['date']);
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Log period',
              summary: 'Log a period start on $periodDate.',
              args: args,
            ),
            () async {
              await api.postCycleLog(periodDate, kind: 'start');
              return 'Period logged.';
            },
          );
        case 'start_workout':
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Start workout',
              summary: 'Start a ${args['type'] ?? 'workout'} session now.',
              args: args,
            ),
            () async {
              final r = await api.startWorkout('${args['type'] ?? 'other'}');
              return _enc(r);
            },
          );
        case 'end_workout':
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'End workout',
              summary: 'End the active workout.',
              args: args,
            ),
            () async {
              final r = await api.endWorkout('${args['workout_id']}');
              return _enc(r);
            },
          );
        case 'log_food':
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Log food',
              summary:
                  'Add "${args['label']}" to ${args['meal']} on '
                  '${args['date'] ?? 'today'}'
                  '${args['kcal'] == null ? '' : ' (${args['kcal']} kcal)'}.',
              args: args,
            ),
            () async => CoachActions.logFood(await LocalDb.instance, args),
          );
        case 'log_journal_fields':
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Log how the day went',
              summary:
                  'Record ${_fieldSummary(args['fields'])} for '
                  '${args['date'] ?? 'today'}.',
              args: args,
            ),
            () async => CoachActions.logJournalFields(api, args),
          );
        case 'add_completed_workout':
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Log a workout',
              summary:
                  'Save a ${args['duration_min']}-minute '
                  '${args['type'] ?? 'workout'} starting '
                  '${args['start_time']} on ${args['date'] ?? 'today'}.',
              args: args,
            ),
            () async => CoachActions.addCompletedWorkout(api, args),
          );
        case 'add_medication':
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Add a medication',
              summary:
                  'Schedule ${args['name']} at ${args['time']}, '
                  '${_daysSummary(args['weekdays'])}. '
                  'This app does not check interactions.',
              args: args,
            ),
            () async =>
                CoachActions.addMedication(await LocalDb.instance, args),
          );
        case 'mark_medication':
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Mark a dose',
              summary:
                  'Record ${args['name']} on ${args['date'] ?? 'today'} as '
                  '${args['state']}.',
              args: args,
            ),
            () async =>
                CoachActions.markMedication(await LocalDb.instance, args),
          );
        case 'set_step_goal':
          return await _action(
            request,
            confirm,
            ActionRequest(
              tool: name,
              title: 'Set step goal',
              summary: 'Set your daily step goal to ${args['goal']}.',
              args: args,
            ),
            () async {
              // A provider that sends "9000" as a string is not an edge case.
              final goal = CoachActions.num_(args['goal']);
              if (goal == null) {
                throw CoachActionError('A step goal must be a number.');
              }
              await api.setStepGoal(goal.round());
              return 'Step goal updated.';
            },
          );

        default:
          return 'Unknown tool: $name';
      }
    } on CoachCancelled {
      rethrow;
    } catch (e) {
      return 'Tool $name failed: ${e is RepositoryException ? e.body : e}';
    }
  }

  Future<String> _action(
    _CoachRequest request,
    Future<bool> Function(ActionRequest) confirm,
    ActionRequest req,
    Future<String> Function() run,
  ) async {
    request.check();
    final receipts = (request.session.retry!['receipts'] as Map)
        .cast<String, dynamic>();
    request.session.retry!['receipts'] = receipts;
    final key = '${req.tool}:${jsonEncode(_canonicalArgs(req.args))}';
    if (receipts.containsKey(key)) return receipts[key] as String;
    if (request.retrying &&
        receipts.isNotEmpty &&
        !request.originalToolIds.contains(request.toolCallId)) {
      return 'A confirmed action already completed in this turn. Do not perform a new write on Retry. Ask the user for a new request if they want another change.';
    }
    request.onStatus('confirmation');
    final ok = await Future.any<bool>([
      confirm(req),
      request.abort.future.then<bool>((_) => throw CoachCancelled()),
    ]);
    request.check();
    if (!ok) {
      receipts[key] = 'User declined the action. Do not retry it.';
      return receipts[key] as String;
    }
    request.onStatus('writing');
    // Persist a fail-closed receipt before entering a mutation. Even if a write
    // fails after committing, Retry cannot blindly execute it a second time.
    receipts[key] =
        'This action may already have been saved. Do not repeat it. Ask the user to check their data.';
    if (_store != null) await _persistSession(request.session);
    request.check();
    final result = await run();
    receipts[key] = result;
    if (_store != null) await _persistSession(request.session);
    return result;
  }

  static Object? _canonicalArgs(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((e) => e.toString()).toList()..sort();
      return {for (final k in keys) k: _canonicalArgs(value[k])};
    }
    if (value is List) return value.map(_canonicalArgs).toList();
    return value;
  }

  String _enc(Object? data) {
    final s = jsonEncode(data);
    return s.length > 16000 ? '${s.substring(0, 16000)}…(truncated)' : s;
  }

  /// "500 ml of water and mood 4" — the confirmation has to say what it writes,
  /// not "3 fields".
  static String _fieldSummary(Object? fields) {
    if (fields is! Map || fields.isEmpty) return 'nothing';
    return fields.entries
        .map((e) => '${e.key.toString().replaceAll('_', ' ')} ${e.value}')
        .join(', ');
  }

  static String _daysSummary(Object? weekdays) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    if (weekdays is! List || weekdays.isEmpty || weekdays.length == 7) {
      return 'every day';
    }
    return weekdays
        .map((d) => d is num && d >= 1 && d <= 7 ? names[d.toInt() - 1] : '?')
        .join(', ');
  }

  String _statusFor(String name, Map<String, dynamic> args) =>
      const {'plot_chart', 'render'}.contains(name)
      ? 'rendering'
      : const {
          'run_sql',
          'get_nutrition',
          'get_medications',
          'get_ecg_reading',
        }.contains(name)
      ? 'reading'
      : 'confirmation';

  void dispose() {
    _store?.removeResetListener(_resetForDeletion);
    _http.close();
  }

  /// What the screen should call instead of [dispose] directly. Closing
  /// [_http] while [send] is mid-flight aborts that request; deferring the
  /// close until [send]'s own `finally` sees it land is what lets a user
  /// navigate away from the coach screen without losing an in-progress
  /// answer.
  void requestDispose() {
    if (_sending > 0) {
      _disposeRequested = true;
    } else {
      dispose();
    }
  }

  // ── tool schema (OpenAI format) ───────────────────────────────────────────────
  static Map<String, dynamic> _fn(
    String name,
    String desc,
    Map<String, dynamic> props, [
    List<String> required = const [],
  ]) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': desc,
      'parameters': {
        'type': 'object',
        'properties': props,
        'required': required,
      },
    },
  };

  static final List<Map<String, dynamic>> _toolDefs = [
    _fn(
      'run_sql',
      'Read your health data by running ONE read-only SQLite SELECT over the '
          'derived views. Views & columns: '
          'v_metric(date,key,value); '
          'v_daily(date,resting_hr,hrv,sdnn,readiness,strain,resp_rate,stress,'
          'sleep_efficiency,sleep_min,deep_min,rem_min,light_min,nap_min,steps,'
          // `odi_per_hour` is NOT listed: the view still has the column but the
          // pipeline stopped writing the key when band SpO2 was dropped, so it
          // is always NULL. Advertising a column that can never hold a
          // value makes the model query it, get nothing, and reason about the
          // hole. A column that can never have data is a lie to the model.
          'active_calories,total_calories,skin_temp_z,lf_hf,hrv_cv,dip_pct,'
          'worn_min,hrr_bpm,brv_cv,irregular_flag); '
          'v_series(date,series,t,v) — series ∈ hr_curve,strain_curve,hrv_timeline,'
          'hrv_day,resp_day,skin_temp_day,zone_timeline,activity_curve; ALWAYS filter '
          'WHERE date=\'YYYY-MM-DD\' AND series=\'…\'; '
          'v_hypnogram(date,start_ts,end_ts,stage); '
          'v_sessions(id,start_ts,end_ts,date,type,status,calories,strain,max_hr,'
          'duration_min,steps,hrr_bpm,source,zone_min_json) — date is the LOCAL '
          'calendar day; filter "today\'s workout" by date, never by converting '
          'start_ts/end_ts yourself; '
          'v_baselines(key,value,mean,z,delta,ratio,n,updated_at); '
          'v_insights(id,kind,title,body,date,created_at,read); '
          'v_ecg_readings(id,start_ts,end_ts,date,wrist,status,category,'
          'result_code,avg_hr,quality,unreadable_mask,interruptions,duration_s,'
          'sample_count,sample_rate_hz,sample_unit,min_uv,max_uv,rms_uv,'
          'missing_segments) — WHOOP MG ECG readings, SUMMARY only (the '
          'category is the band\'s own result); the waveform is in '
          'get_ecg_reading. '
          'Read-only, derived only — no other tables. Dates are \'YYYY-MM-DD\'; '
          'timestamps are epoch seconds. Prefer aggregates (AVG/MIN/MAX/COUNT) over '
          'SELECT *. Results are capped at 200 rows.',
      {
        'sql': {'type': 'string', 'description': 'a single SELECT statement'},
      },
      ['sql'],
    ),
    _fn(
      'plot_chart',
      'Render a simple chart from data you fetched (bar/line/area). Build the figure yourself.',
      {
        'type': {
          'type': 'string',
          'enum': ['bar', 'line', 'area'],
        },
        'title': {'type': 'string'},
        'x_labels': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'series': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
              'values': {
                'type': 'array',
                'items': {
                  'type': ['number', 'null'],
                },
              },
            },
          },
        },
        'unit': {'type': 'string'},
        'note': {'type': 'string'},
      },
      ['type', 'x_labels', 'series'],
    ),
    _fn(
      'render',
      'Render a RICH figure from data you fetched. Pick a "type" and provide its '
          'payload. Types: line/area/bar/multi_series {x_labels,series:[{name,values}],unit}; '
          'scatter {points:[{x,y,label?}],x_label,y_label}; '
          'dual_axis {x_labels,left:{name,values,unit},right:{name,values,unit}}; '
          'stacked_zone_bar {x_labels,zones:[{name,values}]}; '
          'hypnogram {segments:[{start,end,stage}]} (stage∈wake|light|deep|rem, epoch sec); '
          'kpi_grid {cards:[{label,value,unit?,delta?,baseline?,spark?:[n]}]}; '
          'gauge {value,min?,max?,label?,unit?}; '
          'heatmap {rows:[label],cols:[label],values:[[n]],unit?}; '
          'range_band {label,value,min,max,unit?}; '
          'table {columns:[..],rows:[[..]]}. Always include a "title".',
      {
        'type': {'type': 'string'},
        'title': {'type': 'string'},
      },
      ['type'],
    ),
    _fn(
      'get_nutrition',
      'Read one day of food. Returns every entry and the day totals as the '
          'app computes them (a total over an entry with no numbers is a FLOOR '
          'and says so). Food is NOT in run_sql — use this.',
      {
        'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
      },
    ),
    _fn(
      'get_medications',
      'Read the medication/supplement schedule and today\'s doses '
          '(taken/skipped/missed/upcoming). Not in run_sql — use this.',
      {},
    ),
    _fn(
      'get_ecg_reading',
      'Read ONE saved WHOOP MG ECG reading by id: local time, status, the '
          'BAND-REPORTED category and result code, average HR, signal quality, '
          'unreadable reasons, duration, sample count, missing segments, '
          'min/max/RMS, and the accepted waveform in microvolts at the band\'s '
          'own sample rate (null where a segment is missing; a window too long '
          'for one result is decimated by a whole-number stride, reported as '
          '`stride`). Never returns raw frames, a band serial or the notes. The '
          'category is the band\'s HeartKey result, not yours; you may read the '
          'waveform yourself and say if you disagree with it.',
      {
        'reading_id': {
          'type': 'string',
          'description': 'the reading id from v_ecg_readings',
        },
      },
      ['reading_id'],
    ),
    _fn(
      'log_food',
      'Log something eaten (asks the user to confirm). EVERY nutrient is '
          'optional: an eating occasion with no numbers is a complete log, and '
          'you must never invent a calorie or macro figure to fill a field. Only '
          'pass a number the user told you or that is on a label they described.',
      {
        'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
        'meal': {
          'type': 'string',
          'enum': ['breakfast', 'lunch', 'dinner', 'snack'],
        },
        'label': {'type': 'string', 'description': 'what it was'},
        'time': {'type': 'string', 'description': 'HH:MM, optional'},
        'quantity': {'type': 'number'},
        'unit': {'type': 'string', 'description': 'g, ml, piece…'},
        'kcal': {'type': 'number'},
        'protein_g': {'type': 'number'},
        'carbs_g': {'type': 'number'},
        'fat_g': {'type': 'number'},
        'fibre_g': {'type': 'number'},
        'sugar_g': {'type': 'number'},
        'sat_fat_g': {'type': 'number'},
        'sodium_mg': {'type': 'number'},
        'iron_mg': {'type': 'number'},
        'calcium_mg': {'type': 'number'},
        'note': {'type': 'string'},
      },
      ['meal', 'label'],
    ),
    _fn(
      'log_journal_fields',
      'Record the user\'s own numbers for a day (asks them to confirm). This '
          'is where WATER and MOOD live. Fields: mood, sleep_quality, energy, '
          'stress, soreness (all 1–5), water_ml, caffeine_mg, alcohol_units, '
          'screens_min, weight_kg. Fields you do not pass are left as they are.',
      {
        'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
        'fields': {'type': 'object', 'description': 'field key -> number'},
        'time': {
          'type': 'string',
          'description': 'HH:MM — only used by caffeine/alcohol',
        },
      },
      ['fields'],
    ),
    _fn(
      'add_completed_workout',
      'Log a workout that ALREADY HAPPENED (asks the user to confirm). Use '
          'this for "I ran this morning" — start_workout is only for one starting '
          'right now. The window is scored from the recorded 1 Hz data; a window '
          'with nothing recorded behind it is saved unscored, and the result says '
          'which.',
      {
        'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
        'start_time': {'type': 'string', 'description': 'HH:MM local, 24-h'},
        'duration_min': {'type': 'integer'},
        'type': {
          'type': 'string',
          'description': 'run, ride, walk, strength, swim, yoga…',
        },
      },
      ['start_time', 'duration_min', 'type'],
    ),
    _fn(
      'add_medication',
      'Add or replace a medication/supplement schedule (asks the user to '
          'confirm). weekdays are 1=Monday…7=Sunday; pass them whenever the user '
          'says anything other than daily. This app does NOT check interactions '
          'and you must not imply that it does.',
      {
        'name': {'type': 'string'},
        'time': {'type': 'string', 'description': 'HH:MM, 24-h'},
        'weekdays': {
          'type': 'array',
          'items': {'type': 'integer'},
        },
        'dose_value': {'type': 'number'},
        'dose_unit': {'type': 'string', 'description': 'mg, ml, tablet…'},
        'kind': {
          'type': 'string',
          'enum': ['medication', 'supplement'],
        },
      },
      ['name', 'time'],
    ),
    _fn(
      'mark_medication',
      'Record one scheduled dose (asks the user to confirm). "skipped" is a '
          'decision the user made; "not_taken" undoes a mark. They are different '
          'facts — do not collapse them.',
      {
        'name': {'type': 'string'},
        'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
        'time': {
          'type': 'string',
          'description': 'HH:MM of the slot; default the first',
        },
        'state': {
          'type': 'string',
          'enum': ['taken', 'skipped', 'not_taken'],
        },
      },
      ['name', 'state'],
    ),
    _fn(
      'remember_preference',
      'Save a user-requested preference only after native confirmation. Never save health measurements as current facts. Memory must be enabled by the user.',
      {
        'text': {'type': 'string', 'maxLength': 500},
      },
      ['text'],
    ),
    _fn('log_journal', 'Log a journal entry (asks the user to confirm).', {
      'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'note': {'type': 'string'},
    }),
    _fn('log_period', 'Log a period start (asks the user to confirm).', {
      'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
    }),
    _fn('start_workout', 'Start a live workout (asks the user to confirm).', {
      'type': {'type': 'string'},
    }),
    _fn(
      'end_workout',
      'End the active workout (asks the user to confirm).',
      {
        'workout_id': {'type': 'string'},
      },
      ['workout_id'],
    ),
    _fn(
      'set_step_goal',
      'Set the daily step goal (asks the user to confirm).',
      {
        'goal': {'type': 'integer'},
      },
      ['goal'],
    ),
  ];
}

class CoachException implements Exception {
  final String message;
  CoachException(this.message);
  @override
  String toString() => message;
}
