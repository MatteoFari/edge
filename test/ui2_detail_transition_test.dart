import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show ChartPoint;
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Routes extends NavigatorObserver {
  final pushes = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
  }
}

Widget _frame(
  Widget home,
  _Routes routes, {
  bool reduced = false,
  InterfaceStyle style = InterfaceStyle.expressive,
  TargetPlatform platform = TargetPlatform.android,
  Brightness brightness = Brightness.light,
  AppState? app,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider(
      create: (_) => ThemeController.seed(
        AppThemeChoice.light,
        brightness,
        interfaceStyle: style,
      ),
    ),
    if (app != null) ChangeNotifierProvider<AppState>.value(value: app),
  ],
  child: MaterialApp(
    theme: buildTheme(brightness, style: style).copyWith(platform: platform),
    navigatorObservers: [routes],
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Scaffold(body: home),
  ),
);

Widget _card() => Padding(
  padding: const EdgeInsets.only(left: 16, right: 16, top: 150),
  child: Surface(
    key: const ValueKey('source-card'),
    destination: const _Detail(),
    child: const SizedBox(height: 130, child: Text('Open this card')),
  ),
);

Rect _clip(WidgetTester t) {
  final finder = find.byKey(const ValueKey('detail-morph-surface'));
  return t
      .widget<ClipPath>(finder)
      .clipper!
      .getClip(t.getSize(finder))
      .getBounds();
}

class _Detail extends StatefulWidget {
  const _Detail();
  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  int edits = 0;
  @override
  Widget build(BuildContext c) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Text('Full page $edits'),
          Pressable(
            onTap: () => setState(() => edits++),
            child: const Text('Keep my edits'),
          ),
          Pressable(
            onTap: () => Navigator.pop(c, 'saved'),
            child: const Text('Close details'),
          ),
        ],
      ),
    ),
  );
}

void main() {
  Future<void> size(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 850);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  testWidgets(
    'settings rows use their own surface and preserve return actions',
    (t) async {
      await size(t);
      final routes = _Routes();
      var returns = 0;
      await t.pumpWidget(
        _frame(
          Surface(
            child: SetRow(
              Icons.alarm,
              C.orange,
              'Alarm settings',
              onNavigate: (open) async {
                await open<void>(const _Detail());
                returns++;
              },
            ),
          ),
          routes,
        ),
      );
      await t.pumpAndSettle();
      final origin = t.getRect(find.byType(SetRow));
      await t.tap(find.text('Alarm settings'));
      await t.pump();
      await t.pump();
      await t.pump();
      expect(_clip(t), origin);
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(returns, 1);
      expect(find.text('Alarm settings'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('settings cards retain their correct destinations', (t) async {
    await size(t);
    final routes = _Routes();
    final destinations = <String>[];
    await t.pumpWidget(
      _frame(
        MoreSettingsView(
          onNavigate: (open, page) async {
            destinations.add(page.runtimeType.toString());
            await open<void>(const _Detail());
          },
        ),
        routes,
      ),
    );
    await t.pumpAndSettle();
    for (final entry in {
      'Alarm': 'AlarmScreen',
      'Manage notifications': 'NotificationSettings',
      'Export, backup, import': 'DataScreen',
      'Tasker and Shortcuts': 'AutomationSettings',
    }.entries) {
      final row = find.text(entry.key);
      await t.ensureVisible(row);
      await t.pumpAndSettle();
      await t.tap(row);
      await t.pump();
      await t.pumpAndSettle();
      expect(destinations.last, entry.value);
      expect(
        routes.pushes.last.runtimeType.toString(),
        contains('DetailMorph'),
      );
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('device detail grows from the whole source card', (t) async {
    await size(t);
    final routes = _Routes();
    await t.pumpWidget(
      _frame(
        const Padding(
          padding: EdgeInsets.all(S.x4),
          child: SourceRow(
            HealthSource(
              name: 'My band',
              kind: 'band',
              tier: null,
              icon: Icons.watch,
            ),
            destination: _Detail(),
          ),
        ),
        routes,
      ),
    );
    await t.pumpAndSettle();
    final origin = t.getRect(find.byType(SourceRow));
    await t.tap(find.text('My band'));
    await t.pump();
    await t.pump();
    await t.pump();
    expect(_clip(t), origin);
    await t.pumpAndSettle();
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(SourceRow)), origin);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'card grows from its bounds, fades details, and reverses on Back',
    (t) async {
      await size(t);
      final routes = _Routes();
      await t.pumpWidget(_frame(_card(), routes));
      await t.pumpAndSettle();
      final origin = t.getRect(find.byKey(const ValueKey('source-card')));
      await t.tap(find.text('Open this card'));
      await t.pump();
      await t.pump();
      await t.pump();
      expect(
        routes.pushes.last.runtimeType.toString(),
        contains('DetailMorph'),
      );
      expect(_clip(t), origin);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('detail-morph-surface')),
          matching: find.byType(SlideTransition),
        ),
        findsNothing,
      );
      await t.pump(const Duration(milliseconds: 90));
      final during = _clip(t);
      expect(during.width, greaterThan(origin.width));
      expect(during.height, greaterThan(origin.height));
      expect(during.top, lessThan(origin.top));
      expect(routes.pushes.last.settings.name, '_Detail');
      final details = t.state(find.byType(_Detail));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-morph-surface')), findsNothing);
      expect(t.getSize(find.byType(_Detail)), const Size(390, 850));
      expect(identical(t.state(find.byType(_Detail)), details), isTrue);
      await t.binding.handlePopRoute();
      await t.pump();
      await t.pump(const Duration(milliseconds: 90));
      expect(
        find.byKey(const ValueKey('detail-morph-surface')),
        findsOneWidget,
      );
      expect(find.byType(RawImage), findsNothing,
          reason: 'Returning must not replay the opening card snapshot');
      await t.pumpAndSettle();
      expect(find.byType(_Detail), findsNothing);
      expect(t.getRect(find.byKey(const ValueKey('source-card'))), origin);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid taps create one route, and it can open again after returning',
    (t) async {
      await size(t);
      final routes = _Routes();
      await t.pumpWidget(_frame(_card(), routes));
      await t.pumpAndSettle();
      final button = t.widget<Pressable>(
        find.descendant(
          of: find.byKey(const ValueKey('source-card')),
          matching: find.byType(Pressable),
        ),
      );
      button.onTap!();
      button.onTap!();
      await t.pump();
      await t.pumpAndSettle();
      expect(routes.pushes.length, 2);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await t.tap(find.text('Open this card'));
      await t.pump();
      await t.pumpAndSettle();
      expect(routes.pushes.length, 3);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('a removed source cannot open a page after a delayed read', (
    t,
  ) async {
    final routes = _Routes();
    late DetailOpener open;
    await t.pumpWidget(
      _frame(
        DetailLink(
          builder: (navigate) {
            open = navigate;
            return const Text('Source');
          },
        ),
        routes,
      ),
    );
    await t.pumpAndSettle();
    await t.pumpWidget(_frame(const Text('Source removed'), routes));
    await t.pumpAndSettle();
      expect(await open<Object>(const _Detail()), isNull);
    expect(routes.pushes.length, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'reduced motion opens and closes immediately without a snapshot',
    (t) async {
      await size(t);
      final routes = _Routes();
      await t.pumpWidget(_frame(_card(), routes, reduced: true));
      await t.pumpAndSettle();
      await t.tap(find.text('Open this card'));
      await t.pump();
      expect(find.text('Full page 0'), findsOneWidget);
      expect(routes.pushes.last is MaterialPageRoute, isTrue);
      expect(
        (routes.pushes.last as PageRoute).transitionDuration,
        Duration.zero,
      );
      expect(find.byKey(const ValueKey('detail-morph-surface')), findsNothing);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Open this card'), findsOneWidget);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('native navigation remains available for $platform', (t) async {
      await size(t);
      final routes = _Routes();
      await t.pumpWidget(
        _frame(
          _card(),
          routes,
          style: platform == TargetPlatform.android
              ? InterfaceStyle.original
              : InterfaceStyle.expressive,
          platform: platform,
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Open this card'));
      await t.pump();
      await t.pumpAndSettle();
      expect(routes.pushes.last is MaterialPageRoute, isTrue);
      expect(find.byKey(const ValueKey('detail-morph-surface')), findsNothing);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Open this card'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets(
    'typed route results and return callbacks survive the expansion',
    (t) async {
      await size(t);
      String? result;
      final routes = _Routes();
      await t.pumpWidget(
        _frame(
          DetailLink(
            builder: (open) => Surface(
              onTap: () async => result = await open<String>(const _Detail()),
              child: const Text('Open this card'),
            ),
          ),
          routes,
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Open this card'));
      await t.pump();
      await t.pumpAndSettle();
      await t.tap(find.text('Close details'));
      await t.pumpAndSettle();
      expect(result, 'saved');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('theme rebuild keeps the same detail state and edits', (t) async {
    await size(t);
    final routes = _Routes();
    final card = _card();
    await t.pumpWidget(_frame(card, routes));
    await t.pumpAndSettle();
    await t.tap(find.text('Open this card'));
    await t.pump();
    await t.pumpAndSettle();
    await t.tap(find.text('Keep my edits'));
    await t.pumpAndSettle();
    final state = t.state(find.byType(_Detail));
    await t.pumpWidget(_frame(card, routes, brightness: Brightness.dark));
    await t.pumpAndSettle();
    expect(find.text('Full page 1'), findsOneWidget);
    expect(identical(t.state(find.byType(_Detail)), state), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('Health trend opens the same metric from the actual chart card', (
    t,
  ) async {
    await size(t);
    final now = DateTime.now();
    final points = <ChartPoint>[
      for (var i = 0; i < 8; i++)
        (
          t:
              DateTime(
                now.year,
                now.month,
                now.day - 7 + i,
                12,
              ).millisecondsSinceEpoch ~/
              1000,
          v: 55.0 - i,
        ),
    ];
    final app = AppState.forTesting()..repo = _Repo(points);
    addTearDown(app.dispose);
    final routes = _Routes();
    await t.pumpWidget(
      _frame(
        HealthScreen(data: HealthData(charts: {'resting_hr': points})),
        routes,
        app: app,
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Trends'));
    await t.pumpAndSettle();
    final card = find.byType(TrendCard).first;
    await t.ensureVisible(card);
    await t.pumpAndSettle();
    final origin = t.getRect(card);
    await t.tap(card);
    await t.pump();
    await t.pump();
    await t.pump();
    expect(_clip(t), origin);
    await t.pumpAndSettle();
    expect(
      t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey,
      'resting_hr',
    );
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('Trends'), findsOneWidget);
    expect(t.getRect(find.byType(TrendCard).first), origin);
    expect(t.takeException(), isNull);
  });
}

class _Repo extends LocalRepository {
  final List<ChartPoint> points;
  _Repo(this.points);
  @override
  Future<List<String>> availableDays() async => [todayLabel()];
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => {
    'points': [
      for (final point in points) {'t': point.t, 'v': point.v},
    ],
  };
}
