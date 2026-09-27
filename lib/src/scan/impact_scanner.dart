/// A scan: diff the working tree, then follow every reference to the bottom.
///
/// This file only orchestrates. Each step lives in a file named after the question it
/// answers, so you can read the pipeline top to bottom and then go read any one step:
///
///   changed_files.dart  which files and lines did the diff touch?
///   seeds.dart          which declarations in those lines do we start from?
///   graph_walk.dart     follow every reference, breadth-first
///   symbol_tree.dart    interpret documentSymbol output      <- the hard idea is here
///   repo_paths.dart     path shapes, which fail silently
///   lsp_client.dart     how we talk to the analysis server
///   report_format.dart  what the terminal shows
///
/// The analysis server already maintains a reference index — that is how an IDE answers
/// "find references" instantly — so there is no graph to build and no cache to invalidate.
/// We borrow that index and walk it.
///
/// Filtering and ranking are deliberately *not* applied. The point is to make the whole graph
/// visible; deciding what to cut is a later concern, made with data in hand.
library;

import 'dart:io';

import '../model/impact_report.dart';
import 'changed_files.dart';
import 'graph_walk.dart';
import 'lsp_client.dart';
import 'repo_paths.dart';
import 'report_format.dart';
import 'seeds.dart';
import 'symbol_tree.dart';

typedef LogFn = void Function(String message);

class ImpactScanner {
  ImpactScanner({
    required this.root,
    this.gitRoot,
    this.dartPath,
    LogFn? log,
  }) : _log = log ?? ((_) {});

  /// Project root: the directory holding `.dart_tool/package_config.json`. This is what the
  /// analysis server is rooted at, and it decides which package graph is visible.
  final String root;

  /// Repository root. Diff paths are relative to this, not to [root], and the two differ in a
  /// monorepo. Detected from [root] when not supplied.
  final String? gitRoot;

  /// Which `dart` runs the analysis server. Defaults to the dart running this script, which
  /// is right when the scanner is launched with the project's own SDK.
  final String? dartPath;

  final LogFn _log;

  /// Log the raw LSP conversation. Noisy, but the only way to diagnose a server that answers
  /// with nothing.
  bool verbose = false;

  /// Server commands to try in order. Newer SDKs ship `language-server`; `analysis-server` is
  /// the older name and still speaks LSP.
  static const List<List<String>> _serverCommands = <List<String>>[
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

    // The project root becomes a `file:` URI for the analysis server, and a relative path
    // produces a malformed one — the server then reports "File is not being analyzed" for
    // everything. Canonicalise before it is used for anything.
    final projectRoot = normalisePath(Directory(root).absolute.path);
    final repoRoot = normalisePath(
      Directory(gitRoot ?? await findGitRoot(projectRoot) ?? projectRoot)
          .absolute
          .path,
    );
    final paths = RepoPaths(repoRoot);
    if (repoRoot != projectRoot) {
      _log('Project: $projectRoot');
      _log('Repo:    $repoRoot');
    }

    final changes = (await readChangedFiles(
      root: repoRoot,
      base: base,
      staged: staged,
    )).where((c) => isScannableFile(c.path)).toList();

    _logChangedFiles(changes);

    final executable = dartPath ?? Platform.resolvedExecutable;
    _log('Analysis server dart: $executable');

    final client = LspClient(log: verbose ? _log : null);
    await _startServer(client, executable, projectRoot);

    try {
      await client.initialize(rootPath: projectRoot);
      final index = SymbolIndex(
        client,
        paths,
        onError: verbose ? _log : null,
      );

      final groups = await collectSeeds(
        client: client,
        index: index,
        paths: paths,
        changes: changes,
        log: _log,
      );

      final result = await walkReferences(
        client: client,
        paths: paths,
        index: index,
        seeds: <DeclarationRef>[
          for (final group in groups) ...group.declarations,
        ],
        maxDepth: maxDepth,
        maxFiles: maxFiles,
        maxQueries: maxQueries,
        log: _log,
      );

      stopwatch.stop();

      final report = _buildReport(
        base: base,
        repoRoot: repoRoot,
        changes: changes,
        result: result,
        affectedTypes: index.typeNamesFor(result.fileDepths.keys),
        stopwatch: stopwatch,
      );

      printSummary(report, stopwatch, symbolRequests: index.requestCount);
      return report;
    } finally {
      await client.dispose();
    }
  }

  void _logChangedFiles(List<ChangedFile> changes) {
    if (changes.isEmpty) {
      _log('No changed Dart files. Nothing to do.');
      return;
    }
    _log('Changed Dart files: ${changes.length}');
    for (final change in changes.take(15)) {
      _log('  [${change.isNew ? 'new' : '${change.lines.length} line(s)'}]'
          ' ${change.path}');
    }
    if (changes.length > 15) _log('  ... and ${changes.length - 15} more');
  }

  ImpactReport _buildReport({
    required String base,
    required String repoRoot,
    required List<ChangedFile> changes,
    required WalkResult result,
    required Set<String> affectedTypes,
    required Stopwatch stopwatch,
  }) {
    // Nearest first, so the top of the report is what to check.
    final ordered = result.fileDepths.keys.toList()
      ..sort((a, b) {
        final byDepth = result.fileDepths[a]!.compareTo(result.fileDepths[b]!);
        return byDepth != 0 ? byDepth : a.compareTo(b);
      });

    return ImpactReport(
      generatedAt: DateTime.now(),
      base: base,
      root: repoRoot,
      changedFiles: changes.map((c) => c.path).toList(),
      seeds: result.expanded,
      affectedFiles: ordered,
      affectedTypes: affectedTypes.toList()..sort(),
      fileDepths: Map<String, int>.from(result.fileDepths),
      hits: <String, List<String>>{
        for (final e in result.hitsByFile.entries)
          e.key: (e.value.toList()..sort()),
      },
      queryCount: result.queries,
      elapsed: stopwatch.elapsed,
      truncated: result.truncated,
      truncatedReason: result.truncatedReason,
    );
  }

  Future<void> _startServer(
    LspClient client,
    String executable,
    String workingDirectory,
  ) async {
    Object? lastError;
    for (final arguments in _serverCommands) {
      try {
        await client.start(
          executable: executable,
          arguments: arguments,
          workingDirectory: workingDirectory,
        );
        return;
      } on LspException catch (e) {
        lastError = e;
        _log('Server command ${arguments.first} failed: $e');
        await client.dispose();
      }
    }
    throw StateError(
      'Could not start a Dart analysis server.\n'
      'Tried: ${_serverCommands.map((c) => c.join(' ')).join(', ')}\n'
      'Last error: $lastError',
    );
  }
}
