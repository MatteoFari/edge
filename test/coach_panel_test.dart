import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_store.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart';
import 'package:openstrap_edge/ui2/screens/coach_host.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Paths extends PathProviderPlatform {
  final String path;
  _Paths(this.path);
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Repo extends LocalRepository {}

class _RequestGuard extends HttpOverrides {
  final bool holdRequests;
  _RequestGuard({this.holdRequests = false});
  final clients = <_GuardClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = _GuardClient(holdRequests: holdRequests);
    clients.add(client);
    return client;
  }
}

class _GuardClient implements HttpClient {
  final bool holdRequests;
  final pending = Completer<HttpClientRequest>();
  _GuardClient({this.holdRequests = false});
  int requests = 0;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests++;
    if (holdRequests) return pending.future;
    throw StateError('Opening or resizing Coach must not send a request');
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WriteRepo extends _Repo {
  int writes = 0;
  @override
  Future<Map<String, dynamic>> setStepGoal(int goal) async {
    writes++;
    return {};
  }
}

/// A synthetic provider transport only: its first response is released after
/// the real UI leaves the transcript. No socket or production hook is used.
class _DelayedToolProvider extends HttpOverrides {
  _DelayedToolProvider({bool streamReply = false})
    : client = _DelayedToolClient(streamReply: streamReply);
  final _DelayedToolClient client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

class _DelayedToolClient implements HttpClient {
  _DelayedToolClient({this.streamReply = false});
  final bool streamReply;
  late final reply = StreamController<List<int>>();
  final proposal = Completer<void>();
  final requests = <Map<String, dynamic>>[];
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _ToolRequest(this);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ToolRequest implements HttpClientRequest {
  _ToolRequest(this.client);
  final _DelayedToolClient client;
  final _bytes = <int>[];
  // IOClient configures these before piping the request body into the sink.
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  final HttpHeaders headers = _ToolHeaders();
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      _bytes.addAll(bytes);
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    client.requests.add(
      jsonDecode(utf8.decode(_bytes)) as Map<String, dynamic>,
    );
    if (client.streamReply) return _ToolResponse.streaming(client.reply.stream);
    if (client.requests.length == 1) {
      await client.proposal.future;
      return _ToolResponse({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'tool_calls': [
                {
                  'id': 'delayed-write',
                  'type': 'function',
                  'function': {
                    'name': 'set_step_goal',
                    'arguments': '{"goal":9000}',
                  },
                },
              ],
            },
          },
        ],
      });
    }
    return _ToolResponse({
      'choices': [
        {
          'message': {
            'role': 'assistant',
            'content': 'The proposed change was not saved.',
          },
        },
      ],
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ToolHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  void forEach(void Function(String, List<String>) action) =>
      _values.forEach(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ToolResponse extends Stream<List<int>> implements HttpClientResponse {
  _ToolResponse(Map<String, dynamic> body)
    : _bytes = utf8.encode(jsonEncode(body)),
      _stream = null;
  _ToolResponse.streaming(this._stream) : _bytes = const [];
  final List<int> _bytes;
  final Stream<List<int>>? _stream;
  @override
  int get statusCode => HttpStatus.ok;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => _stream == null ? _bytes.length : -1;
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  List<RedirectInfo> get redirects => [];
  @override
  HttpHeaders get headers => _ToolHeaders()
    ..set(
      'content-type',
      _stream == null ? 'application/json' : 'text/event-stream',
    );
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => (_stream ?? Stream<List<int>>.value(_bytes)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late CoachConfig config;
  late AppState app;
  late Directory dir;
  late PathProviderPlatform previousPaths;
  late String previousDbName;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDb.close();
    previousDbName = LocalDb.dbName;
    dir = await Directory.systemTemp.createTemp('coach-panel-test-');
    LocalDb.dbName = '${dir.path}/coach-panel.db';
    await LocalDb.instance;
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    config = CoachConfig();
    app = AppState.forTesting()..repo = _Repo();
  });
  tearDown(() async {
    app.dispose();
    config.dispose();
    PathProviderPlatform.instance = previousPaths;
    await LocalDb.close();
    LocalDb.dbName = previousDbName;
    await dir.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester t, {
    double scale = 1,
    bool reduced = true,
    double? keyboard,
    EdgeInsets padding = EdgeInsets.zero,
    bool accessible = false,
    ScrollPhysics? physics,
    Widget Function(BuildContext)? page,
    InterfaceStyle style = InterfaceStyle.expressive,
  }) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<CoachConfig>.value(value: config),
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ThemeController>(
            create: (_) => ThemeController.seed(
              AppThemeChoice.dark,
              Brightness.dark,
              interfaceStyle: style,
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, style: style),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduced,
              accessibleNavigation: accessible,
              viewInsets: keyboard == null
                  ? MediaQuery.of(c).viewInsets
                  : EdgeInsets.only(bottom: keyboard),
              padding: padding,
              viewPadding: padding,
            ),
            child: child!,
          ),
          home: CoachHost(
            domain: ShellDomain.home,
            builder: (c, entry) => AppShell(
              coachEntry: entry,
              builder: (c, domain) =>
                  page?.call(c) ??
                  ListView(
                    key: const ValueKey('page-list'),
                    physics: physics,
                    children: [
                      Builder(
                        builder: (c) => Pressable(
                          semanticLabel: 'Open Coach',
                          onTap: () => openCoach(c),
                          child: const Text('Open Coach'),
                        ),
                      ),
                      for (var i = 0; i < 30; i++)
                        SizedBox(height: 80, child: Text('Reading $i')),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  bool entryHidden(WidgetTester t) => find
      .ancestor(
        of: find.byKey(const ValueKey('coach-entry')),
        matching: find.byType(IgnorePointer),
      )
      .evaluate()
      .any((e) => (e.widget as IgnorePointer).ignoring);

  ScrollPosition pagePosition(WidgetTester t) => t
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('page-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  Future<void> open(WidgetTester t) async {
    await t.tap(find.text('Open Coach'));
    await t.pump(const Duration(milliseconds: 500));
    for (var i = 0; i < 30; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 50));
      if (config.configured &&
          find
              .byKey(const ValueKey('coach-composer-input'))
              .evaluate()
              .isNotEmpty) {
        break;
      }
    }
    await t.pumpAndSettle();
    if (config.configured) {
      expect(
        find.byKey(const ValueKey('coach-composer-input')),
        findsOneWidget,
        reason: find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .join(' | '),
      );
    }
  }

  testWidgets(
    'scrolling toward the top reveals; idle shrinks; farther down hides',
    (t) async {
      await mount(t);
      final entry = find.byKey(const ValueKey('coach-entry'));
      final list = find.byKey(const ValueKey('page-list'));
      pagePosition(t).jumpTo(400);
      await t.pump();
      await t.drag(list, const Offset(0, 200));
      await t.pump();
      expect(pagePosition(t).pixels, lessThan(400));
      final expanded = t.getSize(entry);
      expect(t.getRect(entry).right, greaterThan(350));
      expect(expanded.width, greaterThan(100));
      await t.pump(Motion.coachSettle);
      await t.pumpAndSettle();
      expect(t.getSize(entry).width, lessThan(expanded.width));
      final logo = find.descendant(
        of: entry,
        matching: find.byType(SvgPicture),
      );
      expect(logo, findsOneWidget);
      expect(t.getSize(logo), const Size(S.x8, S.x8));
      expect(t.getCenter(logo), t.getCenter(entry));
      await t.drag(list, const Offset(0, -120));
      await t.pumpAndSettle();
      final ignore = find.ancestor(
        of: entry,
        matching: find.byType(IgnorePointer),
      );
      expect(
        ignore.evaluate().any((e) => (e.widget as IgnorePointer).ignoring),
        isTrue,
      );
    },
  );

  testWidgets('compact, full and reopen retain the same chat and draft', (
    t,
  ) async {
    await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
    await mount(t);
    await open(t);
    final surface = find.byKey(const ValueKey('coach-panel-surface'));
    final compactHeight = t.getSize(surface).height;
    expect(compactHeight, lessThan(844 * .8));
    final state = t.state(find.byType(CoachScreen));
    await t.enterText(find.byType(TextField), 'Keep this draft');
    await t.tap(find.byKey(const ValueKey('coach-panel-expand')));
    await t.pumpAndSettle();
    expect(t.getSize(surface).height, greaterThan(compactHeight));
    expect(t.state(find.byType(CoachScreen)), same(state));
    expect(
      t.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this draft',
    );
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(t.getSize(surface).height, compactHeight);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byType(CoachScreen), findsNothing);
    await t.tap(find.byKey(const ValueKey('coach-entry')));
    await t.pumpAndSettle();
    expect(t.state(find.byType(CoachScreen)), same(state));
    expect(
      t.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this draft',
    );
  });

  testWidgets('tapping the composer opens keyboard on first open and reopen', (
    t,
  ) async {
    await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
    for (final reduced in [false, true]) {
      await mount(t, reduced: reduced, accessible: true);
      await open(t);
      expect(t.testTextInput.isVisible, isFalse);
      final field = find.byType(TextField);
      await t.tap(field);
      await t.pumpAndSettle();
      expect(t.testTextInput.hasAnyClients, isTrue);
      expect(t.testTextInput.isVisible, isTrue);
      expect(
        t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
        isTrue,
      );
      await t.tap(find.byKey(const ValueKey('coach-panel-close')));
      await t.pumpAndSettle();
      expect(t.testTextInput.isVisible, isFalse);
      await t.tap(find.byKey(const ValueKey('coach-entry')));
      await t.pumpAndSettle();
      await t.tap(field);
      await t.pumpAndSettle();
      expect(t.testTextInput.hasAnyClients, isTrue);
      expect(t.testTextInput.isVisible, isTrue);
      expect(
        t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
        isTrue,
      );
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
    }
  });

  testWidgets('Android accessibility preserves reveal, idle shrink and hide', (
    t,
  ) async {
    for (final reduced in [false, true]) {
      await mount(
        t,
        accessible: true,
        reduced: reduced,
        physics: const ClampingScrollPhysics(),
      );
      final entry = find.byKey(const ValueKey('coach-entry'));
      final list = find.byKey(const ValueKey('page-list'));
      expect(entryHidden(t), isTrue);
      await t.drag(list, const Offset(0, 160));
      await t.pumpAndSettle();
      expect(entryHidden(t), isFalse);
      expect(t.getSize(entry).width, greaterThan(100));
      await t.pump(Motion.coachSettle);
      await t.pumpAndSettle();
      expect(t.getSize(entry).width, S.tap + S.x2);
      pagePosition(t).jumpTo(0);
      await t.pumpAndSettle();
      await t.drag(list, const Offset(0, -160));
      await t.pumpAndSettle();
      expect(entryHidden(t), isTrue);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
    }
  });

  testWidgets('keyboard stays above composer; Back hides it before resizing', (
    t,
  ) async {
    await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
    await mount(t);
    await open(t);
    await t.tap(find.byKey(const ValueKey('coach-panel-expand')));
    await t.pumpAndSettle();
    final surface = find.byKey(const ValueKey('coach-panel-surface'));
    final field = find.byKey(const ValueKey('coach-composer-input'));
    final send = find.byKey(const ValueKey('coach-composer-send'));
    await t.tap(field);
    await t.pump();
    t.testTextInput.enterText('Keep this draft');
    t.view.viewInsets = const FakeViewPadding(bottom: 260);
    await t.pumpAndSettle();
    final focus = t.widget<TextField>(field).focusNode!;
    expect(focus.hasFocus, isTrue);
    expect(t.testTextInput.isVisible, isTrue);
    expect(t.getRect(surface).bottom, 844 - 260);
    expect(t.getRect(field).bottom, lessThanOrEqualTo(844 - 260));
    expect(t.getRect(send).bottom, lessThanOrEqualTo(844 - 260));
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(focus.hasFocus, isFalse);
    expect(t.testTextInput.isVisible, isFalse);
    t.view.viewInsets = const FakeViewPadding();
    await t.pumpAndSettle();
    expect(t.getSize(surface).height, 844);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(t.getSize(surface).height, lessThan(844 * .8));
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byType(CoachScreen), findsNothing);
    await t.tap(find.byKey(const ValueKey('coach-entry')));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(field).controller!.text, 'Keep this draft');
    expect(t.widget<TextField>(field).focusNode, same(focus));
    expect(t.testTextInput.isVisible, isFalse);
  });

  testWidgets(
    'composer aligns single and multiline input with the send control',
    (t) async {
      await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
      await mount(t);
      await open(t);
      final field = find.byKey(const ValueKey('coach-composer-input'));
      final send = find.byKey(const ValueKey('coach-composer-send'));
      final p = P.of(t.element(send));
      Container sendSurface() => t.widget<Container>(
        find.descendant(of: send, matching: find.byType(Container)).first,
      );
      expect((sendSurface().decoration! as BoxDecoration).color, p.card2);
      for (final text in [
        'A question',
        'A longer question\nwith another line\nand a third line',
      ]) {
        await t.enterText(field, text);
        await t.pumpAndSettle();
        expect(
          t.getRect(field).center.dy,
          closeTo(t.getRect(send).center.dy, .1),
        );
        expect(
          (sendSurface().decoration! as BoxDecoration).color,
          p.fill(kCoachAccent),
        );
        expect(t.widget<TextField>(field).cursorColor, p.on(kCoachAccent));
        expect(t.getSize(send).shortestSide, greaterThanOrEqualTo(S.tap));
        expect(t.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'Chats and Personalization fade and grow inside the retained panel',
    (t) async {
      await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
      await mount(t, reduced: false);
      await open(t);
      final field = find.byKey(const ValueKey('coach-composer-input'));
      await t.enterText(field, 'Keep this draft');
      final focus = t.widget<TextField>(field).focusNode;
      final panel = t.getRect(
        find.byKey(const ValueKey('coach-panel-surface')),
      );
      FadeTransition fade(String page) => t.widget<FadeTransition>(
        find
            .descendant(
              of: find.byKey(ValueKey('coach-page-$page')),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      Future<void> finishLoading() async {
        for (var i = 0; i < 4; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await t.pump();
        }
        await t.pumpAndSettle();
      }

      await t.tap(find.byKey(const ValueKey('coach-menu')));
      for (
        var i = 0;
        i < 20 && find.text('Your chats').evaluate().isEmpty;
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await t.pump();
      }
      expect(fade('chats').opacity.value, 0);
      await t.pump(Motion.fast);
      expect(fade('chats').opacity.value, inExclusiveRange(0, 1));
      await finishLoading();
      await t.tap(find.text('Personalization'));
      await t.pump();
      expect(fade('preferences').opacity.value, 0);
      await t.pump(Motion.fast);
      expect(fade('preferences').opacity.value, inExclusiveRange(0, 1));
      await finishLoading();
      expect(
        t.getRect(find.byKey(const ValueKey('coach-panel-surface'))),
        panel,
      );
      await t.binding.handlePopRoute();
      await finishLoading();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(t.widget<TextField>(field).controller!.text, 'Keep this draft');
      expect(t.widget<TextField>(field).focusNode, same(focus));
      expect(t.takeException(), isNull);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'New chat fades through without losing the saved draft; reduced=$reduced',
      (t) async {
        await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
        late CoachStore store;
        await t.runAsync(() async {
          store = await CoachStore.open('local');
          final now = DateTime.now().millisecondsSinceEpoch;
          await store.save({
            'id': 'new-chat-transition',
            'title': 'Saved chat',
            'created_ms': now,
            'updated_ms': now,
            'preview': 'A saved answer',
            'search_text': 'Saved chat\nA saved answer',
            'history_json': '[]',
            'transcript_json': jsonEncode([
              {'kind': 'user', 'text': 'A saved question'},
              {'kind': 'assistant', 'text': 'A saved answer'},
            ]),
            'draft': 'Keep this draft',
            'scroll_offset': 0.0,
          });
        });
        final previousHttp = HttpOverrides.current;
        final guard = _RequestGuard();
        HttpOverrides.global = guard;
        addTearDown(() => HttpOverrides.global = previousHttp);
        await mount(t, reduced: reduced);
        await open(t);
        for (var i = 0; i < 10; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await t.pump();
        }
        await t.pumpAndSettle();
        final field = find.byKey(
          const ValueKey('coach-composer-input'),
          skipOffstage: false,
        );
        final pane = find.byKey(
          const ValueKey('coach-page-chat'),
          skipOffstage: false,
        );
        FadeTransition fade() => t.widget<FadeTransition>(
          find
              .descendant(
                of: pane,
                matching: find.byType(FadeTransition, skipOffstage: false),
                skipOffstage: false,
              )
              .first,
        );
        final panel = t.getRect(
          find.byKey(const ValueKey('coach-panel-surface')),
        );
        final chatState = t.state(find.byType(CoachScreen));
        expect(t.widget<TextField>(field).controller!.text, 'Keep this draft');
        expect(find.text('A saved answer'), findsOneWidget);
        final newChat = find.byKey(const ValueKey('coach-new-chat'));
        await t.tap(newChat);
        await t.tap(newChat);
        await t.pump();
        if (!reduced) {
          await t.pump(Motion.fast ~/ 2);
          expect(fade().opacity.value, inExclusiveRange(0, 1));
          expect(find.text('A saved answer'), findsOneWidget);
          expect(
            t.widget<TextField>(field).controller!.text,
            'Keep this draft',
          );
          expect(t.widget<TextField>(field).enabled, isFalse);
        }
        await t.pump(Motion.fast);
        for (
          var i = 0;
          i < 30 && t.widget<TextField>(field).controller!.text.isNotEmpty;
          i++
        ) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
        }
        expect(t.widget<TextField>(field).controller!.text, isEmpty);
        if (!reduced) {
          expect(fade().opacity.value, 0);
          await t.pump(Motion.fast);
          expect(fade().opacity.value, inExclusiveRange(0, 1));
        } else {
          expect(fade().opacity.value, 1);
        }
        await t.pumpAndSettle();
        expect(fade().opacity.value, 1);
        expect(find.text('A saved answer'), findsNothing);
        expect(find.text('Try asking'), findsOneWidget);
        expect(
          t.getRect(find.byKey(const ValueKey('coach-panel-surface'))),
          panel,
        );
        expect(t.state(find.byType(CoachScreen)), same(chatState));
        await t.runAsync(() async {
          final saved = await store.read('new-chat-transition');
          expect(saved!['draft'], 'Keep this draft');
          expect(saved['transcript_json'], contains('A saved answer'));
        });
        expect(guard.clients.single.requests, 0);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('routed Coach applies keyboard space once', (t) async {
    await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
    await mount(t, style: InterfaceStyle.original);
    await open(t);
    final field = find.byKey(const ValueKey('coach-composer-input'));
    await t.tap(field);
    await t.pump();
    expect(t.testTextInput.isVisible, isTrue);
    t.view.viewInsets = const FakeViewPadding(bottom: 260);
    await t.pumpAndSettle();
    expect(t.getRect(field).bottom, lessThanOrEqualTo(844 - 260));
    expect(t.getRect(field).bottom, greaterThan(844 - 260 - S.x8));
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'rapidly reopening preferences after Cancel discards unsaved choices',
    (t) async {
      await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
      await mount(t, reduced: false);
      await open(t);
      Future<void> settleStorage() async {
        for (var i = 0; i < 5; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await t.pump();
        }
        await t.pumpAndSettle();
      }

      await t.tap(find.byKey(const ValueKey('coach-menu')));
      await settleStorage();
      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('coach-page-chats')),
          matching: find.text('Personalization'),
        ),
      );
      await settleStorage();
      await t.tap(find.byKey(const ValueKey('coach-choice-sleep')));
      await t.pump();
      await t.tap(find.text('Cancel'));
      await t.pump();
      await t.pump(Motion.fast);
      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('coach-page-chats')),
          matching: find.text('Personalization'),
        ),
      );
      await settleStorage();
      final selected = t.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('coach-choice-general')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(selected.properties.selected, isTrue);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'blank drafts disable Send; busy requests allow Stop and a new draft',
    (t) async {
      await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
      final previousHttp = HttpOverrides.current;
      final guard = _RequestGuard(holdRequests: true);
      HttpOverrides.global = guard;
      addTearDown(() => HttpOverrides.global = previousHttp);
      await mount(t);
      await open(t);
      final send = find.byKey(const ValueKey('coach-composer-send'));
      final field = find.byKey(const ValueKey('coach-composer-input'));
      expect(t.widget<Pressable>(send).onTap, isNull);
      expect(t.getSize(send).shortestSide, greaterThanOrEqualTo(S.tap));
      await t.tap(field);
      await t.pump();
      t.testTextInput.enterText('   ');
      await t.pump();
      expect(t.widget<Pressable>(send).onTap, isNull);
      t.testTextInput.enterText('Test question');
      await t.pump();
      expect(t.widget<Pressable>(send).onTap, isNotNull);
      expect(guard.clients.single.requests, 0);
      await t.tap(send);
      for (var i = 0; i < 30 && guard.clients.single.requests == 0; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
      }
      expect(guard.clients.single.requests, 1);
      expect(t.widget<Pressable>(send).onTap, isNotNull);
      expect(t.widget<Pressable>(send).semanticLabel, 'Stop');
      expect(find.byKey(const ValueKey('coach-pending-reply')), findsOneWidget);
      expect(find.byType(ExpressiveLoadingIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(t.widget<TextField>(field).enabled, isTrue);
      await t.enterText(field, 'A new draft while waiting');
      await t.tap(send);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
      expect(
        t.widget<TextField>(field).controller!.text,
        'A new draft while waiting',
      );
      guard.clients.single.pending.completeError(StateError('Test completed'));
      for (
        var i = 0;
        i < 30 && t.widget<Pressable>(send).semanticLabel == 'Stop';
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
      }
      expect(t.widget<TextField>(field).enabled, isTrue);
      expect(t.widget<Pressable>(send).semanticLabel, 'Send');
      expect(find.byKey(const ValueKey('coach-pending-reply')), findsNothing);
      expect(t.widget<Pressable>(send).onTap, isNotNull);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pumpAndSettle();
      await t.tap(field);
      await t.pump();
      expect(t.testTextInput.isVisible, isTrue);
      expect(guard.clients.single.requests, 1);
      expect(t.takeException(), isNull);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'reply loader stays in the transcript until first streamed text; reduced=$reduced',
      (t) async {
        await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
        final previousHttp = HttpOverrides.current;
        final provider = _DelayedToolProvider(streamReply: true);
        HttpOverrides.global = provider;
        addTearDown(() => HttpOverrides.global = previousHttp);
        await mount(t, reduced: reduced, scale: 2);
        await open(t);
        await t.enterText(
          find.byKey(const ValueKey('coach-composer-input')),
          'Test question',
        );
        await t.pump();
        await t.tap(find.byKey(const ValueKey('coach-composer-send')));
        for (var i = 0; i < 30 && provider.client.requests.isEmpty; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
        }
        expect(provider.client.requests, hasLength(1));
        final pending = find.byKey(const ValueKey('coach-pending-reply'));
        expect(pending, findsOneWidget);
        expect(
          find.ancestor(of: pending, matching: find.byType(ListView)),
          findsOneWidget,
        );
        expect(
          t.getRect(pending).top,
          greaterThan(t.getRect(find.text('Test question')).bottom),
        );
        final indicator = find.descendant(
          of: pending,
          matching: find.byType(ExpressiveLoadingIndicator),
        );
        final before = t.widget<ExpressiveLoadingIndicator>(indicator).phase;
        await t.pump(const Duration(milliseconds: 350));
        final after = t.widget<ExpressiveLoadingIndicator>(indicator).phase;
        expect(after, reduced ? before : greaterThan(before));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final status = t.widget<Semantics>(
          find.descendant(of: pending, matching: find.byType(Semantics)).first,
        );
        expect(status.properties.liveRegion, isTrue);
        expect(status.properties.label, isNotEmpty);

        provider.client.reply.add(
          utf8.encode(
            'data: ${jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': 'The first reply text.'},
                },
              ],
            })}\n\n',
          ),
        );
        for (var i = 0; i < 30 && pending.evaluate().isNotEmpty; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
        }
        expect(pending, findsNothing);
        expect(
          find.byWidgetPredicate(
            (w) => w is GptMarkdown && w.data == 'The first reply text.',
          ),
          findsOneWidget,
        );
        expect(
          t
              .widget<Pressable>(
                find.byKey(const ValueKey('coach-composer-send')),
              )
              .semanticLabel,
          'Stop',
        );
        provider.client.reply.add(utf8.encode('data: [DONE]\n\n'));
        await t.runAsync(() async {
          await provider.client.reply.close();
        });
        for (
          var i = 0;
          i < 30 &&
              t
                      .widget<Pressable>(
                        find.byKey(const ValueKey('coach-composer-send')),
                      )
                      .semanticLabel ==
                  'Stop';
          i++
        ) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
        }
        await t.pumpAndSettle();
        expect(pending, findsNothing);
        expect(
          t
              .widget<Pressable>(
                find.byKey(const ValueKey('coach-composer-send')),
              )
              .semanticLabel,
          'Send',
        );
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('streaming preserves the position while reading older messages', (t) async {
    await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
    File('${dir.path}/coach_idx_local.json').writeAsStringSync(jsonEncode([
      {'id': 'read', 'title': 'Long chat', 'updatedAt': 1, 'preview': 'Hello'},
    ]));
    File('${dir.path}/coach_s_local_read.json').writeAsStringSync(jsonEncode({
      'title': 'Long chat',
      'transcript': [for (var i = 0; i < 50; i++) {'kind': 'user', 'text': 'Older message $i'}],
    }));
    final previousHttp = HttpOverrides.current;
    final provider = _DelayedToolProvider(streamReply: true);
    HttpOverrides.global = provider;
    addTearDown(() => HttpOverrides.global = previousHttp);
    await mount(t, reduced: true);
    await open(t);
    for (var i = 0; i < 20 && find.text('Long chat').evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.enterText(find.byKey(const ValueKey('coach-composer-input')), 'Tell me more');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('coach-composer-send')));
    for (var i = 0; i < 30 && provider.client.requests.isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    expect(provider.client.requests, hasLength(1));
    final list = find.descendant(of: find.byType(CoachScreen), matching: find.byWidgetPredicate((w) => w is ListView && w.controller != null));
    final scroll = t.widget<ListView>(list).controller!;
    await t.pump(const Duration(milliseconds: 100));
    await t.drag(list, const Offset(0, 300));
    await t.pump(const Duration(seconds: 1));
    final offset = scroll.offset;
    expect(scroll.position.extentAfter, greaterThan(S.tap));
    provider.client.reply.add(utf8.encode('data: ${jsonEncode({'choices': [{'index': 0, 'delta': {'content': 'A new streamed answer. ' * 100}}]})}\n\n'));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 40));
    }
    expect(scroll.offset, closeTo(offset, .5));
    provider.client.reply.add(utf8.encode('data: [DONE]\n\n'));
    await t.runAsync(() => provider.client.reply.close());
    await t.pump(const Duration(seconds: 1));
    expect(scroll.offset, closeTo(offset, .5));
    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump();
  });

  testWidgets('top overscroll reveals and bottom overscroll hides', (t) async {
    await mount(t, physics: const ClampingScrollPhysics());
    final list = find.byKey(const ValueKey('page-list'));
    await t.drag(list, const Offset(0, -200));
    await t.pumpAndSettle();
    expect(entryHidden(t), isTrue);
    final position = pagePosition(t);
    position.jumpTo(0);
    await t.pumpAndSettle();
    await t.drag(list, const Offset(0, 160));
    await t.pumpAndSettle();
    expect(position.pixels, 0);
    expect(entryHidden(t), isFalse);
    final entry = find.byKey(const ValueKey('coach-entry'));
    expect(t.getSize(entry).width, greaterThan(100));
    await t.pump(Motion.coachSettle);
    await t.pumpAndSettle();
    expect(t.getSize(entry).width, S.tap + S.x2);
    position.jumpTo(position.maxScrollExtent);
    await t.pumpAndSettle();
    await t.drag(list, const Offset(0, -160));
    await t.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    expect(entryHidden(t), isTrue);
  });

  testWidgets('idle shrink does not depend on an end notification', (t) async {
    await mount(t);
    final list = t.element(find.byKey(const ValueKey('page-list')));
    OverscrollNotification(
      metrics: pagePosition(t),
      context: list,
      overscroll: -80,
      dragDetails: DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: const Offset(0, 80),
        primaryDelta: 80,
      ),
    ).dispatch(list);
    await t.pump();
    final entry = find.byKey(const ValueKey('coach-entry'));
    expect(t.getSize(entry).width, greaterThan(100));
    await t.pump(Motion.coachSettle);
    await t.pumpAndSettle();
    expect(t.getSize(entry).width, S.tap + S.x2);
    expect(entryHidden(t), isFalse);
  });

  testWidgets('Ask Coach stays expanded for two and a half seconds', (t) async {
    await mount(t, reduced: true);
    final list = t.element(find.byKey(const ValueKey('page-list')));
    OverscrollNotification(
      metrics: pagePosition(t),
      context: list,
      overscroll: -80,
      dragDetails: DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: const Offset(0, 80),
        primaryDelta: 80,
      ),
    ).dispatch(list);
    await t.pump();
    final entry = find.byKey(const ValueKey('coach-entry'));
    final expanded = t.getSize(entry).width;
    expect(expanded, greaterThan(100));
    await t.pump(const Duration(milliseconds: 2499));
    expect(t.getSize(entry).width, expanded);
    await t.pump(const Duration(milliseconds: 1));
    await t.pumpAndSettle();
    expect(t.getSize(entry).width, S.tap + S.x2);
  });

  testWidgets('idle label shrink moves through intermediate widths', (t) async {
    await mount(t, reduced: false);
    await t.drag(find.byKey(const ValueKey('page-list')), const Offset(0, 200));
    await t.pumpAndSettle();
    final entry = find.byKey(const ValueKey('coach-entry'));
    final expanded = t.getSize(entry).width;
    await t.pump(Motion.coachSettle);
    expect(t.getSize(entry).width, expanded);
    await t.pump(const Duration(milliseconds: 50));
    expect(t.getSize(entry).width, inExclusiveRange(S.tap + S.x2, expanded));
    await t.pumpAndSettle();
    expect(t.getSize(entry).width, S.tap + S.x2);
  });

  testWidgets('entry rises a short distance and reverses without jumping', (
    t,
  ) async {
    await mount(t, reduced: false);
    final entry = find.byKey(const ValueKey('coach-entry'));
    final list = find.byKey(const ValueKey('page-list'));
    final hiddenY = t.getCenter(entry).dy;
    final gesture = await t.startGesture(t.getCenter(list));
    await gesture.moveBy(const Offset(0, 100));
    await t.pump();
    expect(t.getCenter(entry).dy, hiddenY);
    await t.pump(const Duration(milliseconds: 45));
    final risingY = t.getCenter(entry).dy;
    expect(risingY, inExclusiveRange(hiddenY - S.x6, hiddenY));
    await gesture.moveBy(const Offset(0, -80));
    await t.pump();
    expect(t.getCenter(entry).dy, risingY);
    await t.pump(const Duration(milliseconds: 45));
    expect(t.getCenter(entry).dy, greaterThan(risingY));
    await gesture.up();
    await t.pumpAndSettle();
    expect(t.getCenter(entry).dy, hiddenY);
    expect(entryHidden(t), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('small finger reversals do not flicker the entry', (t) async {
    await mount(t);
    final list = find.byKey(const ValueKey('page-list'));
    await t.drag(list, const Offset(0, 200));
    await t.pumpAndSettle();
    final element = t.element(list);
    void dragUpdate(double dy) => ScrollUpdateNotification(
      metrics: pagePosition(t),
      context: element,
      scrollDelta: -dy,
      dragDetails: DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: Offset(0, dy),
        primaryDelta: dy,
      ),
    ).dispatch(element);
    dragUpdate(-1);
    await t.pump();
    expect(entryHidden(t), isFalse);
    dragUpdate(-S.tap);
    await t.pump();
    expect(entryHidden(t), isTrue);
  });

  testWidgets('real Home shows Coach toward the top and hides farther down', (
    t,
  ) async {
    await mount(
      t,
      accessible: true,
      page: (_) => const HomeScreen(
        data: HomeData(
          readiness: Metric(value: 73),
          sleepMin: Metric(value: 431),
          sleepNeedMin: Metric(value: 487),
          strain: Metric(value: 12.4),
          rhr: Metric(value: 51),
          steps: Metric(value: 6234),
          calories: Metric(value: 520),
        ),
      ),
    );
    final list = find
        .descendant(
          of: find.byType(HomeScreen),
          matching: find.byType(ListView),
        )
        .first;
    final position = t
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await t.pump();
    final before = position.pixels;
    await t.drag(list, const Offset(0, 160));
    await t.pumpAndSettle();
    expect(position.pixels, lessThan(before));
    expect(entryHidden(t), isFalse);
    expect(
      t.getSize(find.byKey(const ValueKey('coach-entry'))).width,
      greaterThan(100),
    );
    await t.drag(list, const Offset(0, -160));
    await t.pumpAndSettle();
    expect(entryHidden(t), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('down at chat top contracts one level even with short content', (
    t,
  ) async {
    for (final reduced in [false, true]) {
      await mount(t, reduced: reduced, accessible: true);
      await open(t);
      final surface = find.byKey(const ValueKey('coach-panel-surface'));
      final compactHeight = t.getSize(surface).height;
      await t.tap(find.byKey(const ValueKey('coach-panel-expand')));
      await t.pumpAndSettle();
      final chat = find
          .descendant(
            of: find.byType(CoachScreen),
            matching: find.byType(ListView),
          )
          .first;
      await t.drag(chat, const Offset(0, 300));
      await t.pumpAndSettle();
      expect(t.getSize(surface).height, compactHeight);
      await t.drag(chat, const Offset(0, 140));
      await t.pumpAndSettle();
      expect(surface, findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
    }
  });

  testWidgets(
    'reading older messages does not collapse until a new top swipe',
    (t) async {
      await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
      File('${dir.path}/coach_idx_local.json').writeAsStringSync(
        jsonEncode([
          {
            'id': 'scroll',
            'title': 'Saved chat',
            'updatedAt': 1,
            'preview': 'Hello',
          },
        ]),
      );
      File('${dir.path}/coach_s_local_scroll.json').writeAsStringSync(
        jsonEncode({
          'title': 'Saved chat',
          'transcript': [
            for (var i = 0; i < 80; i++)
              {'kind': 'user', 'text': 'Saved message $i'},
          ],
        }),
      );
      await mount(t);
      await open(t);
      final transcript = find.descendant(
        of: find.byType(CoachScreen),
        matching: find.byWidgetPredicate(
          (w) => w is ListView && w.controller != null,
        ),
      );
      for (var i = 0; i < 10 && transcript.evaluate().isEmpty; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await t.pumpAndSettle();
      }
      expect(transcript, findsOneWidget);
      await t.tap(find.byKey(const ValueKey('coach-panel-expand')));
      await t.pumpAndSettle();
      final surface = find.byKey(const ValueKey('coach-panel-surface'));
      final fullHeight = t.getSize(surface).height;
      final scroll = t.widget<ListView>(transcript).controller!;
      scroll.jumpTo(40);
      await t.pump();
      await t.drag(transcript, const Offset(0, 160));
      await t.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(t.getSize(surface).height, fullHeight);
      await t.drag(transcript, const Offset(0, 140));
      await t.pumpAndSettle();
      expect(t.getSize(surface).height, lessThan(fullHeight));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('upward message scrolling keeps chat size; header can resize', (
    t,
  ) async {
    await mount(t);
    await open(t);
    final surface = find.byKey(const ValueKey('coach-panel-surface'));
    final height = t.getSize(surface).height;
    await t.drag(find.text('The coach is not set up'), const Offset(0, -80));
    await t.pumpAndSettle();
    expect(t.getSize(surface).height, height);
    await t.drag(
      find.byKey(const ValueKey('coach-panel-handle')),
      const Offset(0, -90),
    );
    await t.pumpAndSettle();
    expect(t.getSize(surface).height, greaterThan(height));
    await t.drag(
      find.byKey(const ValueKey('coach-panel-handle')),
      const Offset(0, 90),
    );
    await t.pumpAndSettle();
    expect(t.getSize(surface).height, height);
  });

  testWidgets('opening and resizing morph through intermediate sizes', (
    t,
  ) async {
    await mount(t, reduced: false);
    await t.tap(find.text('Open Coach'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final surface = find.byKey(const ValueKey('coach-panel-surface'));
    final opening = t.getSize(surface);
    final chat = t.state(find.byType(CoachScreen));
    await t.pumpAndSettle();
    final compact = t.getSize(surface);
    expect(opening.height, lessThan(compact.height));
    await t.tap(find.byKey(const ValueKey('coach-panel-expand')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(t.getSize(surface).height, greaterThan(compact.height));
    expect(t.getSize(surface).height, lessThan(844));
    expect(t.state(find.byType(CoachScreen)), same(chat));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'safe-area padding follows expansion and reversal without jumps',
    (t) async {
      await mount(
        t,
        reduced: false,
        padding: const EdgeInsets.only(top: 28, bottom: 24),
      );
      await open(t);
      final surface = find.byKey(const ValueKey('coach-panel-surface'));
      final compact = t.getRect(surface);
      EdgeInsets insets() =>
          t
                  .widget<Padding>(
                    find.byKey(const ValueKey('coach-panel-insets')),
                  )
                  .padding
              as EdgeInsets;
      expect(insets(), EdgeInsets.zero);
      final expand = find.byKey(const ValueKey('coach-panel-expand'));
      await t.tap(expand);
      await t.pump();
      expect(insets(), EdgeInsets.zero);
      expect(t.getRect(surface), compact);
      await t.pump(const Duration(milliseconds: 50));
      final intermediate = insets();
      expect(intermediate.top, greaterThan(0));
      expect(intermediate.top, lessThan(28));
      await t.tap(expand);
      await t.pump();
      expect(insets(), intermediate);
      await t.pump(const Duration(milliseconds: 50));
      expect(insets().top, lessThan(intermediate.top));
      await t.pumpAndSettle();
      expect(insets(), EdgeInsets.zero);
      expect(t.getRect(surface), compact);
      await t.tap(expand);
      await t.pumpAndSettle();
      expect(insets(), const EdgeInsets.only(top: 28, bottom: 24));
      await t.tap(expand);
      await t.pump();
      expect(insets(), const EdgeInsets.only(top: 28, bottom: 24));
      await t.pump(const Duration(milliseconds: 100));
      expect(insets().top, inExclusiveRange(0, 28));
      expect(t.getSize(surface).height, inExclusiveRange(compact.height, 844));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('opening and early dismissal return smoothly to the same pill', (
    t,
  ) async {
    await mount(t, reduced: false);
    await t.drag(find.byKey(const ValueKey('page-list')), const Offset(0, 200));
    await t.pumpAndSettle();
    final entry = find.byKey(const ValueKey('coach-entry'));
    final origin = t.getRect(entry);
    expect(origin.width, greaterThan(100));
    await t.tap(entry);
    await t.pump();
    final surface = find.byKey(const ValueKey('coach-panel-surface'));
    expect(t.getRect(surface), origin);
    await t.pump(const Duration(milliseconds: 100));
    final opening = t.getRect(surface);
    expect(opening.height, greaterThan(origin.height));
    await t.binding.handlePopRoute();
    await t.pump();
    expect(t.getRect(surface), opening);
    await t.pump(const Duration(milliseconds: 80));
    expect(t.getSize(surface).height, lessThan(opening.height));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('coach-panel-surface')), findsNothing);
    expect(t.getRect(entry), origin);
    expect(t.takeException(), isNull);
  });

  testWidgets('horizontal chart/page movement does not reveal Coach', (
    t,
  ) async {
    await mount(t);
    final list = t.element(find.byKey(const ValueKey('page-list')));
    ScrollUpdateNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 500,
        pixels: 20,
        viewportDimension: 300,
        axisDirection: AxisDirection.right,
        devicePixelRatio: 1,
      ),
      context: list,
      scrollDelta: 120,
      dragDetails: DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: const Offset(-120, 1),
      ),
    ).dispatch(list);
    await t.pumpAndSettle();
    final entry = find.byKey(const ValueKey('coach-entry'));
    final ignore = find.ancestor(
      of: entry,
      matching: find.byType(IgnorePointer),
    );
    expect(
      ignore.evaluate().any((e) => (e.widget as IgnorePointer).ignoring),
      isTrue,
    );
  });

  testWidgets(
    'restored chat, draft and scroll survive modes without requests',
    (t) async {
      await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
      File('${dir.path}/coach_idx_local.json').writeAsStringSync(
        jsonEncode([
          {
            'id': 'saved',
            'title': 'Saved chat',
            'updatedAt': 1,
            'preview': 'Hello',
          },
        ]),
      );
      File('${dir.path}/coach_s_local_saved.json').writeAsStringSync(
        jsonEncode({
          'title': 'Saved chat',
          'transcript': [
            for (var i = 0; i < 80; i++)
              {'kind': 'user', 'text': 'Saved message $i'},
          ],
        }),
      );
      final previousHttp = HttpOverrides.current;
      final guard = _RequestGuard();
      HttpOverrides.global = guard;
      addTearDown(() => HttpOverrides.global = previousHttp);
      await mount(t);
      await open(t);
      final chat = t.state(find.byType(CoachScreen));
      final transcript = find.descendant(
        of: find.byType(CoachScreen),
        matching: find.byWidgetPredicate(
          (w) => w is ListView && w.controller != null,
        ),
      );
      // Restore crosses several real file reads. Let each completion return to
      // the test's fake clock before looking for the restored transcript.
      for (var i = 0; i < 10 && transcript.evaluate().isEmpty; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await t.pumpAndSettle();
      }
      expect(transcript, findsOneWidget);
      final list = t.widget<ListView>(transcript);
      final scroll = list.controller!;
      scroll.jumpTo(400);
      await t.pump();
      await t.enterText(find.byType(TextField), 'A saved draft');
      await t.tap(find.byKey(const ValueKey('coach-panel-expand')));
      await t.pumpAndSettle();
      expect(scroll.offset, 400);
      expect(t.state(find.byType(CoachScreen)), same(chat));
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(scroll.offset, 400);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('coach-entry')));
      await t.pumpAndSettle();
      expect(t.state(find.byType(CoachScreen)), same(chat));
      expect(scroll.offset, 400);
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        'A saved draft',
      );
      expect(guard.clients, hasLength(1));
      expect(guard.clients.single.requests, 0);
    },
  );

  testWidgets('screen-reader action opens Coach while its entry is hidden', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    try {
      await mount(t, accessible: true, scale: 3.1);
      final entry = find.byKey(const ValueKey('coach-entry'));
      expect(entryHidden(t), isTrue);
      expect(t.getSize(entry).width, greaterThanOrEqualTo(S.tap));
      expect(t.getSize(entry).height, greaterThanOrEqualTo(S.tap));
      final scope = find.byKey(const ValueKey('coach-entry-actions'));
      final actions = t
          .widget<Semantics>(scope)
          .properties
          .customSemanticsActions!;
      final action = actions.keys.single;
      expect(action.label, 'Ask Coach');
      final node = t.getSemantics(scope);
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(action),
      );
      await t.pumpAndSettle();
      expect(find.byType(CoachScreen), findsOneWidget);
      expect(t.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Home headers no longer expose the old Coach button', (t) async {
    await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
    for (final style in InterfaceStyle.values) {
      await mount(
        t,
        style: style,
        page: (_) => const HomeScreen(data: HomeData(name: 'Alex'), hour: 9),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == 'Ask the coach',
        ),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == 'Profile and settings',
        ),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
    }
  });

  testWidgets(
    'large text and keyboard keep the chat controls within the panel',
    (t) async {
      await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
      for (final scale in [1.0, 2.0, 3.1]) {
        await mount(t, scale: scale, keyboard: 260);
        await open(t);
        final panel = t.getRect(
          find.byKey(const ValueKey('coach-panel-surface')),
        );
        expect(panel.bottom, lessThanOrEqualTo(844 - 260));
        expect(
          t.getRect(find.byType(TextField)).bottom,
          lessThanOrEqualTo(panel.bottom),
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
        await t.pump();
      }
    },
  );

  for (final preferences in [false, true]) {
    testWidgets(
      'delayed write proposal cannot confirm from ${preferences ? 'preferences' : 'chat browser'}',
      (t) async {
        await config.save(baseUrl: 'http://127.0.0.1:11434/v1', model: 'test');
        final previousHttp = HttpOverrides.current;
        final provider = _DelayedToolProvider();
        HttpOverrides.global = provider;
        addTearDown(() => HttpOverrides.global = previousHttp);
        final repo = _WriteRepo();
        app.repo = repo;
        Future<void> until(bool Function() ready) async {
          for (var i = 0; i < 40 && !ready(); i++) {
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await t.pump(const Duration(milliseconds: 50));
          }
          expect(
            ready(),
            true,
            reason:
                'Synthetic requests: ${provider.client.requests.length}; '
                'visible Coach text: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' | ')}',
          );
        }

        await mount(t);
        await open(t);
        await t.enterText(
          find.byKey(const ValueKey('coach-composer-input')),
          'Set my step goal to 9000',
        );
        await t.pump();
        final send = find.byKey(const ValueKey('coach-composer-send'));
        expect(t.widget<Pressable>(send).onTap, isNotNull);
        await t.tap(send);
        await until(() => provider.client.requests.length == 1);
        await t.tap(find.byKey(const ValueKey('coach-menu')));
        await until(() => find.text('Your chats').evaluate().isNotEmpty);
        if (preferences) {
          await t.tap(find.text('Personalization'));
          await until(
            () => find.text('Save preferences').evaluate().isNotEmpty,
          );
        }
        provider.client.proposal.complete();
        // The second synthetic request proves the tool reached confirmation and
        // returned a denial rather than merely being left pending or failing parse.
        await until(
          () =>
              provider.client.requests.length == 2 ||
              find.byType(AlertDialog).evaluate().isNotEmpty,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(repo.writes, 0);
        final messages = provider.client.requests.last['messages'] as List;
        expect(
          messages.where((m) => m['role'] == 'tool').single['content'],
          'User declined the action. Do not retry it.',
        );
        if (preferences) {
          await t.binding.handlePopRoute();
          await t.pump();
        }
        await t.binding.handlePopRoute();
        await until(
          () => find
              .byWidgetPredicate(
                (w) =>
                    w is GptMarkdown &&
                    w.data == 'The proposed change was not saved.',
              )
              .evaluate()
              .isNotEmpty,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(repo.writes, 0);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'chat browser shares the retained surface and Back preserves its draft',
    (t) async {
      await config.save(baseUrl: 'http://localhost:11434/v1', model: 'local');
      await mount(t);
      await open(t);
      await t.enterText(
        find.byKey(const ValueKey('coach-composer-input')),
        'Draft stays here',
      );
      final panel = find.byKey(const ValueKey('coach-panel-surface'));
      final before = t.getRect(panel);
      await t.tap(find.byKey(const ValueKey('coach-menu')));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
      expect(find.text('Your chats'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-chat-search')), findsOneWidget);
      expect(find.byType(SvgPicture), findsWidgets);
      expect(t.getRect(panel), before);
      await t.tap(find.text('Personalization'));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
      expect(find.text('Save preferences'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Your chats'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      final field = find.byKey(const ValueKey('coach-composer-input'));
      expect(t.widget<TextField>(field).controller!.text, 'Draft stays here');
      expect(t.getRect(panel), before);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'chat browser highlights actual active chat and supports rename and confirmed delete',
    (t) async {
      await config.save(baseUrl: 'http://localhost:11434/v1', model: 'local');
      late CoachStore st;
      await t.runAsync(() async {
        st = await CoachStore.open('local');
        final now = DateTime.now().millisecondsSinceEpoch;
        await st.save({
          'id': 'visual-chat',
          'title': 'My saved chat',
          'created_ms': now,
          'updated_ms': now,
          'preview': 'A real saved conversation',
          'search_text': 'My saved chat\nA real saved conversation',
          'history_json': '[]',
          'transcript_json': jsonEncode([
            {'kind': 'user', 'text': 'A saved question'},
            {'kind': 'assistant', 'text': 'A saved answer'},
          ]),
          'draft': '',
          'scroll_offset': 0.0,
        });
      });
      await mount(t);
      await open(t);
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
      expect(find.text('My saved chat'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-view-context')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('coach-menu')));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
      expect(find.textContaining('Current chat'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      final row = find.byKey(const ValueKey('coach-chat-visual-chat'));
      await t.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Rename chat'));
      await t.pumpAndSettle();
      await t.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Renamed conversation',
      );
      await t.tap(find.text('Save'));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
      expect(
        (await t.runAsync(() => st.read('visual-chat')))!['title'],
        'Renamed conversation',
      );
      await t.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Delete it'));
      await t.pumpAndSettle();
      expect(await t.runAsync(() => st.read('visual-chat')), isNotNull);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('Renamed conversation'), findsOneWidget);
      await t.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Delete it'));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete it'));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
      expect(await t.runAsync(() => st.read('visual-chat')), isNull);
      expect(
        find.byKey(const ValueKey('coach-composer-input')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('Original keeps its existing shell and Coach route', (t) async {
    await mount(t, style: InterfaceStyle.original);
    expect(find.byKey(const ValueKey('coach-entry')), findsNothing);
    await t.tap(find.text('Open Coach'));
    await t.pumpAndSettle();
    expect(find.byType(CoachScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-panel-surface')), findsNothing);
  });
}
