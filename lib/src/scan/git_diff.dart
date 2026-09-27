/// Parsing of `git diff --unified=0` output into the files and lines that changed.
library;

import 'dart:convert';
import 'dart:io';

/// One file that changed, plus the 1-based line numbers that changed in it.
class ChangedFile {
  const ChangedFile(this.path, this.lines, {this.isNew = false});

  /// Repository-relative path, always with forward slashes (git style).
  final String path;

  /// 1-based line numbers in the *new* revision of the file.
  final List<int> lines;

  /// True when git created the file, so every line is "new". New files are scanned by
  /// their declarations rather than line by line, which is both far cheaper and more
  /// precise: nobody cares that a `Container` was added on line 40, they care who uses
  /// the widget the file declares.
  final bool isNew;

  @override
  String toString() => '$path:${lines.join(',')}';
}

/// Runs git and returns the changed files.
///
/// [base] is the git ref to diff against. Defaults to `HEAD`, which means "whatever is
/// uncommitted right now" — the right default for the edit-then-scan loop.
Future<List<ChangedFile>> readChangedFiles({
  required String root,
  String base = 'HEAD',
  bool staged = false,
}) async {
  final args = <String>[
    'diff',
    '--unified=0',
    '--no-color',
    '--no-ext-diff',
    // Renames/copies/modifications/additions only. Deletions have no new-side lines to
    // scan, so they are reported separately by the caller if ever needed.
    '--diff-filter=ACMR',
    if (staged) '--cached',
    base,
  ];

  final result = await Process.run('git', args, workingDirectory: root);
  if (result.exitCode != 0) {
    throw StateError(
      'git diff failed (${result.exitCode}): ${result.stderr}',
    );
  }
  return parseUnifiedDiff(result.stdout as String);
}

/// The repository's top level, or null if [from] is not inside a git repo.
///
/// Diff paths are always relative to this, never to the current directory. In a monorepo
/// that matters: running from `apps/tam_supervisor` still reports
/// `apps/tam_supervisor/lib/foo.dart` and `packages/core_x/bar.dart`, so paths must be
/// resolved against the git root or they will not exist on disk.
Future<String?> findGitRoot(String from) async {
  final result = await Process.run(
    'git',
    <String>['rev-parse', '--show-toplevel'],
    workingDirectory: from,
  );
  if (result.exitCode != 0) return null;
  return (result.stdout as String).trim();
}

/// Parses unified diff text. Exposed for tests.
List<ChangedFile> parseUnifiedDiff(String diff) {
  final files = <ChangedFile>[];
  ChangedFile? current;

  var sawNewFileMode = false;

  for (final line in const LineSplitter().convert(diff)) {
    if (line.startsWith('new file mode ')) {
      sawNewFileMode = true;
      continue;
    }
    if (line.startsWith('deleted file mode ') || line.startsWith('index ')) {
      if (!line.startsWith('index ')) sawNewFileMode = false;
      continue;
    }

    if (line.startsWith('+++ ')) {
      var path = line.substring(4).trim();
      // Strip a trailing timestamp if present: "b/lib/foo.dart\t2024-01-01 ..."
      final tab = path.indexOf('\t');
      if (tab >= 0) path = path.substring(0, tab);
      if (path == '/dev/null') {
        current = null;
        sawNewFileMode = false;
        continue;
      }
      if (path.startsWith('b/')) path = path.substring(2);
      current = ChangedFile(path, <int>[], isNew: sawNewFileMode);
      files.add(current);
      sawNewFileMode = false;
      continue;
    }

    if (line.startsWith('@@')) {
      // @@ -oldStart,oldCount +newStart,newCount @@ optional section heading
      final m = RegExp(
        r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@',
      ).firstMatch(line);
      if (m == null || current == null) continue;
      final start = int.parse(m.group(1)!);
      final count = m.group(2) == null ? 1 : int.parse(m.group(2)!);
      for (var i = 0; i < count; i++) {
        current.lines.add(start + i);
      }
      continue;
    }
  }

  // A file with no new-side lines (pure deletion) has nothing to scan.
  return files.where((f) => f.lines.isNotEmpty).toList();
}
