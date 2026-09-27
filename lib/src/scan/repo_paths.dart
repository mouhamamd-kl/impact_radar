/// Path handling for a scan.
///
/// This exists as its own unit because path shape is a silent-failure risk, not a crash
/// risk. The analysis server returns paths built from `file:` URIs (forward slashes) while
/// `File(...).absolute.path` gives backslashes on Windows. Use the two forms as map keys and
/// nothing errors: the span cache never hits, the walk cannot expand, and the report's type
/// list comes back empty. Everything goes through [RepoPaths.normalise].
library;

import 'dart:io';

/// Canonical form of a path: forward slashes, no trailing separator.
String normalisePath(String path) {
  var p = path.replaceAll('\\', '/');
  while (p.length > 1 && p.endsWith('/')) {
    final stripped = p.substring(0, p.length - 1);
    // Stop before `C:/` becomes `C:`, which is a drive-relative path and means something
    // entirely different to Windows.
    if (stripped.endsWith(':')) break;
    p = stripped;
  }
  return p;
}

/// Resolves paths against one repository root.
///
/// One instance per scan. [root] must already be absolute and normalised.
class RepoPaths {
  RepoPaths(String root) : root = normalisePath(root);

  /// Absolute, forward-slash path of the repository top level.
  final String root;

  /// Absolute path for a repo-relative, git-style path like `lib/foo.dart`.
  String absolute(String relative) => normalisePath(
    File('$root${Platform.pathSeparator}'
            '${relative.replaceAll('/', Platform.pathSeparator)}')
        .absolute
        .path,
  );

  /// Repo-relative path for an absolute one, or the input unchanged if it lies outside the
  /// repo.
  String relative(String absolute) {
    final p = normalisePath(absolute);
    if (!p.startsWith('$root/')) return p;
    return p.substring(root.length + 1);
  }

  /// True when [absolutePath] is inside the repo.
  ///
  /// Load-bearing, not a nicety. The analysis server indexes everything the package graph
  /// reaches, so a reference to `toList` returns hits inside the pub cache, including the
  /// `analyzer` package's own source. Without this filter a single change reports 1400+
  /// "affected files", none of them the developer's code.
  bool contains(String absolutePath) =>
      normalisePath(absolutePath).startsWith('$root/');
}
