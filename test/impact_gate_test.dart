import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:impact_radar/impact_radar.dart';

/// Stand-ins for real screens, so a test can name them in the report.
class FooScreen extends StatelessWidget {
  const FooScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('foo')));
}

class OtherScreen extends StatelessWidget {
  const OtherScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('other')));
}

/// A small widget, repeated so the "every instance" rule can be checked.
class TicketCard extends StatelessWidget {
  const TicketCard({super.key, required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => SizedBox(height: 40, child: Text(label));
}

/// A second affected widget, to check that depth is read from the report.
///
/// It has to render something, not just a bare SizedBox: a widget with no RenderBox of its
/// own has no rect to outline, which is a real case the code handles by skipping.
class LeafWidget extends StatelessWidget {
  const LeafWidget({super.key});
  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 40, child: Text('leaf'));
}

void main() {
  late Directory tempDir;
  late File reportFile;
  String reportPath() => reportFile.path;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('impact_radar_test');
    reportFile = File('${tempDir.path}${Platform.pathSeparator}impact.json');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Writes a report. [widgetTypes] is what the runtime matches against mounted widgets;
  /// [affectedTypes] stands in for the wider superset, which is used for a false-positive test.
  void writeReport(
    List<String> widgetTypes, {
    bool truncated = false,
    List<String> affectedTypes = const <String>[],
    Map<String, int> typeDepths = const <String, int>{},
  }) {
    final types = affectedTypes.isEmpty
        ? widgetTypes
        : <String>[...widgetTypes, ...affectedTypes];
    reportFile.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 3,
        'generatedAt': DateTime.now().toIso8601String(),
        'base': 'HEAD',
        'root': tempDir.path,
        'changedFiles': <String>['lib/foo.dart'],
        'seeds': <Map<String, dynamic>>[
          <String, dynamic>{
            'file': 'lib/foo.dart',
            'line': 3,
            'symbol': 'getFoo',
            'referenceCount': 2,
            'depth': 0,
          },
        ],
        'affectedFiles': <String>['lib/bar.dart'],
        'affectedTypes': types,
        'typeDepths': typeDepths.isEmpty
            ? <String, int>{for (final t in widgetTypes) t: 2}
            : typeDepths,
        'widgetTypes': widgetTypes,
        'fileDepths': <String, int>{'lib/bar.dart': 2},
        'hits': <String, List<String>>{
          'lib/bar.dart': <String>['getFoo'],
        },
        'truncated': truncated,
        'truncatedReason': truncated ? 'query budget' : null,
        'stats': <String, dynamic>{'queryCount': 1, 'elapsedMs': 10},
      }),
    );
  }

  /// Mounts [app] inside the gate.
  ///
  /// The gate wraps the whole app and walks its child, so anything we want detected has to
  /// be *inside* that child. A sibling of the gate is invisible to it.
  Widget gated(Widget app, {ImpactMode mode = ImpactMode.widget}) => MaterialApp(
    home: ImpactGate(reportPath: reportPath(), mode: mode, child: app),
  );

  /// Pumps past the poll interval, then a frame so the highlight ticker computes rects.
  ///
  /// The ticker is not a Timer — it needs a real vsync, which in tests means `pump`.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
  }

  ImpactHighlightPainter painterOf(WidgetTester tester) =>
      tester
          .widget<CustomPaint>(find.byKey(impactHighlightsKey))
          .painter as ImpactHighlightPainter;

  group('the card', () {
    testWidgets('appears when an affected widget is on screen', (tester) async {
      writeReport(<String>['FooScreen']);

      await tester.pumpWidget(gated(const FooScreen()));
      await settle(tester);

      expect(find.byKey(impactCardKey), findsOneWidget);
      expect(find.text('Unverified change'), findsOneWidget);
      expect(find.text('FooScreen'), findsOneWidget);
    });

    testWidgets('stays away when nothing affected is on screen', (tester) async {
      writeReport(<String>['FooScreen']);

      await tester.pumpWidget(gated(const OtherScreen()));
      await settle(tester);

      expect(find.byKey(impactCardKey), findsNothing);
    });

    testWidgets('Dismiss hides it and leaves the app alone', (tester) async {
      writeReport(<String>['FooScreen']);

      await tester.pumpWidget(gated(const FooScreen()));
      await settle(tester);
      expect(find.byKey(impactCardKey), findsOneWidget);

      await tester.tap(find.byKey(impactDismissKey));
      await settle(tester);

      expect(find.byKey(impactCardKey), findsNothing);
      expect(find.text('foo'), findsOneWidget);
    });

    testWidgets('collapses to a count and expands again', (tester) async {
      writeReport(<String>['FooScreen']);

      await tester.pumpWidget(gated(const FooScreen()));
      await settle(tester);
      expect(find.byKey(impactWidgetToggleKey), findsOneWidget);

      await tester.tap(find.byKey(impactCollapseKey));
      await settle(tester);
      expect(find.byKey(impactWidgetToggleKey), findsNothing);
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.byKey(impactExpandKey));
      await settle(tester);
      expect(find.byKey(impactWidgetToggleKey), findsOneWidget);
    });

    testWidgets('reports depth and a truncated scan honestly', (tester) async {
      writeReport(
        <String>['FooScreen'],
        truncated: true,
        typeDepths: <String, int>{'FooScreen': 0},
      );

      await tester.pumpWidget(gated(const FooScreen()));
      await settle(tester);

      expect(find.textContaining('1 direct'), findsOneWidget);
      expect(find.textContaining('INCOMPLETE'), findsOneWidget);
    });

    testWidgets('enabled: false renders the child with no overlay at all', (tester) async {
      writeReport(<String>['FooScreen']);

      await tester.pumpWidget(
        MaterialApp(
          home: ImpactGate(
            reportPath: reportPath(),
            enabled: false,
            child: const FooScreen(),
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(impactCardKey), findsNothing);
      expect(find.byKey(impactHighlightsKey), findsNothing);
      expect(find.text('foo'), findsOneWidget);
    });

    testWidgets('a missing report file is not a crash', (tester) async {
      await tester.pumpWidget(gated(const FooScreen()));
      await settle(tester);

      expect(find.byKey(impactCardKey), findsNothing);
      expect(find.text('foo'), findsOneWidget);
    });
  });

  group('widget mode', () {
    testWidgets('outlines every instance of an affected widget', (tester) async {
      // Three instances, one class name. All three are affected and all three must be
      // outlined; sampling would be a lie by omission.
      writeReport(
        <String>['TicketCard'],
        typeDepths: <String, int>{'TicketCard': 0},
      );

      await tester.pumpWidget(
        gated(
          const Scaffold(
            body: Column(
              children: <Widget>[
                TicketCard(label: 'a'),
                TicketCard(label: 'b'),
                TicketCard(label: 'c'),
              ],
            ),
          ),
        ),
      );
      await settle(tester);

      expect(painterOf(tester).highlights, hasLength(3));
    });

    testWidgets('the nearest hit reads louder than a far one', (tester) async {
      writeReport(
        <String>['TicketCard', 'LeafWidget'],
        typeDepths: <String, int>{'TicketCard': 0, 'LeafWidget': 3},
      );

      await tester.pumpWidget(
        gated(
          const Scaffold(
            body: Column(
              children: <Widget>[
                TicketCard(label: 'a'),
                LeafWidget(),
              ],
            ),
          ),
        ),
      );
      await settle(tester);

      final highlights = painterOf(tester).highlights;
      final near = highlights.where((h) => h.depth == 0).toList();
      final far = highlights.where((h) => h.depth == 3).toList();
      expect(near, hasLength(1));
      expect(far, hasLength(1));
      expect(near.single.isNearest, isTrue);
      expect(far.single.isNearest, isFalse);
    });

    testWidgets('screen mode shows the card but no outlines', (tester) async {
      writeReport(<String>['TicketCard']);

      await tester.pumpWidget(
        gated(const Scaffold(body: TicketCard(label: 'a')), mode: ImpactMode.screen),
      );
      await settle(tester);

      expect(find.byKey(impactHighlightsKey), findsNothing);
      expect(find.byKey(impactCardKey), findsOneWidget);
    });

    testWidgets('the card toggle switches to screen mode and back', (tester) async {
      writeReport(<String>['TicketCard']);

      await tester.pumpWidget(
        gated(const Scaffold(body: TicketCard(label: 'a'))),
      );
      await settle(tester);
      expect(find.byKey(impactHighlightsKey), findsOneWidget);

      await tester.tap(find.byKey(impactScreenToggleKey));
      await settle(tester);
      expect(find.byKey(impactHighlightsKey), findsNothing);

      await tester.tap(find.byKey(impactWidgetToggleKey));
      await settle(tester);
      expect(find.byKey(impactHighlightsKey), findsOneWidget);
    });

    testWidgets('a model in affectedTypes does not match a same-named widget', (tester) async {
      // The false positive that narrowing to widgetTypes exists to prevent: a `Ticket` model
      // in the report's wider set, a `Ticket` widget on screen, no real overlap.
      writeReport(<String>[], affectedTypes: <String>['TicketCard']);

      await tester.pumpWidget(
        gated(const Scaffold(body: TicketCard(label: 'a'))),
      );
      await settle(tester);

      expect(painterOf(tester).highlights, isEmpty);
      expect(find.byKey(impactCardKey), findsNothing);
    });

    testWidgets('outlines are clipped to the viewport', (tester) async {
      // A widget far below the fold still has global coordinates; unclipped, its box would be
      // drawn over unrelated UI or off the screen entirely.
      writeReport(
        <String>['TicketCard'],
        typeDepths: <String, int>{'TicketCard': 0},
      );

      await tester.pumpWidget(
        gated(
          const Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  TicketCard(label: 'a'),
                  SizedBox(height: 2000),
                  TicketCard(label: 'below the fold'),
                ],
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final bounds = Offset.zero & size;
      for (final h in painterOf(tester).highlights) {
        expect(bounds.contains(h.rect.topLeft), isTrue);
        expect(h.rect.bottom, lessThanOrEqualTo(size.height + 0.5));
        expect(h.rect.right, lessThanOrEqualTo(size.width + 0.5));
      }
    });

    testWidgets('the overlay never highlights itself', (tester) async {
      // If the walk started at the gate's own element, the overlay's own widgets would be
      // candidates the moment a report named something common like Container or Padding.
      writeReport(<String>['Container', 'CustomPaint', 'Positioned']);

      await tester.pumpWidget(
        gated(const Scaffold(body: TicketCard(label: 'a'))),
      );
      await settle(tester);

      // No such types are declared in the fixture, so nothing matches and the layer is empty.
      expect(painterOf(tester).highlights, isEmpty);
    });
  });
}
