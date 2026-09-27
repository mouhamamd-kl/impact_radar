import 'package:flutter_test/flutter_test.dart';
import 'package:impact_radar/src/scan/repo_paths.dart';

void main() {
  group('normalisePath', () {
    test('converts backslashes, which is the whole point', () {
      // The server sends forward slashes; File.absolute.path sends backslashes on Windows.
      // If these two forms ever disagree, a cache key misses and the walk silently stops.
      expect(normalisePath(r'C:\a\b.dart'), 'C:/a/b.dart');
      expect(normalisePath('C:/a/b.dart'), 'C:/a/b.dart');
    });

    test('strips trailing separators', () {
      expect(normalisePath('C:/a/b/'), 'C:/a/b');
      expect(normalisePath('C:/a/b///'), 'C:/a/b');
    });

    test('leaves a lone root alone', () {
      expect(normalisePath('C:/'), 'C:/');
    });

    test('is idempotent', () {
      final once = normalisePath(r'C:\a\b\');
      expect(normalisePath(once), once);
    });
  });

  group('RepoPaths', () {
    final paths = RepoPaths(r'C:\repo');

    test('absolute normalises its result', () {
      expect(paths.absolute('lib/foo.dart'), 'C:/repo/lib/foo.dart');
    });

    test('relative strips the root', () {
      expect(paths.relative(r'C:\repo\lib\foo.dart'), 'lib/foo.dart');
    });

    test('relative leaves outside paths alone rather than mangling them', () {
      expect(
        paths.relative('C:/elsewhere/lib/foo.dart'),
        'C:/elsewhere/lib/foo.dart',
      );
    });

    test('contains accepts both slash forms', () {
      expect(paths.contains(r'C:\repo\lib\foo.dart'), isTrue);
      expect(paths.contains('C:/repo/lib/foo.dart'), isTrue);
    });

    test('contains rejects the pub cache and the SDK', () {
      expect(paths.contains('C:/Users/me/AppData/Local/Pub/Cache/x.dart'), isFalse);
      expect(paths.contains('C:/src/flutter/packages/flutter/lib/x.dart'), isFalse);
    });

    test('contains does not match a sibling directory with a shared prefix', () {
      // `C:/repository-other` must not count as inside `C:/repo`.
      expect(paths.contains('C:/repository-other/lib/foo.dart'), isFalse);
    });

    test('round trips', () {
      const rel = 'lib/src/scan/thing.dart';
      expect(paths.relative(paths.absolute(rel)), rel);
    });
  });
}
