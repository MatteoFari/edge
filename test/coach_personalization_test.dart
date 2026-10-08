import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/coach_personalization.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String previousDbName;
  late PathProviderPlatform previousPaths;
  late CoachStore store;
  late AppState app;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    previousDbName = LocalDb.dbName;
    previousPaths = PathProviderPlatform.instance;
    dir = await Directory.systemTemp.createTemp('coach_personalization_');
    PathProviderPlatform.instance = _Paths(dir.path);
    LocalDb.dbName = '${dir.path}/test.db';
    store = await CoachStore.open('local');
    app = AppState.forTesting();
  });
  tearDown(() async {
    app.dispose();
    await LocalDb.close();
    LocalDb.dbName = previousDbName;
    PathProviderPlatform.instance = previousPaths;
    await dir.delete(recursive: true);
  });
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await t.pumpAndSettle();
    }
  }

  Future<void> mount(
    WidgetTester t,
    Widget child, {
    double scale = 1,
    bool reduced = true,
    Brightness brightness = Brightness.dark,
  }) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ThemeController>(
            create: (_) => ThemeController.seed(
              brightness == Brightness.dark
                  ? AppThemeChoice.dark
                  : AppThemeChoice.light,
              brightness,
              interfaceStyle: InterfaceStyle.expressive,
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(brightness, style: InterfaceStyle.expressive),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduced,
            ),
            child: child!,
          ),
          home: child,
        ),
      ),
    );
    await settle(t);
  }

  testWidgets(
    'custom instructions Save applies future preferences; Cancel and clear behave explicitly',
    (t) async {
      await t.runAsync(
        () => store.savePreferences(
          const CoachPreferences(
            focus: 'sleep',
            customInstructions: 'Original',
          ),
        ),
      );
      await mount(t, CoachCustomInstructions(store: store));
      final field = find.byKey(const ValueKey('coach-custom-instructions'));
      expect(t.widget<TextField>(field).maxLength, 2000);
      await t.enterText(field, 'Discarded');
      await t.tap(find.text('Cancel'));
      await settle(t);
      expect(
        (await t.runAsync(store.preferences))!.customInstructions,
        'Original',
      );
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
      await mount(t, CoachCustomInstructions(store: store));
      await t.enterText(field, 'Answer in Italian');
      await t.tap(find.text('Save instructions'));
      await settle(t);
      expect(
        (await t.runAsync(store.preferences))!.customInstructions,
        'Answer in Italian',
      );
      expect((await t.runAsync(store.preferences))!.focus, 'sleep');
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
      await mount(t, CoachCustomInstructions(store: store));
      await t.enterText(field, '');
      await t.tap(find.text('Save instructions'));
      await settle(t);
      expect(
        (await t.runAsync(store.preferences))!.customInstructions,
        isEmpty,
      );
    },
  );
  testWidgets(
    'manual preference Save is explicit consent; Cancel and confirmed removal work',
    (t) async {
      await mount(t, const CoachPersonalization());
      final list = find.byType(ListView);
      await t.scrollUntilVisible(
        find.text('Add a preference'),
        200,
        scrollable: find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Add a preference'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'I prefer outdoor runs');
      expect(await t.runAsync(store.memories), isEmpty);
      await t.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await t.pumpAndSettle();
      expect(await t.runAsync(store.memories), isEmpty);
      await t.ensureVisible(find.text('Add a preference'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add a preference'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'I prefer outdoor runs');
      await t.tap(find.text('Save'));
      await settle(t);
      expect(
        (await t.runAsync(store.memories))!.single.text,
        'I prefer outdoor runs',
      );
      expect((await t.runAsync(store.preferences))!.memoryEnabled, false);
      await settle(t);
      await t.scrollUntilVisible(
        find.text('I prefer outdoor runs'),
        200,
        scrollable: find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('I prefer outdoor runs'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Short replies');
      await t.tap(find.text('Save'));
      await settle(t);
      expect((await t.runAsync(store.memories))!.single.text, 'Short replies');
      await settle(t);
      await t.scrollUntilVisible(
        find.byTooltip('Remove preference'),
        200,
        scrollable: find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first,
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Remove preference'));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete it'));
      await settle(t);
      expect(await t.runAsync(store.memories), isEmpty);
    },
  );
  testWidgets('focus, reply length and memory are staged until explicit Save', (
    t,
  ) async {
    await mount(t, const CoachPersonalization());
    await t.tap(find.byKey(const ValueKey('coach-choice-sleep')));
    await t.tap(find.byKey(const ValueKey('coach-choice-brief')));
    await t.tap(find.byType(Checkbox));
    await t.pump();
    var prefs = (await t.runAsync(store.preferences))!;
    expect(prefs.focus, 'general');
    expect(prefs.replyLength, 'balanced');
    expect(prefs.memoryEnabled, false);
    await t.tap(find.text('Cancel'));
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await mount(t, const CoachPersonalization());
    expect(t.widget<Checkbox>(find.byType(Checkbox)).value, false);
    await t.tap(find.byKey(const ValueKey('coach-choice-training')));
    await t.tap(find.byKey(const ValueKey('coach-choice-detailed')));
    await t.tap(find.byType(Checkbox));
    await t.tap(find.text('Save preferences'));
    await settle(t);
    prefs = (await t.runAsync(store.preferences))!;
    expect(prefs.focus, 'training');
    expect(prefs.replyLength, 'detailed');
    expect(prefs.memoryEnabled, true);
  });

  testWidgets(
    'instruction editor returns to staged preferences and saves only its own field',
    (t) async {
      await mount(t, const CoachPersonalization(), reduced: false);
      await t.tap(find.byKey(const ValueKey('coach-choice-sleep')));
      final custom = find.text('Custom instructions');
      await t.scrollUntilVisible(
        custom,
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.pumpAndSettle();
      await t.tap(custom);
      await t.pump();
      await t.pump(const Duration(milliseconds: 80));
      final transitions = t.widgetList<FadeTransition>(find.byType(FadeTransition));
      expect(transitions.any((w) => w.opacity.value > 0 && w.opacity.value < 1), isTrue);
      await settle(t);
      final field = find.byKey(const ValueKey('coach-custom-instructions'));
      await t.enterText(field, 'Keep answers practical');
      await t.tap(find.text('Save instructions'));
      await settle(t);
      var prefs = (await t.runAsync(store.preferences))!;
      expect(prefs.focus, 'general');
      expect(prefs.customInstructions, 'Keep answers practical');
      await t.tap(find.text('Save preferences'));
      await settle(t);
      prefs = (await t.runAsync(store.preferences))!;
      expect(prefs.focus, 'sleep');
      expect(prefs.customInstructions, 'Keep answers practical');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'personalization remains scrollable at large text in light and dark palettes',
    (t) async {
      for (final brightness in Brightness.values) {
        await mount(
          t,
          const CoachPersonalization(),
          scale: 3.1,
          brightness: brightness,
        );
        await t.drag(find.byType(ListView), const Offset(0, -600));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
        await t.pump();
      }
    },
  );
}
