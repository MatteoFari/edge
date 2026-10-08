import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// SharedPreferences' test store lets these tests delay/refuse platform writes.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';

Briefing _note({
  String id = 'morning-original',
  String day = '2026-10-08',
  BriefingPeriod period = BriefingPeriod.morning,
  String oneLiner = 'Your briefing is ready.',
  String breakdownMd = '- Review your plan for today.',
}) => Briefing(
  id: id,
  day: day,
  period: period,
  oneLiner: oneLiner,
  breakdownMd: breakdownMd,
  generatedAtMs: 1791450000000,
  inputs: const {},
);

class _ControlledStore extends InMemorySharedPreferencesStore {
  _ControlledStore() : super.empty();

  bool refuseMarkers = false;
  bool throwOnMarker = false;
  Completer<bool>? markerGate;
  int markerWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.startsWith('flutter.ai.briefing.read.')) {
      markerWrites++;
      if (throwOnMarker) throw StateError('Storage unavailable');
      if (refuseMarkers) return false;
      if (markerGate != null && !await markerGate!.future) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => const {'daily': {}};

  @override
  Future<Map<String, dynamic>> getDaySleep(String date) async => const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an unavailable store cannot consume unread state', () async {
    final note = _note(id: 'unavailable-store');
    expect(Prefs.loaded, isFalse);
    expect(await BriefingStore.markRead(note), isFalse);
    expect(BriefingStore.isRead(note), isFalse);
  });

  group('durable briefing read state', () {
    late SharedPreferences preferences;
    late _ControlledStore store;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      preferences = await SharedPreferences.getInstance();
    });

    setUp(() async {
      store = _ControlledStore();
      SharedPreferencesStorePlatform.instance = store;
      // Prefs deliberately retains its instance. Reload that instance from
      // the fresh platform store so every test starts with a clean cache too.
      await preferences.reload();
    });

    test('generation and cache lookup leave a new briefing unread', () async {
      final now = DateTime(2026, 10, 8, 9);
      final engine = BriefingEngine(
        config: CoachConfig(),
        repo: _Repo(),
        complete: ({required system, required user}) async =>
            'Your briefing is ready.\n---\n- Review your plan for today.',
      );
      final note = await engine.generate(BriefingPeriod.morning, now: now);
      final cached = BriefingStore.read(note.period, day: note.day)!;
      expect(cached.id, note.id);
      expect(BriefingStore.isRead(note), isFalse);
      expect(BriefingStore.isRead(cached), isFalse);
      expect(store.markerWrites, 0);
    });

    test(
      'only the opened briefing transitions and repeated marks are idempotent',
      () async {
        final morning = _note();
        final evening = _note(
          id: 'evening-original',
          period: BriefingPeriod.evening,
        );
        final yesterday = _note(id: 'yesterday', day: '2026-10-07');
        BriefingStore.write(morning);
        BriefingStore.write(evening);
        expect(await BriefingStore.markRead(morning), isTrue);
        expect(await BriefingStore.markRead(morning), isTrue);
        expect(BriefingStore.isRead(morning), isTrue);
        expect(BriefingStore.isRead(evening), isFalse);
        expect(BriefingStore.isRead(yesterday), isFalse);
        expect(store.markerWrites, 1);
      },
    );

    test(
      'regenerating identical text at the same timestamp creates a new unread note',
      () async {
        final now = DateTime(2026, 10, 8, 9);
        final engine = BriefingEngine(
          config: CoachConfig(),
          repo: _Repo(),
          complete: ({required system, required user}) async =>
              'A steady start.',
        );
        final old = await engine.generate(BriefingPeriod.morning, now: now);
        expect(await BriefingStore.markRead(old), isTrue);
        final replacement = await engine.generate(
          BriefingPeriod.morning,
          now: now,
        );
        expect(replacement.id, isNot(old.id));
        expect(BriefingStore.isRead(replacement), isFalse);
        expect(BriefingStore.isRead(old), isTrue);
        expect(
          BriefingStore.read(old.period, day: old.day)?.id,
          replacement.id,
        );
        // Replacing a cache slot also must not reset an older note's marker.
        BriefingStore.write(old);
        expect(
          BriefingStore.isRead(BriefingStore.read(old.period, day: old.day)!),
          isTrue,
        );
      },
    );

    test(
      'read and unread identities survive reopening from persisted values',
      () async {
        final morning = _note(id: 'restart-morning');
        final evening = _note(
          id: 'restart-evening',
          period: BriefingPeriod.evening,
        );
        BriefingStore.write(morning);
        BriefingStore.write(evening);
        expect(await BriefingStore.markRead(morning), isTrue);

        // Keep only the acknowledged platform data, then construct a new store
        // and fetch its values into an empty preferences cache as a restart does.
        final persisted = await store.getAll();
        SharedPreferencesStorePlatform.instance =
            InMemorySharedPreferencesStore.empty();
        await preferences.reload();
        expect(BriefingStore.read(morning.period, day: morning.day), isNull);
        expect(BriefingStore.isRead(morning), isFalse);
        SharedPreferencesStorePlatform.instance =
            InMemorySharedPreferencesStore.withData(persisted);
        await preferences.reload();
        final reopenedMorning = BriefingStore.read(
          morning.period,
          day: morning.day,
        )!;
        final reopenedEvening = BriefingStore.read(
          evening.period,
          day: evening.day,
        )!;
        expect(reopenedMorning.id, morning.id);
        expect(reopenedEvening.id, evening.id);
        expect(BriefingStore.isRead(reopenedMorning), isTrue);
        expect(BriefingStore.isRead(reopenedEvening), isFalse);
      },
    );

    test(
      'legacy notes gain a stable identity and retain read state when rewritten',
      () async {
        final legacy = _note(id: 'discarded').toJson()..remove('id');
        final note = Briefing.fromJson(legacy)!;
        final same = Briefing.fromJson(jsonDecode(jsonEncode(legacy)))!;
        expect(note.id, same.id);
        expect(note.id, startsWith('legacy-'));
        expect(BriefingStore.isRead(note), isFalse);
        expect(await BriefingStore.markRead(note), isTrue);
        BriefingStore.write(same);
        final rewritten = BriefingStore.read(note.period, day: note.day)!;
        expect(rewritten.id, note.id);
        expect(BriefingStore.isRead(rewritten), isTrue);
        final different = Briefing.fromJson({
          ...legacy,
          'one_liner': 'Another note.',
        })!;
        expect(different.id, isNot(note.id));
        expect(BriefingStore.isRead(different), isFalse);
      },
    );

    test(
      'missing, corrupt, and wrong-day cache loads do not mark anything read',
      () async {
        final note = _note(id: 'load-failure');
        expect(BriefingStore.read(note.period, day: note.day), isNull);
        BriefingStore.write(note);
        expect(BriefingStore.read(note.period, day: '2026-10-07'), isNull);
        Prefs.setString('ai.briefing.morning', '{broken json');
        expect(BriefingStore.read(note.period, day: note.day), isNull);
        expect(BriefingStore.isRead(note), isFalse);
        expect(store.markerWrites, 0);
      },
    );

    test(
      'a failed regeneration preserves the cached note and its unread state',
      () async {
        final note = _note(id: 'provider-failure');
        BriefingStore.write(note);
        final engine = BriefingEngine(
          config: CoachConfig(),
          repo: _Repo(),
          complete: ({required system, required user}) async =>
              throw StateError('Provider unavailable'),
        );
        await expectLater(
          engine.generate(
            BriefingPeriod.morning,
            now: DateTime(2026, 10, 8, 9),
          ),
          throwsStateError,
        );
        expect(BriefingStore.read(note.period, day: note.day)?.id, note.id);
        expect(BriefingStore.isRead(note), isFalse);
        expect(store.markerWrites, 0);
      },
    );

    test('empty content cannot be marked read', () async {
      final blank = _note(
        id: 'empty-content',
        oneLiner: ' ',
        breakdownMd: '\n',
      );
      expect(await BriefingStore.markRead(blank), isFalse);
      expect(BriefingStore.isRead(blank), isFalse);
      expect(store.markerWrites, 0);
      final singleLine = _note(id: 'single-line', breakdownMd: '');
      expect(await BriefingStore.markRead(singleLine), isTrue);
      expect(BriefingStore.isRead(singleLine), isTrue);
    });

    test('a malformed read marker is unread and can be repaired on opening',
        () async {
      final note = _note(id: 'malformed-marker');
      Prefs.setString('ai.briefing.read.${note.id}', 'broken');
      expect(BriefingStore.isRead(note), isFalse);
      expect(await BriefingStore.markRead(note), isTrue);
      expect(BriefingStore.isRead(note), isTrue);
    });

    test(
      'pending writes stay unread and concurrent openings share the write',
      () async {
        final note = _note(id: 'pending-marker');
        store.markerGate = Completer<bool>();
        final first = BriefingStore.markRead(note);
        final second = BriefingStore.markRead(note);
        expect(BriefingStore.isRead(note), isFalse);
        expect(store.markerWrites, 1);
        store.markerGate!.complete(true);
        expect(await Future.wait([first, second]), [true, true]);
        expect(BriefingStore.isRead(note), isTrue);
      },
    );

    for (final throws in [false, true]) {
      test(
        'a ${throws ? 'throwing' : 'refused'} marker write stays unread and retries',
        () async {
          final note = _note(id: 'failed-marker-$throws');
          store.refuseMarkers = !throws;
          store.throwOnMarker = throws;
          expect(await BriefingStore.markRead(note), isFalse);
          expect(BriefingStore.isRead(note), isFalse);
          await preferences.reload();
          expect(BriefingStore.isRead(note), isFalse);
          store.refuseMarkers = false;
          store.throwOnMarker = false;
          expect(await BriefingStore.markRead(note), isTrue);
          expect(BriefingStore.isRead(note), isTrue);
          expect(store.markerWrites, 2);
        },
      );
    }
  });
}
