# Personal-fork respiratory-rate build

Build with `--dart-define=EXPERIMENTAL_RESPIRATION=true`. Normal builds leave
the experiment off. The experimental build uses algorithm version 110 and the
matching full analytics SHA in `pubspec.yaml` / `kAnalyticsPin`.

The tested analytics commit is published to `MatteoFari/analytics` on
`feat/experimental-respiration`. Edge resolves that fork directly through the
full commit SHA in `pubspec.yaml` and `pubspec.lock`; no local dependency
override is required. Keep the commit pin rather than a floating branch ref.

Accepted estimates persist as `resp_rate_experimental` and an experimental
envelope with window diagnostics in `day_result`. Health, Sleep, expanded
Recovery and the experimental detail chart read that envelope. At the user’s request,
the visible reading is named “Breathing rate” without
the experimental advice text. The internal experimental marker and separate
series remain; Recovery shows no standard-method baseline comparison.
Missing representative evidence stays blank. Imported/older bundles retain their original values and labels.

The canonical `resp_rate` scalar and its history remain untouched by the
experiment. Recovery scoring, illness/anomaly inputs and Health Connect /
HealthKit export keep the standard method. The experiment retains uncalibrated
confidence in its stored metadata. It missed one WHOOP rise in the local
comparison; agreement with WHOOP does not establish independent accuracy.

The algorithm bump recomputes nights whose raw data remains on the phone.
Already-pruned raw beats cannot be recovered by the estimator. No schema
change, destructive migration or backup rewrite is needed.

App checks: `flutter test test/experimental_respiration_test.dart
test/experimental_respiration_ui_test.dart test/experimental_respiration_pin_test.dart`.
Private replay data is kept outside Git.
