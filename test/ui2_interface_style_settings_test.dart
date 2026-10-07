import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The preference store is already provided by shared_preferences; substituting
// it makes a refused write observable through the real settings screen.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/onboarding/profile_setup.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _RefusingStyleStore extends SharedPreferencesStorePlatform {
  @override
  Future<Map<String, Object>> getAll() async => {};
  @override
  Future<bool> clear() async => false;
  @override
  Future<bool> remove(String key) async => false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async => false;
}

void _phone(WidgetTester t, {double height = 2400}) {
  t.view.physicalSize = Size(390 * 3, height * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Widget _host(Widget child, ThemeController theme, {double scale = 1}) =>
    AnimatedBuilder(
      animation: theme,
      builder: (_, _) => MaterialApp(
        theme: buildTheme(theme.effective, style: theme.interfaceStyle,
            palette: theme.palette),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
              disableAnimations: true, textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    );

Widget _settingsHost(AppState app, ThemeController theme) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<UnitsController>(
            create: (_) => UnitsController.seed(UnitSystem.metric)),
        ChangeNotifierProvider<ClockFormatController>(
            create: (_) => ClockFormatController.seed(ClockFormat.system)),
      ],
      child: _host(const MoreSettings(), theme),
    );

Future<void> _pickExpressive(WidgetTester t) async {
  await t.ensureVisible(find.text('Interface style'));
  await t.tap(find.text('Interface style'));
  await t.pumpAndSettle();
  await t.tap(find.descendant(
      of: find.byType(InterfaceStylePicker), matching: find.text('Expressive')));
  await t.pumpAndSettle();
}

Future<void> _pickPalette(WidgetTester t, String label) async {
  await t.ensureVisible(find.text('Colour palette'));
  await t.tap(find.text('Colour palette'));
  await t.pumpAndSettle();
  final option = find.descendant(of: find.byType(ExpressivePalettePicker),
      matching: find.text(label));
  await t.ensureVisible(option);
  await t.tap(option);
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(ClockFormatController.debugReset);

  testWidgets('all palettes switch live without replacing data or settings', (t) async {
    _phone(t);
    final app = AppState.forTesting()
      ..user = {'name': 'Sam', 'age': 34, 'sex': 'f'}
      ..paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1')
      ..activeWorkout = LiveWorkoutState(startTime: DateTime(2026, 10, 7, 9),
          targetKcal: 300, workoutId: 'in-progress');
    final profile = app.user, band = app.paired, workout = app.activeWorkout;
    final theme = ThemeController.seed(AppThemeChoice.dark, Brightness.light,
        interfaceStyle: InterfaceStyle.expressive);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    await t.pumpWidget(_settingsHost(app, theme));
    await t.pumpAndSettle();
    final state = t.state(find.byType(MoreSettings));
    for (final entry in {
      ExpressivePalette.matteLime: 'Matte lime',
      ExpressivePalette.electricViolet: 'Electric violet',
      ExpressivePalette.freshMint: 'Fresh mint',
      ExpressivePalette.warmAmber: 'Warm amber',
      ExpressivePalette.edge: 'Edge',
    }.entries) {
      await _pickPalette(t, entry.value);
      expect(theme.palette, entry.key);
      final context = t.element(find.byType(MoreSettings));
      expect(P.of(context).bg, P(true, expressive: true, palette: entry.key).bg);
      expect(t.state(find.byType(MoreSettings)), same(state));
      expect(app.user, same(profile));
      expect(app.paired, same(band));
      expect(app.activeWorkout, same(workout));
      expect(theme.choice, AppThemeChoice.dark);
      expect(t.takeException(), isNull);
    }
    await theme.setPalette(ExpressivePalette.freshMint);
    await theme.setInterfaceStyle(InterfaceStyle.original);
    await t.pumpAndSettle();
    expect(find.text('Colour palette'), findsNothing);
    await theme.setInterfaceStyle(InterfaceStyle.expressive);
    await t.pumpAndSettle();
    expect(find.text('Fresh mint'), findsOneWidget);
  });

  testWidgets('failed palette writes leave the old colours and allow retry', (t) async {
    _phone(t);
    final app = AppState.forTesting();
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.dark,
        interfaceStyle: InterfaceStyle.expressive);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    await t.pumpWidget(_settingsHost(app, theme));
    await t.pumpAndSettle();
    final store = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _RefusingStyleStore();
    addTearDown(() => SharedPreferencesStorePlatform.instance = store);
    await _pickPalette(t, 'Fresh mint');
    expect(theme.palette, ExpressivePalette.edge);
    expect(find.text('Could not save the colour palette. Please try again.'),
        findsOneWidget);
    SharedPreferencesStorePlatform.instance = store;
    await _pickPalette(t, 'Fresh mint');
    expect(theme.palette, ExpressivePalette.freshMint);
  });

  testWidgets('palette choices fit large text and expose the selected option', (t) async {
    t.view.physicalSize = const Size(320 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final semantics = t.ensureSemantics();
    try {
      for (final brightness in Brightness.values) {
        final theme = ThemeController.seed(
            brightness == Brightness.dark ? AppThemeChoice.dark : AppThemeChoice.light,
            brightness, interfaceStyle: InterfaceStyle.expressive,
            palette: ExpressivePalette.freshMint);
        ExpressivePalette? picked;
        await t.pumpWidget(_host(Scaffold(body: ExpressivePalettePicker(
          chosen: ExpressivePalette.freshMint, onPick: (value) => picked = value,
        )), theme, scale: 3.1));
        await t.pumpAndSettle();
        for (final label in ['Edge','Matte lime','Electric violet','Fresh mint','Warm amber']) {
          await t.ensureVisible(find.text(label));
          await t.tap(find.text(label));
        }
        expect(picked, ExpressivePalette.warmAmber);
        final selected = find.ancestor(of: find.text('Fresh mint'),
            matching: find.byWidgetPredicate((widget) => widget is Semantics &&
                widget.properties.selected == true));
        expect(selected, findsOneWidget);
        expect(t.takeException(), isNull);
        for (final target in t.widgetList<Pressable>(find.byType(Pressable))) {
          final size = t.getSize(find.byWidget(target));
          expect(size.width, greaterThanOrEqualTo(S.tap));
          expect(size.height, greaterThanOrEqualTo(S.tap));
        }
        await t.pumpWidget(const SizedBox.shrink());
        theme.dispose();
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the settings choice preserves brightness, profile, band and workout',
      (t) async {
    _phone(t);
    final app = AppState.forTesting()
      ..user = {'name': 'Sam', 'age': 34, 'sex': 'f'}
      ..paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1')
      ..activeWorkout = LiveWorkoutState(
          startTime: DateTime(2026, 10, 7, 9), targetKcal: 300,
          workoutId: 'in-progress');
    final profile = app.user;
    final band = app.paired;
    final workout = app.activeWorkout;
    final theme = ThemeController.seed(AppThemeChoice.dark, Brightness.light);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    await t.pumpWidget(_settingsHost(app, theme));
    await t.pumpAndSettle();
    final settingsState = t.state(find.byType(MoreSettings));

    await _pickExpressive(t);

    expect(theme.interfaceStyle, InterfaceStyle.expressive);
    expect(theme.choice, AppThemeChoice.dark);
    expect(theme.effective, Brightness.dark);
    expect(t.state(find.byType(MoreSettings)), same(settingsState));
    expect(app.user, same(profile));
    expect(app.paired, same(band));
    expect(app.activeWorkout, same(workout));
    expect((await SharedPreferences.getInstance())
        .getString('ui.interface_style'), 'expressive');
    expect(find.text('Expressive'), findsOneWidget);

    // Existing appearance remains independently editable after the switch.
    await t.tap(find.text('Appearance'));
    await t.pumpAndSettle();
    expect(theme.choice, AppThemeChoice.system);
    expect(theme.effective, Brightness.light);
    expect(theme.interfaceStyle, InterfaceStyle.expressive);
  });

  testWidgets('a failed style write is reported and the picker can be retried',
      (t) async {
    _phone(t);
    final app = AppState.forTesting();
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.dark);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    await t.pumpWidget(_settingsHost(app, theme));
    await t.pumpAndSettle();
    final store = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _RefusingStyleStore();
    addTearDown(() => SharedPreferencesStorePlatform.instance = store);

    await _pickExpressive(t);

    expect(theme.interfaceStyle, InterfaceStyle.original);
    expect(theme.choice, AppThemeChoice.light);
    expect(find.text('Could not save the interface style. Please try again.'),
        findsOneWidget);
    SharedPreferencesStorePlatform.instance = store;
    await _pickExpressive(t);
    expect(theme.interfaceStyle, InterfaceStyle.expressive);
  });

  testWidgets('profile inputs and optional blanks survive a live style switch',
      (t) async {
    _phone(t);
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light);
    addTearDown(theme.dispose);
    Map<String, dynamic>? saved;
    await t.pumpWidget(_host(
        ProfileSetupView(onSave: (fields) async => saved = fields), theme));
    await t.pumpAndSettle();
    await t.tap(find.text('Female'));
    await t.enterText(find.byType(TextField).first, '34');
    final formState = t.state(find.byType(ProfileSetupView));

    await theme.setInterfaceStyle(InterfaceStyle.expressive);
    await t.pumpAndSettle();
    expect(t.state(find.byType(ProfileSetupView)), same(formState));
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(saved, {'sex': 'f', 'age': 34});
  });

  testWidgets('Expressive settings rows still dispatch each existing action',
      (t) async {
    _phone(t);
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light,
        interfaceStyle: InterfaceStyle.expressive);
    addTearDown(theme.dispose);
    final calls = <String>[];
    await t.pumpWidget(_host(MoreSettingsView(
      interfaceStyle: InterfaceStyle.expressive,
      onAlarm: () => calls.add('alarm'),
      onNotifications: () => calls.add('notifications'),
      onCycleUnits: () => calls.add('units'),
      onCycleAppearance: () => calls.add('appearance'),
      onToggleCycleTracking: () => calls.add('cycle'),
      onData: () => calls.add('data'),
      onToggleTelemetry: () => calls.add('telemetry'),
      onToggleBarcodeLookup: () => calls.add('barcode'),
    ), theme));
    await t.pumpAndSettle();
    for (final label in [
      'Alarm', 'Manage notifications', 'Units', 'Appearance', 'Cycle tracking',
      'Export, backup, import', 'Crash reports', 'Look barcodes up online',
    ]) {
      await t.ensureVisible(find.text(label));
      await t.tap(find.text(label));
      await t.pump();
    }
    expect(calls, ['alarm', 'notifications', 'units', 'appearance', 'cycle',
      'data', 'telemetry', 'barcode']);
  });

  testWidgets('Expressive alarm controls preserve schedule actions and disconnect',
      (t) async {
    _phone(t);
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light,
        interfaceStyle: InterfaceStyle.expressive);
    addTearDown(theme.dispose);
    final schedule = fillDefaultAlarmSchedule(const [
      AlarmScheduleEntry(weekday: 0, hour: 7, minute: 15, enabled: true),
    ]);
    (int, bool)? toggled;
    await t.pumpWidget(_host(AlarmScreenView(
      connected: true, schedule: schedule,
      onToggleDay: (weekday, enabled) async => toggled = (weekday, enabled),
    ), theme));
    await t.pumpAndSettle();
    await t.tap(find.text('Mon'));
    expect(toggled, (0, false));
    expect(find.text('Wake time'), findsOneWidget);

    await t.pumpWidget(_host(AlarmScreenView(
      schedule: schedule,
      onToggleDay: (weekday, enabled) async => toggled = (weekday, enabled),
    ), theme));
    await t.pumpAndSettle();
    expect(find.text('The band is not connected'), findsOneWidget);
    expect(find.text('Mon'), findsNothing);
  });

  testWidgets('Expressive pairing failures retain the skip action', (t) async {
    _phone(t);
    final theme = ThemeController.seed(AppThemeChoice.dark, Brightness.dark,
        interfaceStyle: InterfaceStyle.expressive);
    addTearDown(theme.dispose);
    for (final phase in PairPhase.values) {
      if (phase == PairPhase.paired) continue;
      var skipped = false;
      await t.pumpWidget(_host(PairingView(
        phase: phase, onPair: () {}, onSkip: () => skipped = true,
      ), theme));
      // The scanning phase deliberately has an indeterminate indicator.
      await t.pump();
      await t.tap(find.text('Skip for now'));
      expect(skipped, isTrue, reason: phase.name);
    }
  });

  testWidgets('style choices fit large text and expose their selection', (t) async {
    _phone(t, height: 844);
    final theme = ThemeController.seed(AppThemeChoice.dark, Brightness.dark,
        interfaceStyle: InterfaceStyle.expressive);
    addTearDown(theme.dispose);
    final semantics = t.ensureSemantics();
    try {
      InterfaceStyle? picked;
      await t.pumpWidget(_host(Scaffold(body: InterfaceStylePicker(
        chosen: InterfaceStyle.expressive, onPick: (style) => picked = style,
      )), theme, scale: 3.1));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.ensureVisible(find.text('Expressive'));
      final option = find.ancestor(of: find.text('Expressive'),
          matching: find.byWidgetPredicate((widget) =>
              widget is Semantics && widget.properties.selected == true));
      expect(option, findsOneWidget);
      await t.tap(find.text('Expressive'));
      expect(picked, InterfaceStyle.expressive);
    } finally {
      semantics.dispose();
    }
  });
}
