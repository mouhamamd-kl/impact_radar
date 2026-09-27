/// The transitive walk: from a set of seed declarations, follow every reference to the end.
///
/// Owns the frontier, the depth bookkeeping, the caps, and the per-file symbol cache. It does
/// not decide *what* to start from (see `symbol_tree.dart`) and it does not talk to the
/// process (see `lsp_client.dart`).
library;

import '../model/impact_report.dart';
import 'lsp_client.dart';
import 'repo_paths.dart';
import 'symbol_tree.dart';

/// Fetches and caches the [SymbolTree] of each file, once per file per walk.
///
/// This cache is the walk's main optimisation. The closure reaches the same file from many
/// different edges, and without it the same `documentSymbol` request is sent dozens of times.
class SymbolIndex {
  SymbolIndex(this._client, this._paths, {this.onError});

  final LspClient _client;
  final RepoPaths _paths;

  /// Called with a repo-relative path when a file's symbols cannot be read.
  final void Function(String message)? onError;

  final Map<String, SymbolTree> _trees = <String, SymbolTree>{};

  int _requests = 0;

  /// How many `documentSymbol` requests were actually sent. The closure issues far fewer
  /// lookups than this, and both numbers matter when tuning.
  int get requestCount => _requests;

  /// The tree for [absolutePath], fetched on first use and cached after.
  Future<SymbolTree> treeAt(String absolutePath) async {
    final key = normalisePath(absolutePath);
    final cached = _trees[key];
    if (cached != null) return cached;

    _requests++;
    List<Map<String, dynamic>> nodes;
    try {
      nodes = await _client.documentSymbols(path: key);
    } on LspException catch (e) {
      // One unreadable file must not abort the scan; it just contributes no seeds and no
      // further expansion.
      onError?.call('documentSymbol failed for ${_paths.relative(key)}: $e');
      nodes = const <Map<String, dynamic>>[];
    }

    final tree = SymbolTree(path: key, nodes: nodes);
    _trees[key] = tree;
    return tree;
  }

  /// Every class name declared in the affected files, for the report.
  Set<String> typeNamesFor(Iterable<String> repoRelativePaths) {
    final out = <String>{};
    for (final rel in repoRelativePaths) {
      out.addAll(_trees[_paths.absolute(rel)]?.typeNames ?? const <String>{});
    }
    return out;
  }

  /// Widget-only class names declared in the affected files.
  Set<String> widgetTypesFor(Iterable<String> repoRelativePaths) {
    final out = <String>{};
    for (final rel in repoRelativePaths) {
      out.addAll(
        _trees[_paths.absolute(rel)]?.widgetTypeNames ?? const <String>{},
      );
    }
    return out;
  }

  /// Class name -> fewest hops at which it was reached.
  ///
  /// Derived from the file's depth: a class declared in a depth-2 file is a depth-2 hit.
  /// Good enough for ranking, and it avoids tracking depth per declaration instead of per
  /// file, which is what the walk actually measures.
  Map<String, int> typeDepthsFor(Map<String, int> fileDepths) {
    final out = <String, int>{};
    fileDepths.forEach((rel, depth) {
      final tree = _trees[_paths.absolute(rel)];
      if (tree == null) return;
      for (final name in tree.typeNames) {
        final existing = out[name];
        if (existing == null || depth < existing) out[name] = depth;
      }
    });
    return out;
  }
}

/// What the walk produced.
class WalkResult {
  const WalkResult({
    required this.fileDepths,
    required this.hitsByFile,
    required this.expanded,
    required this.queries,
    required this.truncatedReason,
  });

  /// Repo-relative path -> fewest hops from the change. 0 means directly edited.
  final Map<String, int> fileDepths;

  /// Repo-relative path -> the symbols whose references reached it.
  final Map<String, Set<String>> hitsByFile;

  /// One entry per declaration that produced at least one in-repo reference.
  final List<ImpactSeed> expanded;

  /// `textDocument/references` requests sent. Excludes `documentSymbol`, which
  /// [SymbolIndex.requestCount] tracks separately — an earlier version conflated the two and
  /// made the cost of a scan look far smaller than it was.
  final int queries;

  /// Non-null when a cap stopped the walk early. Reported, never silently swallowed.
  final String? truncatedReason;

  bool get truncated => truncatedReason != null;
}

/// Follows references breadth-first from [seeds].
///
/// Breadth-first so [WalkResult.fileDepths] records each file's *true* minimum distance,
/// which is what makes "nearest first" ordering meaningful.
///
/// Safety caps ([maxDepth], [maxFiles], [maxQueries]) exist to bound a pathological change,
/// not to shape normal output. Hitting one sets [WalkResult.truncatedReason].
Future<WalkResult> walkReferences({
  required LspClient client,
  required RepoPaths paths,
  required SymbolIndex index,
  required List<DeclarationRef> seeds,
  required int maxDepth,
  required int maxFiles,
  required int maxQueries,
  void Function(String message)? log,
}) async {
  final queue = <_FrontierEntry>[];
  final depthOf = <String, int>{};
  final expandedKeys = <String>{};

  final fileDepths = <String, int>{};
  final hitsByFile = <String, Set<String>>{};
  final expanded = <ImpactSeed>[];
  var queries = 0;
  String? truncatedReason;

  void enqueue(DeclarationRef ref, int depth) {
    // Only re-enqueue when this is a shorter path than any seen, so BFS settles on the
    // minimum distance rather than whatever order references happened to arrive in.
    final existing = depthOf[ref.key];
    if (existing != null && existing <= depth) return;
    depthOf[ref.key] = depth;
    queue.add(_FrontierEntry(ref, depth));
  }

  for (final seed in seeds) {
    enqueue(seed, 0);
  }

  while (queue.isNotEmpty) {
    if (queries >= maxQueries) {
      truncatedReason = 'query budget ($maxQueries)';
      break;
    }
    if (fileDepths.length >= maxFiles) {
      truncatedReason = 'file budget ($maxFiles)';
      break;
    }

    final entry = queue.removeAt(0);
    if (!expandedKeys.add(entry.ref.key)) continue;
    final depth = entry.depth;
    if (depth > maxDepth) continue;

    queries++;
    final locations = await client.references(
      path: entry.ref.path,
      line: entry.ref.line,
      character: entry.ref.character,
    );

    final kept = <LspLocation>[];
    for (final location in locations) {
      // A reference back into the file we are standing in is not impact, and neither is
      // anything outside the repo (pub cache, SDK, another checkout).
      if (normalisePath(location.path) == entry.ref.path) continue;
      if (!paths.contains(location.path)) continue;
      kept.add(location);
    }
    if (kept.isEmpty) continue;

    expanded.add(
      ImpactSeed(
        file: paths.relative(entry.ref.path),
        line: entry.ref.line + 1,
        symbol: entry.ref.name,
        referenceCount: kept.length,
        depth: depth,
      ),
    );

    for (final location in kept) {
      final rel = paths.relative(location.path);
      final previous = fileDepths[rel];
      if (previous == null || depth < previous) fileDepths[rel] = depth;
      (hitsByFile[rel] ??= <String>{}).add(entry.ref.name);

      // Expand the *type* enclosing this reference, not the member. See the note at the top
      // of symbol_tree.dart: `build` is called by the framework everywhere, the widget is
      // what user code actually references.
      //
      // Reading the tree here rather than lazily is deliberate. This is the one place a
      // newly discovered file is guaranteed to pass on its way into the frontier; if the
      // cache were filled any later the walk would find references but never expand.
      final tree = await index.treeAt(location.path);
      final enclosing = tree.enclosingTypeAt(location.line);
      if (enclosing == null) continue;
      if (depth + 1 > maxDepth) continue;
      enqueue(enclosing, depth + 1);
    }
  }

  if (truncatedReason != null) {
    log?.call('STOPPED EARLY: $truncatedReason reached. The graph is INCOMPLETE.');
  }

  return WalkResult(
    fileDepths: fileDepths,
    hitsByFile: hitsByFile,
    expanded: expanded,
    queries: queries,
    truncatedReason: truncatedReason,
  );
}

class _FrontierEntry {
  const _FrontierEntry(this.ref, this.depth);
  final DeclarationRef ref;
  final int depth;
}
