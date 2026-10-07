import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/onboarding/splash.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _QueuedStore extends SharedPreferencesStorePlatform {
  final firstWrite = Completer<bool>();
  final values = <String, Object>{};
  final calls = <Object>[];

  @override
  Future<Map<String, Object>> getAll() async => values;
  @override
  Future<bool> clear() async => true;
  @override
  Future<bool> remove(String key) async => values.remove(key) != null;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    calls.add(value);
    if (calls.length == 1 && !await firstWrite.future) return false;
    values[key] = value;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the shared brand asset loads and never re-covers a ready app', (
    tester,
  ) async {
    var ready = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, style: InterfaceStyle.expressive),
        home: StatefulBuilder(
          builder: (c, setState) {
            update = setState;
            return BootSplash(ready: ready, child: const Text('App content'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.text('OpenStrap'), findsOneWidget);
    expect(tester.takeException(), isNull);
    update(() => ready = true);
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsNothing);
    update(() => ready = false);
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.text('App content'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('existing and unknown style preferences open Original', () async {
    for (final value in [null, 'unknown']) {
      SharedPreferences.setMockInitialValues({
        'theme_choice': 'dark',
        'ui.interface_style': ?value,
      });
      final controller = await ThemeController.bootstrap();
      expect(controller.interfaceStyle, InterfaceStyle.original);
      expect(controller.choice, AppThemeChoice.dark);
      controller.dispose();
    }
  });

  test('style round trips preserve every unrelated saved preference', () async {
    final existing = <String, Object>{
      'local_profile_json': '{"age":34,"sex":"f"}',
      'ui.shell_tab': 3,
      'paired_remote_id': 'fixture-device',
      'health_sync_enabled': false,
    };
    SharedPreferences.setMockInitialValues(existing);
    final controller = await ThemeController.bootstrap();
    expect(
      await controller.setInterfaceStyle(InterfaceStyle.expressive),
      isTrue,
    );
    final restarted = await ThemeController.bootstrap();
    expect(restarted.interfaceStyle, InterfaceStyle.expressive);
    expect(await restarted.setInterfaceStyle(InterfaceStyle.original), isTrue);
    final prefs = await SharedPreferences.getInstance();
    for (final entry in existing.entries) {
      expect(prefs.get(entry.key), entry.value);
    }
    expect(prefs.getKeys(), {...existing.keys, 'ui.interface_style'});
    controller.dispose();
    restarted.dispose();
  });

  test('unknown palettes retain Edge and every palette survives restart', () async {
    final existing = <String, Object>{
      'theme_choice': 'dark',
      'ui.interface_style': 'expressive',
      'local_profile_json': '{"age":34,"sex":"f"}',
      'paired_remote_id': 'fixture-device',
      'ui.shell_tab': 3,
    };
    for (final value in [null, 'unknown']) {
      SharedPreferences.setMockInitialValues({
        ...existing, 'ui.expressive_palette': ?value,
      });
      final controller = await ThemeController.bootstrap();
      expect(controller.palette, ExpressivePalette.edge);
      controller.dispose();
    }
    for (final palette in ExpressivePalette.values) {
      SharedPreferences.setMockInitialValues(existing);
      final controller = await ThemeController.bootstrap();
      expect(await controller.setPalette(palette), isTrue);
      final restarted = await ThemeController.bootstrap();
      expect(restarted.palette, palette);
      expect(restarted.choice, AppThemeChoice.dark);
      expect(restarted.interfaceStyle, InterfaceStyle.expressive);
      await restarted.setInterfaceStyle(InterfaceStyle.original);
      await restarted.setInterfaceStyle(InterfaceStyle.expressive);
      expect(restarted.palette, palette);
      final prefs = await SharedPreferences.getInstance();
      for (final entry in existing.entries) {
        expect(prefs.get(entry.key), entry.value);
      }
      expect(prefs.getKeys().difference(existing.keys.toSet()),
          palette == ExpressivePalette.edge ? isEmpty : {'ui.expressive_palette'});
      controller.dispose();
      restarted.dispose();
    }
  });

  test('palette saves serialize with style saves and publish after success', () async {
    final controller = ThemeController.seed(AppThemeChoice.dark, Brightness.light);
    final previous = SharedPreferencesStorePlatform.instance;
    final store = _QueuedStore();
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    addTearDown(controller.dispose);
    final observed = <ExpressivePalette>[];
    controller.addListener(() => observed.add(controller.palette));
    final first = controller.setPalette(ExpressivePalette.matteLime);
    final style = controller.setInterfaceStyle(InterfaceStyle.expressive);
    final last = controller.setPalette(ExpressivePalette.freshMint);
    await Future<void>.delayed(Duration.zero);
    expect(controller.palette, ExpressivePalette.edge);
    expect(observed, isEmpty);
    store.firstWrite.complete(false);
    expect(await first, isFalse);
    expect(await style, isTrue);
    expect(await last, isTrue);
    expect(store.calls, ['matteLime', 'expressive', 'freshMint']);
    expect(observed, [ExpressivePalette.edge, ExpressivePalette.freshMint]);
    expect(store.values['flutter.ui.expressive_palette'], 'freshMint');
  });

  test('palette selection leaves Original tokens unchanged', () {
    for (final palette in ExpressivePalette.values) {
      for (final dark in [false, true]) {
        final original = P(dark, palette: palette);
        final unchanged = P(dark);
        expect(original.bg, unchanged.bg);
        expect(original.card, unchanged.card);
        expect(original.ink, unchanged.ink);
        for (final accent in C.all) {
          expect(original.on(accent), unchanged.on(accent));
          expect(original.fill(accent), unchanged.fill(accent));
          expect(original.wash(accent), unchanged.wash(accent));
        }
      }
    }
  });

  test(
    'rapid style choices persist in order and notify only after saving',
    () async {
      final controller = ThemeController.seed(
        AppThemeChoice.light,
        Brightness.dark,
      );
      final previous = SharedPreferencesStorePlatform.instance;
      final store = _QueuedStore();
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      addTearDown(controller.dispose);
      final observed = <InterfaceStyle>[];
      controller.addListener(() => observed.add(controller.interfaceStyle));
      final expressive = controller.setInterfaceStyle(
        InterfaceStyle.expressive,
      );
      final original = controller.setInterfaceStyle(InterfaceStyle.original);
      await Future<void>.delayed(Duration.zero);
      expect(controller.interfaceStyle, InterfaceStyle.original);
      expect(observed, isEmpty);
      expect(store.calls, ['expressive']);
      store.firstWrite.complete(true);
      expect(await expressive, isTrue);
      expect(await original, isTrue);
      expect(store.calls, ['expressive', 'original']);
      expect(store.values['flutter.ui.interface_style'], 'original');
      expect(observed, [InterfaceStyle.expressive, InterfaceStyle.original]);
    },
  );

  for (final style in InterfaceStyle.values) {
    testWidgets('$style progress keeps its spoken percentage', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light, style: style),
            home: const Scaffold(
              body: ProgressCard('Steps', '50', '100', .5, C.green),
            ),
          ),
        );
        final progress = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.role == SemanticsRole.progressBar,
        );
        expect(progress, findsOneWidget);
        final data = tester.getSemantics(progress).getSemanticsData();
        expect(data.role, SemanticsRole.progressBar);
        expect(data.value, '50');
        expect(data.minValue, '0');
        expect(data.maxValue, '100');
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
    'expressive spatial press stops immediately under reduced motion',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, style: InterfaceStyle.expressive),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: Pressable(onTap: () {}, child: const Text('Press')),
          ),
        ),
      );
      final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale.duration, Duration.zero);
      expect(scale.curve.transform(0), 0);
      expect(scale.curve.transform(1), 1);
    },
  );
}
