/// Scans a project for code affected by uncommitted changes and writes `impact.json`.
///
/// Usage:
///   dart run impact_radar:impact_scan [options]
///   dart run impact_radar:impact_scan serve [options]
///
/// Without a subcommand it scans. `serve` runs a long-lived file server instead, so a device
/// can read the report over the network — see `impact_serve`'s docs.
library;

import 'dart:async';
import 'dart:io';

import 'package:impact_radar/src/model/impact_report.dart';
import 'package:impact_radar/src/scan/impact_scanner.dart';
import 'package:impact_radar/src/scan/serve.dart';

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    _printUsage();
    return;
  }

  // `serve` is a subcommand rather than a flag so its argument shape stays independent of
  // the scanner's. Everything after it belongs to serve.
  if (args.isNotEmpty && args.first == 'serve') {
    await _serve(args.sublist(1));
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

/// `serve` subcommand: run until interrupted.
Future<void> _serve(List<String> args) async {
  var project = _findProjectRoot();
  var port = 8787;

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
        project = next();
      case '--port':
        port = int.tryParse(next()) ?? port;
      default:
        stderr.writeln('Unknown option for serve: $arg');
        exit(2);
    }
  }

  if (project == null) {
    stderr.writeln('Could not find a Dart project root from ${Directory.current.path}');
    stderr.writeln('Pass one explicitly with --project <path>.');
    exitCode = 2;
    return;
  }

  stdout.writeln('impact_serve');
  final root = Directory(project).absolute.path;

  final report = File('$root${Platform.pathSeparator}impact.json');
  if (!report.existsSync()) {
    // Not fatal: a scan may be about to run. Worth saying, though, because a 404 from the
    // device is otherwise a confusing thing to debug.
    stdout.writeln('  note: no impact.json yet. Run impact_scan first.');
  }

  try {
    await serveProject(root: root, port: port, log: (m) => stdout.writeln(m));
  } on SocketException catch (e) {
    stderr.writeln('');
    stderr.writeln('Could not bind port $port: ${e.message}');
    stderr.writeln('Something else is using it, or it is outside your allowed range.');
    exitCode = 1;
    return;
  }

  stdout.writeln('Ctrl-C to stop.');
  // Park the isolate; the server runs on its own.
  await Completer<void>().future;
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
          stderr.writeln('Unknown option: $arg');
          exit(2);
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
  dart run impact_radar:impact_scan serve [--project <path>] [--port <n>]

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

serve - expose the report to a device
  Serves the project directory over HTTP. An app on a phone cannot see a file on your
  machine, so point a tunnel at this and point the app at the tunnel:

    dart run impact_radar:impact_scan serve --project path/to/app
    ngrok http 8787
    flutter run --dart-define=IMPACT_URL=https://<subdomain>.ngrok-free.app/impact.json

  Or stay private, over USB:

    dart run impact_radar:impact_scan serve --project path/to/app
    adb reverse tcp:8787 tcp:8787
    flutter run      # IMPACT_URL already defaults to http://127.0.0.1:8787/impact.json
''');
}
