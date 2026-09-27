/// The scan result, and the on-disk shape the app reads at runtime.
library;

import 'dart:convert';
import 'dart:io';

/// One symbol the scan expanded, and what referenced it.
class ImpactSeed {
  const ImpactSeed({
    required this.file,
    required this.line,
    required this.symbol,
    required this.referenceCount,
    this.depth = 0,
  });

  final String file;
  final int line;

  /// The declaration we asked about, e.g. `getProfile`.
  final String symbol;
  final int referenceCount;

  /// Hops from the original change. 0 means it was directly edited.
  final int depth;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'file': file,
    'line': line,
    'symbol': symbol,
    'referenceCount': referenceCount,
    'depth': depth,
  };
}

class ImpactReport {
  const ImpactReport({
    required this.generatedAt,
    required this.base,
    required this.root,
    required this.changedFiles,
    required this.seeds,
    required this.affectedFiles,
    required this.affectedTypes,
    required this.typeDepths,
    required this.widgetTypes,
    required this.fileDepths,
    required this.hits,
    required this.queryCount,
    required this.elapsed,
    this.truncated = false,
    this.truncatedReason,
  });

  final DateTime generatedAt;

  /// The git ref that was diffed against.
  final String base;
  final String root;

  /// Repo-relative, git-style paths.
  final List<String> changedFiles;
  final List<ImpactSeed> seeds;

  /// Everything transitively reachable from a changed declaration, closest first.
  final List<String> affectedFiles;

  /// Class names declared in the affected files. The honest superset: it includes cubits,
  /// use cases and models, which is informative but cannot be matched against mounted
  /// widgets reliably. Use [widgetTypes] for that.
  final List<String> affectedTypes;

  /// Class name -> fewest hops from the change.
  ///
  /// `affectedTypes` is a `List<String>` and cannot express "which of these is nearest",
  /// which is what the outline needs in order to read loudest at the closest hit.
  final Map<String, int> typeDepths;

  /// The subset of [affectedTypes] that are actually widgets — classes with a `build`
  /// method. This is what the runtime matches against the mounted element tree.
  final List<String> widgetTypes;

  /// Repo-relative path -> fewest hops from the change. Recorded for ranking; this step
  /// deliberately applies no filtering based on it.
  final Map<String, int> fileDepths;

  /// Repo-relative path -> the symbols whose references reached it.
  final Map<String, List<String>> hits;

  final int queryCount;
  final Duration elapsed;

  /// True when a cap stopped the walk. A partial answer is fine, a *silent* one is not.
  final bool truncated;
  final String? truncatedReason;

  bool get isEmpty => affectedFiles.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 2,
    'generatedAt': generatedAt.toIso8601String(),
    'base': base,
    'root': root,
    'changedFiles': changedFiles,
    'seeds': seeds.map((s) => s.toJson()).toList(),
    'affectedFiles': affectedFiles,
    'affectedTypes': affectedTypes,
    'typeDepths': typeDepths,
    'widgetTypes': widgetTypes,
    'fileDepths': fileDepths,
    'hits': hits,
    'truncated': truncated,
    'truncatedReason': truncatedReason,
    'stats': <String, dynamic>{
      'queryCount': queryCount,
      'elapsedMs': elapsed.inMilliseconds,
    },
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  static ImpactReport fromJson(Map<String, dynamic> json) {
    final stats = (json['stats'] as Map?)?.cast<String, dynamic>();
    final rawDepths = (json['fileDepths'] as Map?)?.cast<String, dynamic>();
    final rawHits = (json['hits'] as Map?)?.cast<String, dynamic>();
    return ImpactReport(
      generatedAt:
          DateTime.tryParse(json['generatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      base: json['base'] as String? ?? 'HEAD',
      root: json['root'] as String? ?? '',
      changedFiles: _stringList(json['changedFiles']),
      seeds: <ImpactSeed>[
        for (final s in (json['seeds'] as List? ?? const <dynamic>[]))
          if (s is Map)
            ImpactSeed(
              file: s['file'] as String? ?? '',
              line: s['line'] as int? ?? 0,
              symbol: s['symbol'] as String? ?? '',
              referenceCount: s['referenceCount'] as int? ?? 0,
              depth: s['depth'] as int? ?? 0,
            ),
      ],
      affectedFiles: _stringList(json['affectedFiles']),
      affectedTypes: _stringList(json['affectedTypes']),
      typeDepths: _intMap(json['typeDepths']),
      // Absent in older reports: fall back to affectedTypes rather than showing nothing.
      widgetTypes: json.containsKey('widgetTypes')
          ? _stringList(json['widgetTypes'])
          : _stringList(json['affectedTypes']),
      fileDepths: <String, int>{
        for (final e in (rawDepths?.entries ?? const <MapEntry<String, dynamic>>[]))
          if (e.value is int) e.key: e.value as int,
      },
      hits: <String, List<String>>{
        for (final e in (rawHits?.entries ?? const <MapEntry<String, dynamic>>[]))
          e.key: _stringList(e.value),
      },
      queryCount: stats?['queryCount'] as int? ?? 0,
      elapsed: Duration(milliseconds: stats?['elapsedMs'] as int? ?? 0),
      truncated: json['truncated'] as bool? ?? false,
      truncatedReason: json['truncatedReason'] as String?,
    );
  }

  static List<String> _stringList(dynamic v) =>
      (v as List? ?? const <dynamic>[]).whereType<String>().toList();

  static Map<String, int> _intMap(dynamic v) {
    if (v is! Map) return const <String, int>{};
    return <String, int>{
      for (final e in v.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    };
  }
}

/// Reads a report written by the scanner. Used by the runtime side.
ImpactReport? readReportFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    return ImpactReport.fromJson(decoded.cast<String, dynamic>());
  } catch (_) {
    // A half-written file (scanner mid-write) should not crash the app.
    return null;
  }
}
