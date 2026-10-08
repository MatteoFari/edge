import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAnalyticsPin;

void main() {
  test('the app pin contains the experimental respiratory method', () async {
    if (!Directory('../analytics').existsSync()) {
      markTestSkipped('no sibling analytics checkout');
      return;
    }
    final result = await Process.run('git', [
      'show', '$kAnalyticsPin:lib/src/onehz/respiration/experimental_resp_rate.dart',
    ], workingDirectory: '../analytics');
    expect(result.exitCode, 0);
    expect(result.stdout, contains('ExperimentalRespResult experimentalRsaRespRate'));
    expect(File('pubspec.yaml').readAsStringSync(), contains('ref: $kAnalyticsPin'));
  });
}
