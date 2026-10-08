import 'dart:convert';

import 'package:http/http.dart' as http;

class CoachStreamException implements Exception {
  const CoachStreamException(this.message);
  final String message;
}

/// An SSE response whose tool fragments cannot be safely associated. Nothing
/// from that response has executed; the caller may request an ordinary reply.
class CoachStreamToolAssociationException extends CoachStreamException {
  const CoachStreamToolAssociationException()
    : super('The provider sent ambiguous streamed tool calls.');
}

void _mergeMetadata(Map<String, dynamic> target, Map source) {
  for (final entry in source.entries) {
    final key = entry.key.toString(), value = entry.value;
    if (!target.containsKey(key)) {
      target[key] = value is Map ? Map<String, dynamic>.from(value) : value;
    } else if (value is Map && target[key] is Map) {
      final nested = Map<String, dynamic>.from(target[key] as Map);
      _mergeMetadata(nested, value);
      target[key] = nested;
    } else if (jsonEncode(target[key]) != jsonEncode(value)) {
      throw const CoachStreamToolAssociationException();
    }
  }
}

bool _completeArguments(String value) {
  try {
    return jsonDecode(value) is Map;
  } catch (_) {
    return false;
  }
}

/// Actual server-sent deltas. Tools are returned only after a complete stream;
/// partially received tool arguments never reach a native action.
Future<Map<String, dynamic>> readCoachStream(
  http.StreamedResponse response, {
  required void Function(String) onText,
  required void Function() checkCancelled,
}) async {
  final text = StringBuffer(), tools = <int, Map<String, dynamic>>{};
  final idIndexes = <String, int>{}, metadata = <String, dynamic>{};
  var done = false, finished = false, bytes = 0;
  final data = <String>[];
  void event() {
    if (data.isEmpty) return;
    final value = data.join('\n');
    data.clear();
    if (value == '[DONE]') {
      done = true;
      return;
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      throw const CoachStreamException(
        'The provider sent an invalid streamed event.',
      );
    }
    if (decoded['error'] != null) {
      throw CoachStreamException('Provider stream error: ${decoded['error']}');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return;
    final choice = choices.first;
    if (choice is! Map) {
      throw const CoachStreamException(
        'The provider sent an invalid streamed choice.',
      );
    }
    final reason = choice['finish_reason'];
    if (reason != null) {
      finished = true;
    }
    final delta = choice['delta'];
    if (delta is! Map) {
      if (reason == 'length' || reason == 'content_filter') {
        throw const CoachStreamException(
          'The provider ended this reply before it was complete. Retry or ask a narrower question.',
        );
      }
      return;
    }
    final content = delta['content'] ?? delta['refusal'];
    if (delta['extra_content'] is Map) {
      _mergeMetadata(metadata, {'extra_content': delta['extra_content']});
    }
    if (content is String && content.isNotEmpty) {
      text.write(content);
      onText(text.toString());
    }
    final calls = delta['tool_calls'];
    if (calls is List) {
      for (final call in calls) {
        if (call is! Map) throw const CoachStreamToolAssociationException();
        final id = call['id'] is String ? call['id'] as String : '';
        final fn = call['function'];
        final rawIndex = call['index'];
        final int index;
        if (rawIndex is num &&
            rawIndex.isFinite &&
            rawIndex == rawIndex.toInt()) {
          index = rawIndex.toInt();
          if (id.isNotEmpty &&
              idIndexes[id] != null &&
              idIndexes[id] != index) {
            throw const CoachStreamToolAssociationException();
          }
        } else if (rawIndex != null) {
          throw const CoachStreamToolAssociationException();
        } else if (id.isNotEmpty) {
          // Gemini's OpenAI compatibility path can omit index while retaining
          // the complete call ID. IDs safely associate parallel/reordered calls.
          var candidate = idIndexes[id] ?? 0;
          if (!idIndexes.containsKey(id)) {
            while (tools.containsKey(candidate)) {
              candidate++;
            }
          }
          index = candidate;
        } else if (calls.length == 1 && tools.length == 1) {
          // An unnamed continuation of one known call is unambiguous. Never
          // infer a parallel call's identity from its current array position.
          final previous = tools.values.single;
          final previousFn = previous['function'] as Map;
          final name = fn is Map ? fn['name'] : null;
          final arguments = fn is Map ? fn['arguments'] : null;
          if ((previous['id'] as String).isEmpty ||
              (name != null && name != '' && name != previousFn['name']) ||
              (arguments != null &&
                  arguments != '' &&
                  _completeArguments(previousFn['arguments'] as String))) {
            // More anonymous arguments after a complete call could start a
            // second call, even if it happens to use the same function name.
            throw const CoachStreamToolAssociationException();
          }
          index = tools.keys.single;
        } else {
          throw const CoachStreamToolAssociationException();
        }
        if (index < 0 || index >= 32) {
          throw const CoachStreamException(
            'The provider sent too many streamed tools.',
          );
        }
        final tool = tools.putIfAbsent(
          index,
          () => {
            'id': '',
            'type': 'function',
            'function': <String, dynamic>{'name': '', 'arguments': ''},
          },
        );
        if (id.isNotEmpty) {
          if ((tool['id'] as String).isNotEmpty && tool['id'] != id) {
            throw const CoachStreamToolAssociationException();
          }
          tool['id'] = id;
          idIndexes[id] = index;
        }
        _mergeMetadata(tool, {
          for (final entry in call.entries)
            if (!const {'index', 'id', 'type', 'function'}.contains(entry.key))
              entry.key.toString(): entry.value,
        });
        if (fn is Map) {
          final target = tool['function'] as Map;
          final name = fn['name'];
          if (name is String && name.isNotEmpty && name != target['name']) {
            target['name'] = '${target['name']}$name';
          }
          final arguments = fn['arguments'];
          if (arguments is Map) {
            final encoded = jsonEncode(arguments);
            if ((target['arguments'] as String).isEmpty) {
              target['arguments'] = encoded;
            } else if (target['arguments'] != encoded) {
              throw const CoachStreamToolAssociationException();
            }
          } else if (arguments is String && arguments.isNotEmpty) {
            final previous = target['arguments'] as String;
            // Some adapters repeat a whole completed call beside later deltas.
            // Repeating it is neither another tool nor another JSON fragment.
            if (arguments != previous || !_completeArguments(previous)) {
              target['arguments'] = '$previous$arguments';
            }
          }
          _mergeMetadata(tool['function'] as Map<String, dynamic>, {
            for (final entry in fn.entries)
              if (!const {'name', 'arguments'}.contains(entry.key))
                entry.key.toString(): entry.value,
          });
        }
      }
    }
    if (text.length +
            tools.values.fold<int>(0, (n, t) => n + jsonEncode(t).length) +
            jsonEncode(metadata).length >
        120000) {
      throw const CoachStreamException(
        'The provider reply grew too large. Ask a narrower question.',
      );
    }
    if (reason == 'length' || reason == 'content_filter') {
      throw const CoachStreamException(
        'The provider ended this reply before it was complete. Retry or ask a narrower question.',
      );
    }
  }

  final bounded = response.stream.map((chunk) {
    checkCancelled();
    bytes += chunk.length;
    if (bytes > 4 * 1024 * 1024) {
      throw const CoachStreamException(
        'The provider stream grew too large. Ask a narrower question.',
      );
    }
    return chunk;
  });
  await for (final line
      in bounded.transform(utf8.decoder).transform(const LineSplitter())) {
    checkCancelled();
    if (line.isEmpty) {
      event();
      if (done) break;
    } else if (line.startsWith('data:')) {
      data.add(line.substring(5).trimLeft());
    }
  }
  if (!done) event();
  checkCancelled();
  if (!done && !finished) {
    throw const CoachStreamException(
      'The connection ended before the provider finished. Your partial reply was kept.',
    );
  }
  final ordered = tools.keys.toList()..sort();
  for (final key in ordered) {
    final tool = tools[key]!, fn = tool['function'] as Map;
    if ((tool['id'] as String).isEmpty || (fn['name'] as String).isEmpty) {
      throw const CoachStreamException(
        'The provider did not finish a tool call. No action was taken.',
      );
    }
    try {
      if (jsonDecode(fn['arguments'] as String) is! Map) {
        throw const FormatException();
      }
    } catch (_) {
      throw const CoachStreamException(
        'The provider did not finish valid tool arguments. No action was taken.',
      );
    }
  }
  return {
    ...metadata,
    'role': 'assistant',
    'content': text.toString(),
    if (tools.isNotEmpty) 'tool_calls': [for (final i in ordered) tools[i]],
  };
}
