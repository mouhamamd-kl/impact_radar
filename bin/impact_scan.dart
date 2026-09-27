/// Scans a project for code affected by uncommitted changes and writes `impact.json`.
///
/// Usage:
///   dart run impact_radar:impact_scan [options] [path/to/file.dart ...]
///
/// With no file arguments it diffs against the base ref (default HEAD) and scans every
/// changed Dart file. With file arguments it scans those files in full.
library;

import 'dart:io';

import 'package:impact_radar/src/model/impact_report.dart';
import 'package:impact_radar/src/scan/impact_scanner.dart';

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    _printUsage();
    return;
  }

  final options = _Options.parse(args);
  if (options.projectRoot == null) {
    stderr.writeln('Could not find a Dart project root from ${Directory.current.path}');
    stderr.writeln('Pass one explicitly with --project <path>.');
    exitCode = 2;
    return;
  }

  final root = options.projectRoot!;
  stdout.writeln('impact_scan');
  stdout.writeln('  project: $root');

  final scanner = ImpactScanner(
    root: root,
    dartPath: options.dartPath,
    log: (m) => stdout.writeln('  $m'),
  )..verbose = options.verbose;

  final stopwatch = Stopwatch()..start();
  late final ImpactReport report;

  if (options.files.isNotEmpty) {
    stdout.writeln('  mode: explicit files (${options.files.length})');
    // Explicit files are not wired up yet in v1; fall back to the diff and say so.
    stdout.writeln(
      '  note: explicit file mode is not implemented yet, scanning the diff instead.',
    );
  }

  try {
    report = await scanner.scan(
      base: options.base,
      staged: options.staged,
      maxDepth: options.maxDepth,
      maxFiles: options.maxFiles,
      maxQueries: options.maxQueries,
    );
  } catch (e) {
    stderr.writeln('');
    stderr.writeln('Scan failed: $e');
    exitCode = 1;
    return;
  }

  final outPath = options.outPath ?? '$root${Platform.pathSeparator}impact.json';
  File(outPath).writeAsStringSync('${report.toJsonString()}\n');
  stopwatch.stop();

  stdout.writeln('');
  stdout.writeln('Wrote $outPath');
  if (report.truncated) {
    stdout.writeln(
      '  WARNING: truncated (${report.truncatedReason}). The list is INCOMPLETE.',
    );
  }
  final nearest = report.fileDepths.values.isEmpty
      ? 0
      : (report.fileDepths.values.reduce((a, b) => a < b ? a : b));
  stdout.writeln(
    '  ${report.affectedFiles.length} affected file(s), '
    '${report.affectedTypes.length} type name(s), '
    'nearest at depth $nearest, '
    '${report.queryCount} queries, '
    '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s total',
  );
  if (report.isEmpty) {
    stdout.writeln('  Nothing referenced the changed symbols.');
  }
  stdout.writeln('');
  stdout.writeln('Point the app at it with:');
  stdout.writeln('  ImpactGate(reportPath: \'$outPath\', child: ...)');
}

class _Options {
  _Options({
    required this.projectRoot,
    required this.base,
    required this.staged,
    required this.outPath,
    required this.dartPath,
    required this.maxDepth,
    required this.maxFiles,
    required this.maxQueries,
    required this.verbose,
    required this.files,
  });

  final String? projectRoot;
  final String base;
  final bool staged;
  final String? outPath;
  final String? dartPath;
  final int maxDepth;
  final int maxFiles;
  final int maxQueries;
  final bool verbose;
  final List<String> files;

  static _Options parse(List<String> args) {
    String? root;
    String? out;
    String? dart;
    var base = 'HEAD';
    var staged = false;
    var maxDepth = 8;
    var maxFiles = 2000;
    var maxQueries = 5000;
    var verbose = false;
    final files = <String>[];

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String next() {
        if (i + 1 >= args.length) {
          stderr.writeln('Missing value for $arg');
          exit(2);
        }
        return args[++i];
      }

      switch (arg) {
        case '--project':
          root = next();
        case '--out':
          out = next();
        case '--dart':
          dart = next();
        case '--base':
          base = next();
        case '--staged':
          staged = true;
        case '--max-depth':
          maxDepth = int.tryParse(next()) ?? maxDepth;
        case '--max-files':
          maxFiles = int.tryParse(next()) ?? maxFiles;
        case '--max-queries':
          maxQueries = int.tryParse(next()) ?? maxQueries;
        case '-v':
        case '--verbose':
          verbose = true;
        default:
          if (arg.startsWith('-')) {
            stderr.writeln('Unknown option: $arg');
            exit(2);
          }
          files.add(arg);
      }
    }

    return _Options(
      projectRoot: root ?? _findProjectRoot(),
      base: base,
      staged: staged,
      outPath: out,
      dartPath: dart,
      maxDepth: maxDepth,
      maxFiles: maxFiles,
      maxQueries: maxQueries,
      verbose: verbose,
      files: files,
    );
  }
}

/// Walks up from the current directory looking for `.dart_tool/package_config.json`.
String? _findProjectRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (File('${dir.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}package_config.json').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

void _printUsage() {
  stdout.writeln('''
impact_scan - find the code affected by your recent changes

Usage:
  dart run impact_radar:impact_scan [options]

Options:
  --project <path>   Project root. Defaults to walking up from the current directory
                     looking for .dart_tool/package_config.json
  --base <ref>       Git ref to diff against (default: HEAD)
  --staged           Diff the index instead of the working tree
  --out <path>       Where to write the report (default: <project>/impact.json)
  --dart <path>      Which dart runs the analysis server.
                     Defaults to the dart running this script. Point this at the
                     project's own SDK if it differs.

Walk limits (safety valves, not the design; hitting one sets truncated:true):
  --max-depth <n>    How many hops from the change to follow (default: 8)
  --max-files <n>    Stop after this many affected files (default: 2000)
  --max-queries <n>  Stop after this many server queries (default: 5000)

  -v, --verbose      Log raw server traffic

Example, using a pinned SDK:
  dart run impact_radar:impact_scan --dart C:\\path\\to\\flutter_sdk\\bin\\dart.exe
''');
}
