// briefing.dart — the daily AI briefing value type + its on-device cache.
//
// A Briefing is one generated note for one local day + period (morning = last
// night's sleep/recovery; evening = the nightly sweep, which is findings about
// today or nothing at all — see nightly_sweep.dart). It carries
// BOTH the notification-length one-liner and the short structured breakdown,
// plus the exact inputs snapshot it was generated from (so the breakdown screen
// can show "based on" metrics without re-querying, and regeneration is honest
// about what the model saw).
//
// Storage: SharedPreferences via the synchronous `Prefs` façade — one slot per
// period, newest-wins. Today's card reads it synchronously at build (no async
// flash); a stale (previous-day) slot simply reads back as null. This is a
// cache, not a record: losing it only means a regenerate.
// Read state is separate from those replaceable slots and keyed to each
// generated note, so writing a replacement never consumes its unread state.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/day_label.dart';
import '../state/prefs.dart';

enum BriefingPeriod { morning, evening }

extension BriefingPeriodLabel on BriefingPeriod {
  String get id => this == BriefingPeriod.morning ? 'morning' : 'evening';
  String get title =>
      this == BriefingPeriod.morning ? 'Morning briefing' : 'Nightly sweep';
}

/// Which period the Today card should surface right now. Mornings through the
/// afternoon show the morning briefing; from 17:00 the evening recap takes over
/// (falling back to the cached morning one until the recap exists).
BriefingPeriod currentBriefingPeriod(DateTime now) =>
    now.hour >= 17 ? BriefingPeriod.evening : BriefingPeriod.morning;

class Briefing {
  final String? _storedId;

  /// Local day label (YYYY-MM-DD) the briefing belongs to.
  final String day;
  final BriefingPeriod period;

  /// Notification-length single sentence (plain text, no markdown).
  final String oneLiner;

  /// Short structured markdown breakdown (a few bullets — not an essay).
  final String breakdownMd;

  final int generatedAtMs;

  /// The compact metric snapshot the prompt was built from (only fields that
  /// were actually present — absent metrics are never fabricated).
  final Map<String, dynamic> inputs;

  /// Historical request provenance, without API keys or URL credentials.
  /// Null for legacy notes whose provider was never saved.
  final String? providerOrigin, model;

  const Briefing({
    String? id,
    required this.day,
    required this.period,
    required this.oneLiner,
    required this.breakdownMd,
    required this.generatedAtMs,
    required this.inputs,
    this.providerOrigin,
    this.model,
  }) : _storedId = id;

  /// Identity of one generated note, preserved when its cache slot is read.
  /// Older cached notes have no ID; their generation metadata and text supply
  /// a deterministic identity without changing or rewriting their contents.
  String get id {
    final stored = _storedId;
    if (stored != null && stored.isNotEmpty) return stored;
    final legacy = jsonEncode([
      day,
      period.id,
      generatedAtMs,
      oneLiner,
      breakdownMd,
    ]);
    return 'legacy-${sha256.convert(utf8.encode(legacy))}';
  }

  /// Whether producing this note involved a model at all.
  ///
  /// The nightly sweep with no findings is written on-device and asks nobody:
  /// no request, no payload, nothing to disclose. THE one place that rule is
  /// stated — the "what was sent" screen reads it rather than re-deriving it,
  /// because a screen that guesses wrong about this is the worst bug this app
  /// can ship.
  bool get calledModel =>
      period != BriefingPeriod.evening || inputs.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'day': day,
        'period': period.id,
        'one_liner': oneLiner,
        'breakdown_md': breakdownMd,
        'generated_at_ms': generatedAtMs,
        'inputs': inputs,
        if (providerOrigin != null) 'provider_origin': providerOrigin,
        if (model != null) 'model': model,
      };

  static Briefing? fromJson(dynamic j) {
    if (j is! Map) return null;
    final day = j['day'];
    final one = j['one_liner'];
    if (day is! String || one is! String) return null;
    final id = j['id'];
    return Briefing(
      id: id is String && id.isNotEmpty ? id : null,
      day: day,
      period: j['period'] == 'evening'
          ? BriefingPeriod.evening
          : BriefingPeriod.morning,
      oneLiner: one,
      breakdownMd: (j['breakdown_md'] as String?) ?? '',
      generatedAtMs: (j['generated_at_ms'] as num?)?.toInt() ?? 0,
      inputs: j['inputs'] is Map
          ? (j['inputs'] as Map).cast<String, dynamic>()
          : const {},
      providerOrigin: j['provider_origin'] is String ? j['provider_origin'] : null,
      model: j['model'] is String ? j['model'] : null,
    );
  }
}

/// Resolves which period's briefing an entry point meaning "today's
/// briefing" (Home's link row, a generic notification tap) should actually
/// show, per [currentBriefingPeriod]'s own documented fallback: past 17:00 it
/// returns [BriefingPeriod.evening] even when nothing has been written there
/// yet, "falling back to the cached morning one until [it] exists."
///
/// [current] is [BriefingStore.read] for [period]; [morningFallback] is the
/// same for [BriefingPeriod.morning] — passed in rather than read here so
/// this stays a pure function, testable without touching SharedPreferences.
({BriefingPeriod period, Briefing? briefing}) resolveBriefingToShow(
  BriefingPeriod period,
  Briefing? current,
  Briefing? morningFallback,
) {
  if (current != null) return (period: period, briefing: current);
  if (morningFallback != null) {
    return (period: BriefingPeriod.morning, briefing: morningFallback);
  }
  return (period: period, briefing: null);
}

/// Per-day+period briefing cache + the journal "done for today" flag.
class BriefingStore {
  BriefingStore._();

  static String _slotKey(BriefingPeriod p) => 'ai.briefing.${p.id}';
  static String _readKey(String id) => 'ai.briefing.read.$id';
  static const String _kJournalDoneDay = 'ai.journal_done_day';
  static final Map<String, Future<bool>> _readWrites = {};
  static final Set<String> _uncommittedReadIds = {};

  /// Synchronous read of the cached briefing for [period]. Returns null when
  /// nothing is cached or the cached slot belongs to a different day than
  /// [day] (default: today, local).
  static Briefing? read(BriefingPeriod period, {String? day}) {
    final raw = Prefs.getString(_slotKey(period), '');
    if (raw.isEmpty) return null;
    try {
      final b = Briefing.fromJson(jsonDecode(raw));
      if (b == null) return null;
      if (b.day != (day ?? todayLabel())) return null;
      return b;
    } catch (_) {
      return null;
    }
  }

  static void write(Briefing b) =>
      Prefs.setString(_slotKey(b.period), jsonEncode(b.toJson()));

  /// Reading the cache or generating a note never changes this marker.
  static bool isRead(Briefing b) {
    if (_uncommittedReadIds.contains(b.id)) return false;
    try {
      return Prefs.getBool(_readKey(b.id), false);
    } catch (_) {
      return false;
    }
  }

  /// Call only after this note's content has successfully been displayed.
  /// The marker becomes visible after storage acknowledges it, and repeated
  /// calls for the same note share one write. Empty/failed loads cannot consume
  /// unread state. A failed write can be retried on a subsequent opening.
  static Future<bool> markRead(Briefing b) {
    if (b.oneLiner.trim().isEmpty && b.breakdownMd.trim().isEmpty) {
      return Future.value(false);
    }
    if (isRead(b)) return Future.value(true);
    return _readWrites[b.id] ??= _persistRead(b.id);
  }

  static Future<bool> _persistRead(String id) async {
    // SharedPreferences sets its cache before the platform acknowledges a
    // write. Keep pending/refused markers unread instead of trusting that
    // optimistic cache as evidence of persistence.
    _uncommittedReadIds.add(id);
    try {
      final saved = await Prefs.setBoolAcked(_readKey(id), true);
      if (saved) _uncommittedReadIds.remove(id);
      return saved;
    } finally {
      _readWrites.remove(id);
    }
  }

  // ── journal "done for today" (suppresses tonight's pre-sleep nudge) ─────────

  static void markJournalDone([String? day]) =>
      Prefs.setString(_kJournalDoneDay, day ?? todayLabel());

  static bool journalDoneToday([String? day]) =>
      Prefs.getString(_kJournalDoneDay, '') == (day ?? todayLabel());
}
