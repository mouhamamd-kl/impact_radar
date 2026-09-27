/// Terminal output for a scan.
///
/// Separate from the engine so that printing is not tangled up with computing, and so the
/// engine can be driven by something other than a terminal.
library;

import 'dart:io';

import '../model/impact_report.dart';

const int _maxRows = 35;

/// Prints the depth-sorted result, and says plainly when the walk was cut short.
void printSummary(
  ImpactReport report,
  Stopwatch stopwatch, {
  required int symbolRequests,
  void Function(String line)? out,
}) {
  final write = out ?? stdout.writeln;

  write('');
  write('=== ${report.affectedFiles.length} affected file(s)   '
      '[${_depthHistogram(report)}] ===');
  for (final rel in report.affectedFiles.take(_maxRows)) {
    final via = (report.hits[rel] ?? const <String>[]);
    final shown = via.take(3).join(', ');
    final more = via.length > 3 ? ', +…' : '';
    write('  d${report.fileDepths[rel]}  $rel   <- $shown$more');
  }
  if (report.affectedFiles.length > _maxRows) {
    write('  ... and ${report.affectedFiles.length - _maxRows} more');
  }

  write('');
  if (report.truncated) {
    write('TRUNCATED: ${report.truncatedReason} — this list is INCOMPLETE.');
  }
  write(
    '${report.queryCount} reference queries '
    '($symbolRequests symbol lookups), '
    '${report.affectedTypes.length} type name(s), '
    '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
  );
}

String _depthHistogram(ImpactReport report) {
  final counts = <int, int>{};
  for (final depth in report.fileDepths.values) {
    counts[depth] = (counts[depth] ?? 0) + 1;
  }
  final depths = counts.keys.toList()..sort();
  return depths.map((d) => 'd$d:${counts[d]}').join('  ');
}
