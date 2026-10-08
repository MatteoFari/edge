import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  testWidgets(
    'breathing has a short label and keeps its separate chart on a narrow Health screen',
    (t) async {
      t.view.physicalSize = const Size(390 * 3, 800 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light, style: InterfaceStyle.expressive),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const Scaffold(
            body: HealthScreen(
              data: HealthData(
                today: {
                  'resp': {
                    'value': 12.3,
                    'confidence': 0.25,
                    'tier': 'ESTIMATE',
                    'label': 'Breathing rate',
                    'experimental': true,
                    'chart_key': 'resp_rate_experimental',
                  },
                },
              ),
              explore: ExploreData(),
              vitals: VitalsData(),
              labs: LabsData(),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.text('Breathing rate'),
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('health-tab-0')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Breathing rate'), findsOneWidget);
      expect(find.textContaining('Experimental'), findsNothing);
      expect(find.text('12.3'), findsWidgets);
      expect(t.takeException(), isNull);
      expect(
        specOf('resp_rate_experimental').chartKey,
        'resp_rate_experimental',
      );
      expect(specOf('resp_rate_experimental').title, 'Breathing rate');
      expect(
        const HealthData(
          today: {
            'resp': {
              'value': 12.3,
              'label': 'Breathing rate',
              'chart_key': 'resp_rate_experimental',
            },
          },
        ).respChartKey,
        'resp_rate_experimental',
      );
      expect(
        const HealthData(
          today: {
            'resp': {'value': 14.2},
          },
        ).respChartKey,
        'resp_rate',
      );
    },
  );
}
