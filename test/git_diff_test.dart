import 'package:flutter_test/flutter_test.dart';
import 'package:impact_radar/src/scan/git_diff.dart';

void main() {
  group('parseUnifiedDiff', () {
    test('extracts new-side line numbers from a hunk', () {
      const diff = '''
diff --git a/lib/foo.dart b/lib/foo.dart
index 1111111..2222222 100644
--- a/lib/foo.dart
+++ b/lib/foo.dart
@@ -10,0 +11,2 @@ class Foo {
+  final x = 1;
+  final y = 2;
''';

      final files = parseUnifiedDiff(diff);

      expect(files, hasLength(1));
      expect(files.single.path, 'lib/foo.dart');
      expect(files.single.lines, <int>[11, 12]);
    });

    test('handles multiple hunks in one file', () {
      const diff = '''
--- a/lib/foo.dart
+++ b/lib/foo.dart
@@ -1,0 +2,1 @@
+one
@@ -20,2 +21,2 @@
+two
+three
''';

      final files = parseUnifiedDiff(diff);

      expect(files.single.lines, <int>[2, 21, 22]);
    });

    test('omits a single-line hunk count when the diff omits it', () {
      // "@@ -5 +7 @@" means one line, starting at 7.
      const diff = '''
--- a/a.dart
+++ b/a.dart
@@ -5 +7 @@
+only
''';

      expect(parseUnifiedDiff(diff).single.lines, <int>[7]);
    });

    test('drops files deleted with no new-side lines', () {
      const diff = '''
--- a/gone.dart
+++ /dev/null
@@ -1,3 +0,0 @@
-one
-two
-three
''';

      expect(parseUnifiedDiff(diff), isEmpty);
    });

    test('strips a trailing timestamp after the path', () {
      const diff = '''
--- a/lib/foo.dart\t2024-01-01 10:00:00
+++ b/lib/foo.dart\t2024-01-02 10:00:00
@@ -1,0 +2,1 @@
+x
''';

      expect(parseUnifiedDiff(diff).single.path, 'lib/foo.dart');
    });

    test('returns empty for an empty diff', () {
      expect(parseUnifiedDiff(''), isEmpty);
    });
  });
}
