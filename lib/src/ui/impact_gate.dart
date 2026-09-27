/// The in-app side: shows a banner when a screen you are looking at was affected by a
/// recent code change.
///
/// Crude on purpose. It does not know about routes, does not rank, and does not explain
/// itself well. It answers one question: "is something I need to look at on screen right
/// now?"
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../model/impact_report.dart';

/// Wraps the whole app and drops a banner over the top when an affected widget class is
/// currently mounted.
///
/// Install it once, in the app's root `builder`:
///
/// ```dart
/// builder: (context, child) => ImpactGate(
///   child: DevicePreview.appBuilder(context, child) ?? const SizedBox.shrink(),
/// )
/// ```
class ImpactGate extends StatefulWidget {
  const ImpactGate({
    super.key,
    required this.child,
    this.reportPath = 'impact.json',
    this.pollInterval = const Duration(milliseconds: 700),
    this.enabled = true,
  });

  final Widget child;

  /// Where the scanner wrote its report.
  final String reportPath;

  final Duration pollInterval;

  /// Set false to turn the whole thing off without removing it.
  final bool enabled;

  @override
  State<ImpactGate> createState() => _ImpactGateState();
}

class _ImpactGateState extends State<ImpactGate> {
  ImpactReport? _report;
  Set<String> _mountedTypes = <String>{};
  Timer? _timer;
  String? _dismissedChange;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) return;
    _report = readReportFile(widget.reportPath);
    _timer = Timer.periodic(widget.pollInterval, (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final report = readReportFile(widget.reportPath);
    final changed = report?.generatedAt != _report?.generatedAt;
    final types = <String>{};
    _collectMountedTypes(types);
    if (changed || !_sameTypes(types, _mountedTypes)) {
      setState(() {
        _report = report;
        _mountedTypes = types;
        if (changed) _dismissedChange = null; // a new scan re-arms the banner
      });
    }
  }

  /// Walks the element tree below this widget and records every mounted widget's type
  /// name. This is the router-agnostic part: it does not care what the navigator is.
  void _collectMountedTypes(Set<String> into) {
    void walk(Element element, int depth) {
      if (depth > 60) return;
      into.add(_baseTypeName(element.widget.runtimeType.toString()));
      element.visitChildElements((child) => walk(child, depth + 1));
    }

    // State.context is BuildContext, but at runtime it is this State's own Element.
    walk(context as Element, 0);
  }

  static bool _sameTypes(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// `HomeScreen<Profile>` -> `HomeScreen`
  static String _baseTypeName(String raw) {
    final i = raw.indexOf('<');
    return i < 0 ? raw : raw.substring(0, i);
  }

  /// Which affected class names are on screen right now.
  List<String> get _liveTypes {
    final report = _report;
    if (report == null) return const <String>[];
    final live = <String>[];
    for (final type in report.affectedTypes) {
      if (_mountedTypes.contains(type)) live.add(type);
    }
    return live;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final report = _report;
    final live = _liveTypes;
    final stale = report != null &&
        DateTime.now().difference(report.generatedAt) >
            const Duration(hours: 2);
    final show = live.isNotEmpty &&
        _dismissedChange != report?.generatedAt.toIso8601String();

    final body = Stack(
      children: <Widget>[
        widget.child,
        if (show)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _ImpactBanner(
              liveTypes: live,
              report: report!,
              stale: stale,
              onDismiss: () {
                setState(() {
                  _dismissedChange = report.generatedAt.toIso8601String();
                });
              },
            ),
          ),
      ],
    );

    // The banner is app chrome, not app content: give it its own Directionality so it
    // renders even if the wrapped subtree has none.
    return Directionality(textDirection: TextDirection.ltr, child: body);
  }
}

class _ImpactBanner extends StatelessWidget {
  const _ImpactBanner({
    required this.liveTypes,
    required this.report,
    required this.stale,
    required this.onDismiss,
  });

  final List<String> liveTypes;
  final ImpactReport report;
  final bool stale;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = liveTypes.take(3).join(', ');
    final moreTypes = liveTypes.length > 3 ? ' +${liveTypes.length - 3}' : '';
    final nearest = report.fileDepths.isEmpty
        ? null
        : report.fileDepths.values.reduce((a, b) => a < b ? a : b);
    final topSeed = report.seeds.isEmpty
        ? null
        : report.seeds.reduce((a, b) => a.depth <= b.depth ? a : b);

    return Material(
      color: stale ? const Color(0xFF6D4C41) : const Color(0xFFB3261E),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      stale
                          ? 'Unverified change (report is old)'
                          : 'Unverified change on this screen',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$shown$moreTypes',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      <String>[
                        if (topSeed != null) 'via ${topSeed.symbol}',
                        if (nearest != null) 'depth $nearest',
                        '${report.affectedFiles.length} file(s) affected',
                        if (report.truncated) 'INCOMPLETE',
                      ].join('  '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onDismiss,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
