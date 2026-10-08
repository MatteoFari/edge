import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';

class _Repo extends LocalRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a viewed date stays with its turn without replacing today or transcript',
    () async {
      final cfg = CoachConfig();
      await cfg.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
      final requests = <Map<String, dynamic>>[];
      final engine = CoachEngine(
        config: cfg,
        api: _Repo(),
        client: MockClient((req) async {
          requests.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': 'A saved-day answer',
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(engine.dispose);
      addTearDown(cfg.dispose);
      await engine.send(
        'Explain my sleep',
        viewingDay: '2026-10-07',
        viewingSection: 'Home',
        onItem: (_) {},
        onStatus: (_) {},
        confirm: (_) async => false,
      );
      await engine.send(
        'And my workout?',
        viewingDay: '2026-10-08',
        viewingSection: 'Workout',
        onItem: (_) {},
        onStatus: (_) {},
        confirm: (_) async => false,
      );
      final messages = requests.last['messages'] as List;
      expect(messages.first['content'], contains('Today is ${todayLabel()}'));
      final user = messages.where((m) => m['role'] == 'user').toList();
      expect(user.first['content'], contains('Home, local day 2026-10-07'));
      expect(user.last['content'], contains('Workout, local day 2026-10-08'));
      expect(engine.transcript.first.text, 'Explain my sleep');
      expect(engine.transcript[2].text, 'And my workout?');
    },
  );
}
