// A SCREEN MAY ONLY STATE A CAUSE THE DATA ACTUALLY GAVE IT.
//
// `whyFromNote` is the one place a machine note becomes a sentence, so it is
// also the one place a guess could re-enter. The measured failure it exists to
// stop: the Strain screen printed "it needs a resting heart rate from a scored
// night and a day the band was on your wrist" on a day with a scored night
// (RHR 56.8) and 89 % wear, and the Zones screen offered "Add your age in
// Profile" to a profile whose age was set.
//
// The contract in one line: a note it understands becomes a sentence, a note it
// does not becomes NULL — never a paraphrase, never the raw token on screen.

import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';

void main() {
  group('whyFromNote', () {
    test('nothing said means nothing is said', () {
      expect(whyFromNote(null), isNull);
      expect(whyFromNote(''), isNull);
      expect(whyFromNote('   '), isNull);
      // The pipeline's own "we could not attribute this" marker. It exists so
      // an absence never borrows a plausible reason, so it renders as none.
      expect(whyFromNote('unknown_cause'), isNull);
    });

    test('an unrecognised machine token is not a sentence', () {
      // Not paraphrased, and not dumped on screen either. A key added after
      // this map was written must degrade to "we do not know".
      expect(whyFromNote('some_new_gate:id=7'), isNull);
      expect(whyFromNote('need_input:name=cosmic_rays'), isNull);
    });

    test('prose notes pass through as written', () {
      const p = 'HF peak unstable across spectral resolutions — withheld';
      expect(whyFromNote(p), p);
      // A colon FOLLOWED BY A SPACE is prose, not a token.
      expect(whyFromNote('refused: the red and IR channels are one signal'),
          startsWith('refused:'));
    });

    test('need_baseline keeps its "Need N more" wording, per unit', () {
      expect(whyFromNote('need_baseline:have=4,need=7'), 'Need 3 more nights');
      expect(whyFromNote('need_baseline:have=0,need=14', unit: 'days'),
          'Wear 14 more days to unlock');
    });

    test('need_input names the INPUT, and counts it when it is countable', () {
      // The input, never the metric that wanted it: "calories" is not something
      // a user can go and fix.
      expect(whyFromNote('need_input:name=weight_kg'),
          contains('weight is not on file'));
      expect(whyFromNote('need_input:name=age'), contains('age is not on file'));
      expect(whyFromNote('need_input:name=wake_hr'),
          contains('No waking heart rate'));
      expect(whyFromNote('need_input:name=nn_beats,have=12,need=20'),
          endsWith('There were 12, and it needs 20.'));
    });

    test('complete sleep time requires a complete recording, not better sleep', () {
      const note = 'need_input:name=complete_tst';
      expect(whyFromNote(note), 'The sleep recording for that night is incomplete.');
      expect(whyFromNote(note, l: lookupAppLocalizations(const Locale('en'))),
          'The sleep recording for that night is incomplete.');
      expect(whyFromNote(note, l: lookupAppLocalizations(const Locale('it'))),
          'La registrazione del sonno di quella notte è incompleta.');
    });

    test('a missing prospective target is a missing saved plan', () {
      const note = 'need_input:name=prospective_sleep_target';
      expect(whyFromNote(note), 'No sleep target was saved before this night began.');
      expect(whyFromNote(note, l: lookupAppLocalizations(const Locale('en'))),
          'No sleep target was saved before this night began.');
      expect(whyFromNote(note, l: lookupAppLocalizations(const Locale('it'))),
          'Non era stato salvato un obiettivo di sonno prima dell’inizio di questa notte.');
    });

    // The map degrades SILENTLY: a name with no sentence renders as "we do not
    // know", which is safe and says nothing. This is what notices.
    test('every need_input name lib/ emits has a sentence', () {
      final emitted = <String>{};
      final re = RegExp(r"needInputNote\(\s*'([a-z0-9_]+)'");
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final m in re.allMatches(f.readAsStringSync())) {
          emitted.add(m.group(1)!);
        }
      }
      expect(emitted, isNotEmpty, reason: 'the convention moved');
      for (final name in emitted) {
        expect(whyFromNote('need_input:name=$name'), isNotNull,
            reason: 'no sentence for "$name" — add one to _inputWhy in '
                'lib/models/metric.dart, or every screen it reaches says it '
                'does not know why');
        for (final code in ['en', 'it']) {
          expect(whyFromNote('need_input:name=$name',
              l: lookupAppLocalizations(Locale(code))), isNotEmpty,
              reason: 'missing $code explanation for "$name"');
        }
      }
    });

    test('unknown_device_family says what it is, not what a screen guessed', () {
      final s = whyFromNote('unknown_device_family:id=none')!;
      expect(s, contains('which strap'));
      // It is emphatically NOT a missing-age or a missing-wear story, which is
      // what the two affected screens used to print.
      expect(s.toLowerCase(), isNot(contains('age')));
      expect(s.toLowerCase(), isNot(contains('wrist')));
    });
  });
}
