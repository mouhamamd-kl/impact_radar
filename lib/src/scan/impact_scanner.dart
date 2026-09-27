/// The scan itself: changed declarations -> transitive closure over the reference graph.
///
/// The analysis server already maintains a reference index, so there is no graph to build
/// and no cache to invalidate. This walks that index breadth-first, following every
/// reference it finds, and records how many hops each file was from the original change.
///
/// Filtering and ranking are deliberately *not* applied. The point of this step is to make
/// the whole graph visible; deciding what to cut is a later concern, made with data in hand.
library;

import 'dart:io';

import '../model/impact_report.dart';
import 'git_diff.dart';
import 'lsp_client.dart';

typedef LogFn = void Function(String message);

class ImpactScanner {
  ImpactScanner({
    required this.root,
    this.gitRoot,
    this.dartPath,
    LogFn? log,
  }) : _log = log ?? ((_) {});

  /// Project root, i.e. the directory holding `.dart_tool/package_config.json`. This is
  /// what the analysis server is rooted at, and it decides which package graph is visible.
  final String root;

  /// Repository root. Diff paths are relative to this, not to [root], which differs in a
  /// monorepo. Detected from [root] when not supplied.
  final String? gitRoot;

  /// Which `dart` runs the analysis server. Defaults to the dart running this script,
  /// which is right when you launch the scanner with the project's own SDK.
  final String? dartPath;

  final LogFn _log;
  int _queryCount = 0;
  bool verbose = false;

  /// Repo root, forward slashes. Path helpers resolve against it.
  late String _repoRoot;
  late String _repoPrefix;

  /// abs path -> the class-like spans declared in it. Populated at most once per file for
  /// the whole scan. This is the single most important optimisation here: the closure
  /// revisits the same file from many different edges, and without this the same
  /// documentSymbol is fetched dozens of times.
  final Map<String, List<_ClassSpan>> _spans = <String, List<_ClassSpan>>{};

  /// abs path -> every class name declared in it, for the report's type list.
  final Map<String, Set<String>> _classNames = <String, Set<String>>{};

  /// Server commands to try, in order. Newer SDKs ship `language-server`; `analysis-server`
  /// is the older name and still speaks LSP.
  static const List<List<String>> _serverCandidates = <List<String>>[
    <String>['language-server'],
    <String>['analysis-server', '--protocol=lsp'],
  ];

  Future<ImpactReport> scan({
    String base = 'HEAD',
    bool staged = false,
    int maxDepth = 8,
    int maxFiles = 2000,
    int maxQueries = 5000,
  }) async {
    final stopwatch = Stopwatch()..start();
    _queryCount = 0;
    _spans.clear();
    _classNames.clear();

    // The project root is turned into a `file:` URI for the analysis server, and a
    // relative path produces a malformed one — the server then reports "File is not being
    // analyzed" for everything. Canonicalise before it is used for anything.
    final projectRoot = _norm(Directory(root).absolute.path);

    final repoRoot = gitRoot ?? await findGitRoot(projectRoot) ?? projectRoot;
    _repoRoot = _norm(Directory(repoRoot).absolute.path);
    _repoPrefix = _repoRoot;
    if (_repoRoot != projectRoot) {
      _log('Project: $projectRoot');
      _log('Repo:    $_repoRoot');
    }

    final changes = await readChangedFiles(
      root: _repoRoot,
      base: base,
      staged: staged,
    );

    final dartChanges = changes
        .where((c) => _isDartFile(c.path) && !_isGenerated(c.path))
        .toList();

    if (dartChanges.isEmpty) {
      stopwatch.stop();
      _log('No changed Dart files against $base. Nothing to do.');
      return ImpactReport(
        generatedAt: DateTime.now(),
        base: base,
        root: _repoRoot,
        changedFiles: changes.map((c) => c.path).toList(),
        seeds: const <ImpactSeed>[],
        affectedFiles: const <String>[],
        affectedTypes: const <String>[],
        fileDepths: const <String, int>{},
        hits: const <String, List<String>>{},
        queryCount: 0,
        elapsed: stopwatch.elapsed,
      );
    }

    _log('Changed Dart files: ${dartChanges.length} of ${changes.length} total');
    for (final c in dartChanges.take(15)) {
      final tag = c.isNew ? 'new' : '${c.lines.length} line(s)';
      _log('  [$tag] ${c.path}');
    }
    if (dartChanges.length > 15) {
      _log('  ... and ${dartChanges.length - 15} more');
    }

    final executable = dartPath ?? Platform.resolvedExecutable;
    _log('Analysis server dart: $executable');

    final client = LspClient(log: _verbose);
    await _startAnyServer(client, executable, projectRoot);

    try {
      await client.initialize(rootPath: projectRoot);

      // BFS state.
      final queue = <_Node>[];
      final depthOf = <String, int>{};
      final expanded = <String>{};
      final seeds = <ImpactSeed>[];
      final fileDepths = <String, int>{};
      final hitsByFile = <String, Set<String>>{};

      // --- seeds: the declarations the diff actually touched -------------------------
      for (final change in dartChanges) {
        final abs = _absolute(change.path);
        if (!File(abs).existsSync()) continue;

        // A new file is scanned by what it declares. Nobody cares that a `Container` was
        // added on line 40; they care who uses the classes the file declares.
        final touched = change.isNew
            ? _topLevelDeclarations(await _spansFor(client, abs))
            : _declarationsCovering(
                await _treeFor(client, abs),
                change.lines,
              );

        if (touched.isEmpty) continue;
        _log(
          '  seed: ${change.path} -> ${touched.length} declaration(s): '
          '${touched.take(4).map((d) => d.name).join(', ')}'
          '${touched.length > 4 ? ', +${touched.length - 4}' : ''}',
        );
        for (final decl in touched) {
          _enqueue(
            _Node(abs, decl.line, decl.character, decl.name),
            depthOf,
            queue,
          );
        }
      }

      if (queue.isEmpty) {
        stopwatch.stop();
        _log('No declarations matched the changed lines. Nothing to expand.');
        return ImpactReport(
          generatedAt: DateTime.now(),
          base: base,
          root: _repoRoot,
          changedFiles: changes.map((c) => c.path).toList(),
          seeds: const <ImpactSeed>[],
          affectedFiles: const <String>[],
          affectedTypes: const <String>[],
          fileDepths: const <String, int>{},
          hits: const <String, List<String>>{},
          queryCount: _queryCount,
          elapsed: stopwatch.elapsed,
        );
      }

      _log('');
      _log('Seeds: ${queue.length}. Walking the graph (depth cap $maxDepth)...');

      // --- the walk -----------------------------------------------------------------
      String? truncatedReason;

      while (queue.isNotEmpty) {
        if (_queryCount >= maxQueries) {
          truncatedReason = 'query budget ($maxQueries)';
          break;
        }
        if (fileDepths.length >= maxFiles) {
          truncatedReason = 'file budget ($maxFiles)';
          break;
        }

        final node = queue.removeAt(0);
        final key = node.key;
        if (!expanded.add(key)) continue;
        final depth = depthOf[key]!;
        if (depth > maxDepth) continue;

        _queryCount++;
        final locations = await client.references(
          path: _norm(node.path),
          line: node.line,
          character: node.character,
        );

        // A reference back into the file we are standing in is not impact, and neither is
        // anything outside the repo (pub cache, the SDK, another checkout).
        final selfPath = _norm(node.path);
        final kept = <LspLocation>[];
        for (final loc in locations) {
          if (_norm(loc.path) == selfPath) continue;
          if (!_insideRepo(loc.path)) continue;
          kept.add(loc);
        }
        if (kept.isEmpty) continue;

        seeds.add(
          ImpactSeed(
            file: _relative(node.path),
            line: node.line + 1,
            symbol: node.name,
            referenceCount: kept.length,
            depth: depth,
          ),
        );

        for (final loc in kept) {
          final rel = _relative(loc.path);
          final previous = fileDepths[rel];
          if (previous == null || depth < previous) fileDepths[rel] = depth;
          (hitsByFile[rel] ??= <String>{}).add(node.name);

          // The next thing to expand is the *type* enclosing this reference. Expanding the
          // member would be wrong: a reference landing inside `SomeWidget.build` means the
          // widget uses the changed thing, and `SomeWidget` is what someone else can
          // reference. `build` itself is called by the framework everywhere.
          //
          // The span cache is filled here, not lazily: this is the one place a newly
          // discovered file is guaranteed to pass through on its way into the frontier.
          // Without it the walk finds references but never expands past depth 0.
          await _spansFor(client, loc.path);
          final enclosing = _enclosingTypeAt(loc.path, loc.line);
          if (enclosing == null) continue;
          if (depth + 1 > maxDepth) continue;
          _enqueue(enclosing, depthOf, queue, depth: depth + 1);
        }
      }

      if (truncatedReason != null) {
        _log('');
        _log('STOPPED EARLY: $truncatedReason reached. The graph is INCOMPLETE.');
      }

      stopwatch.stop();

      // Every affected file passed through _spansFor, so type names are already cached.
      final affectedTypes = <String>{};
      for (final rel in fileDepths.keys) {
        final names = _classNames[_absolute(rel)];
        if (names != null) affectedTypes.addAll(names);
      }

      final ordered = fileDepths.keys.toList()
        ..sort((a, b) {
          final byDepth = fileDepths[a]!.compareTo(fileDepths[b]!);
          return byDepth != 0 ? byDepth : a.compareTo(b);
        });

      final report = ImpactReport(
        generatedAt: DateTime.now(),
        base: base,
        root: _repoRoot,
        changedFiles: changes.map((c) => c.path).toList(),
        seeds: seeds,
        affectedFiles: ordered,
        affectedTypes: affectedTypes.toList()..sort(),
        fileDepths: Map<String, int>.from(fileDepths),
        hits: <String, List<String>>{
          for (final e in hitsByFile.entries) e.key: (e.value.toList()..sort()),
        },
        queryCount: _queryCount,
        elapsed: stopwatch.elapsed,
        truncated: truncatedReason != null,
        truncatedReason: truncatedReason,
      );

      _printSummary(report, stopwatch, truncatedReason);
      return report;
    } finally {
      await client.dispose();
    }
  }

  // --- graph helpers ---------------------------------------------------------------

  void _enqueue(
    _Node node,
    Map<String, int> depthOf,
    List<_Node> queue, {
    int? depth,
  }) {
    final d = depth ?? 0;
    final key = node.key;
    final existing = depthOf[key];
    // Only enqueue if this is a shorter path than any we have seen, so BFS settles on the
    // true minimum distance.
    if (existing != null && existing <= d) return;
    depthOf[key] = d;
    queue.add(node);
  }

  /// Innermost class-like declaration whose range contains [line] in [absPath].
  _Node? _enclosingTypeAt(String absPath, int line) {
    final spans = _spans[_norm(absPath)];
    if (spans == null || spans.isEmpty) return null;
    _ClassSpan? best;
    for (final span in spans) {
      if (line < span.from || line > span.to) continue;
      if (best == null || span.size < best.size) best = span;
    }
    return best?.node;
  }

  /// Fetches and caches the raw documentSymbol tree for a file.
  Future<List<Map<String, dynamic>>> _treeFor(
    LspClient client,
    String absPath,
  ) async {
    try {
      return await client.documentSymbols(path: absPath);
    } on LspException catch (e) {
      _log('documentSymbol failed for ${_relative(absPath)}: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  /// Fetches (once) and caches the class spans and class names for a file.
  ///
  /// This is the scan's main optimisation: the closure revisits the same file from many
  /// different edges, and without this cache the same documentSymbol is fetched dozens of
  /// times over.
  Future<List<_ClassSpan>> _spansFor(LspClient client, String absPath) async {
    final key = _norm(absPath);
    final cached = _spans[key];
    if (cached != null) return cached;
    final tree = await _treeFor(client, key);
    final spans = _classSpans(tree, key);
    final names = <String>{};
    for (final span in spans) {
      names.add(span.node.name);
    }
    _spans[key] = spans;
    _classNames[key] = names;
    return spans;
  }

  Future<void> _startAnyServer(
    LspClient client,
    String executable,
    String workingDirectory,
  ) async {
    Object? lastError;
    for (final args in _serverCandidates) {
      try {
        await client.start(
          executable: executable,
          arguments: args,
          workingDirectory: workingDirectory,
        );
        return;
      } on LspException catch (e) {
        lastError = e;
        _log('Server candidate ${args.first} failed: $e');
        await client.dispose();
      }
    }
    throw StateError(
      'Could not start a Dart analysis server.\n'
      'Tried: ${_serverCandidates.map((a) => a.join(' ')).join(', ')}\n'
      'Last error: $lastError',
    );
  }

  void _verbose(String message) {
    if (verbose) _log(message);
  }

  // --- paths -----------------------------------------------------------------------

  /// Canonical form of a path: forward slashes, no trailing separator.
  ///
  /// The LSP server hands back paths built from `file:` URIs (forward slashes) while
  /// `File(...).absolute.path` produces backslashes on Windows. Using both as map keys
  /// means the span cache never hits, the walk cannot expand, and `affectedTypes` comes
  /// back empty. Everything is normalised through here.
  static String _norm(String path) {
    var p = path.replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _absolute(String relative) => _norm(
    File('$_repoRoot${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}').absolute.path,
  );

  String _relative(String absolute) {
    final p = _norm(absolute);
    return p.startsWith('$_repoPrefix/')
        ? p.substring(_repoPrefix.length + 1)
        : p;
  }

  /// True when [absolutePath] is inside the repo we are scanning.
  ///
  /// Load-bearing, not a nicety. The analysis server indexes everything the package graph
  /// reaches, so a reference to `toList` returns hits inside the pub cache, including the
  /// `analyzer` package's own source. Without this filter a single change reports 1400+
  /// "affected files", none of them the developer's code.
  bool _insideRepo(String absolutePath) =>
      _norm(absolutePath).startsWith('$_repoPrefix/');

  static bool _isDartFile(String path) => path.endsWith('.dart');
}

/// Codegen output. Never a scan target, and never a source of affected class names.
bool _isGenerated(String path) {
  final name = path.split('/').last;
  return name.endsWith('.g.dart') ||
      name.endsWith('.freezed.dart') ||
      name.endsWith('.mocks.dart') ||
      name.endsWith('.config.dart') ||
      name.endsWith('.gr.dart') ||
      path.startsWith('.dart_tool/');
}

/// A node in the walk: a declaration we are about to ask about.
class _Node {
  const _Node(this.path, this.line, this.character, this.name);

  /// **Absolute** path. Node keys are built from this, so seeds and discovered nodes must
  /// agree on the form or the same declaration gets expanded twice.
  final String path;

  /// 0-based, as LSP uses.
  final int line;
  final int character;
  final String name;

  String get key => '$path#$name@$line';
}

/// A class-like declaration and the line span it covers, so we can find which one encloses
/// a given reference without re-walking the tree.
class _ClassSpan {
  const _ClassSpan(this.from, this.to, this.node);

  final int from;
  final int to;
  final _Node node;

  int get size => to - from;
}

/// Builds class spans from a documentSymbol tree. Once per file, cached for the scan.
List<_ClassSpan> _classSpans(List<Map<String, dynamic>> nodes, String absPath) {
  final out = <_ClassSpan>[];
  void walk(List<Map<String, dynamic>> list) {
    for (final node in list) {
      final name = node['name'];
      final kind = node['kind'];
      final range = node['range'];
      if (name is! String || kind is! int || range is! Map) continue;
      if (!_typeKinds.contains(kind)) continue;
      final start = range['start'];
      final end = range['end'];
      if (start is! Map || end is! Map) continue;
      final from = start['line'];
      final to = end['line'];
      if (from is! int || to is! int) continue;
      final sel = node['selectionRange'];
      final anchor = (sel is Map && sel['start'] is Map) ? sel : range;
      final a = anchor['start'];
      if (a is! Map) continue;
      final line = a['line'];
      final character = a['character'];
      if (line is! int || character is! int) continue;
      out.add(_ClassSpan(from, to, _Node(absPath, line, character, name)));
      final children = node['children'];
      if (children is List) walk(children.cast<Map<String, dynamic>>());
    }
  }

  walk(nodes);
  return out;
}

/// LSP SymbolKinds that are a type rather than a member of one.
const Set<int> _typeKinds = <int>{5, 9, 10, 11, 23};

/// LSP SymbolKind values that name a real thing someone can reference.
const Set<int> _declarationKinds = <int>{
  2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 22,
};

/// Members the framework calls, so nothing in user code references them directly.
const Set<String> _frameworkCalled = <String>{
  'build', 'initState', 'dispose', 'didChangeDependencies', 'didUpdateWidget',
  'deactivate', 'activate', 'reassemble', 'createState', 'toString', 'noSuchMethod',
};

/// A declaration, located at its name.
class _Decl {
  const _Decl(this.name, this.line, this.character);
  final String name;
  final int line;
  final int character;
}

/// Declarations whose source range covers any of [changedLines].
///
/// Keeps the *outermost* matching declaration, because asking about a class and about each
/// of its members gives the same references plus noise. A changed framework-called member
/// resolves to its enclosing type instead.
List<_Decl> _declarationsCovering(
  List<Map<String, dynamic>> nodes,
  List<int> changedLines,
) {
  final wanted = changedLines.toSet();
  final out = <_Decl>[];
  final seen = <String>{};

  void add(_Decl decl) {
    if (seen.add('${decl.name}@${decl.line}')) out.add(decl);
  }

  bool walk(List<Map<String, dynamic>> list, _Decl? enclosingType) {
    var matched = false;
    for (final node in list) {
      final name = node['name'];
      final kind = node['kind'];
      final range = node['range'];
      if (name is! String || kind is! int || range is! Map) continue;
      final start = range['start'];
      final end = range['end'];
      if (start is! Map || end is! Map) continue;
      final from = start['line'];
      final to = end['line'];
      if (from is! int || to is! int) continue;

      var covers = false;
      for (var l = from; l <= to; l++) {
        if (wanted.contains(l + 1)) {
          covers = true;
          break;
        }
      }
      if (!covers) continue;
      matched = true;

      final sel = node['selectionRange'];
      final anchor = (sel is Map && sel['start'] is Map) ? sel : range;
      final a = anchor['start'];
      if (a is! Map) continue;
      final line = a['line'];
      final character = a['character'];
      if (line is! int || character is! int) continue;
      final decl = _Decl(name, line, character);

      final isType = _typeKinds.contains(kind);
      final childType = isType ? decl : enclosingType;
      final children = node['children'];
      if (children is List) {
        walk(children.cast<Map<String, dynamic>>(), childType);
      }

      if (isType) {
        add(decl);
      } else if (_frameworkCalled.contains(name)) {
        // The framework calls it everywhere; the enclosing widget is what matters.
        if (enclosingType != null) add(enclosingType);
      } else if (_declarationKinds.contains(kind)) {
        add(decl);
      }
    }
    return matched;
  }

  walk(nodes, null);
  return out;
}

/// Declarations of a newly added file, used to seed it.
///
/// A new file has no history, so every line is new and the only sensible question is "who
/// uses the things this file declares?". Nested classes are included; the walk decides
/// what matters by distance, not by nesting.
List<_Decl> _topLevelDeclarations(List<_ClassSpan> spans) => <_Decl>[
  for (final span in spans) _Decl(span.node.name, span.node.line, span.node.character),
];

/// Prints the depth-sorted summary, and says plainly when the walk was cut short.
void _printSummary(
  ImpactReport report,
  Stopwatch stopwatch,
  String? truncatedReason,
) {
  final byDepth = <int, int>{};
  for (final d in report.fileDepths.values) {
    byDepth[d] = (byDepth[d] ?? 0) + 1;
  }
  final depthSummary =
      (byDepth.keys.toList()..sort()).map((d) => 'd$d:${byDepth[d]}').join('  ');

  stdout.writeln('');
  stdout.writeln(
    '=== ${report.affectedFiles.length} affected file(s)   '
    '[$depthSummary] ===',
  );
  for (final rel in report.affectedFiles.take(35)) {
    final depth = report.fileDepths[rel];
    final via = (report.hits[rel] ?? const <String>[]).take(3).join(', ');
    final more = (report.hits[rel] ?? const <String>[]).length > 3 ? ', +…' : '';
    stdout.writeln('  d$depth  $rel   <- $via$more');
  }
  if (report.affectedFiles.length > 35) {
    stdout.writeln('  ... and ${report.affectedFiles.length - 35} more');
  }
  stdout.writeln('');
  if (truncatedReason != null) {
    stdout.writeln('TRUNCATED: $truncatedReason — this list is INCOMPLETE.');
  }
  stdout.writeln(
    '${report.queryCount} queries, ${report.affectedTypes.length} type name(s), '
    '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
  );
}
