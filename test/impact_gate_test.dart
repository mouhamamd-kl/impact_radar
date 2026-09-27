import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:impact_radar/impact_radar.dart';

/// Stand-in for a real screen, so the test can name it in the report.
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

  void writeReport(
    List<String> affectedTypes, {
    bool truncated = false,
    Map<String, int> fileDepths = const <String, int>{},
  }) {
    reportFile.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 2,
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
        'affectedTypes': affectedTypes,
        'fileDepths': fileDepths.isEmpty
            ? <String, int>{'lib/bar.dart': 2}
            : fileDepths,
        'hits': <String, List<String>>{
          'lib/bar.dart': <String>['getFoo'],
        },
        'truncated': truncated,
        'truncatedReason': truncated ? 'query budget' : null,
        'stats': <String, dynamic>{'queryCount': 1, 'elapsedMs': 10},
      }),
    );
  }

  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 800));

  testWidgets('shows the banner when an affected screen is mounted', (tester) async {
    writeReport(<String>['FooScreen']);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ImpactGate(
          reportPath: reportPath(),
          child: child!,
        ),
        home: const FooScreen(),
      ),
    );
    await settle(tester);

    expect(find.text('Unverified change on this screen'), findsOneWidget);
    expect(find.text('FooScreen'), findsOneWidget);
    expect(find.textContaining('via getFoo'), findsOneWidget);
  });

  testWidgets('stays quiet on a screen that is not affected', (tester) async {
    writeReport(<String>['FooScreen']);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ImpactGate(
          reportPath: reportPath(),
          child: child!,
        ),
        home: const OtherScreen(),
      ),
    );
    await settle(tester);

    expect(find.text('Unverified change on this screen'), findsNothing);
  });

  testWidgets('Done dismisses the banner', (tester) async {
    writeReport(<String>['FooScreen']);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ImpactGate(
          reportPath: reportPath(),
          child: child!,
        ),
        home: const FooScreen(),
      ),
    );
    await settle(tester);
    expect(find.text('Unverified change on this screen'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await settle(tester);

    expect(find.text('Unverified change on this screen'), findsNothing);
    // The screen itself is untouched.
    expect(find.text('foo'), findsOneWidget);
  });

  testWidgets('enabled: false renders the child with no banner at all', (tester) async {
    writeReport(<String>['FooScreen']);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ImpactGate(
          reportPath: reportPath(),
          enabled: false,
          child: child!,
        ),
        home: const FooScreen(),
      ),
    );
    await settle(tester);

    expect(find.text('Unverified change on this screen'), findsNothing);
    expect(find.text('foo'), findsOneWidget);
  });

  testWidgets('shows depth and marks a truncated report as INCOMPLETE', (tester) async {
    writeReport(<String>['FooScreen'], truncated: true);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ImpactGate(
          reportPath: reportPath(),
          child: child!,
        ),
        home: const FooScreen(),
      ),
    );
    await settle(tester);

    expect(find.textContaining('depth 2'), findsOneWidget);
    expect(find.textContaining('INCOMPLETE'), findsOneWidget);
  });

  testWidgets('a missing report file is not a crash', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ImpactGate(
          reportPath: reportPath(),
          child: child!,
        ),
        home: const FooScreen(),
      ),
    );
    await settle(tester);

    expect(find.text('Unverified change on this screen'), findsNothing);
    expect(find.text('foo'), findsOneWidget);
  });
}
