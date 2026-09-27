/// impact_radar - flags the screens affected by a code change so a human can go verify
/// them.
///
/// Two halves, deliberately separable:
///
///  * `impact_scan` (see `bin/impact_scan.dart`) - the offline scanner. Pure Dart, talks
///    LSP to Dart's analysis server, writes `impact.json`.
///  * `ImpactGate` - the runtime overlay. Flutter widget, reads `impact.json`, shows a
///    banner over a screen when an affected widget class is mounted.
library;

export 'src/model/impact_report.dart' show ImpactReport, ImpactSeed, readReportFile;
export 'src/ui/impact_gate.dart'
    show
        ImpactCardPosition,
        ImpactGate,
        ImpactMode,
        impactCardKey,
        impactCollapseKey,
        impactDismissKey,
        impactExpandKey,
        impactHighlightsKey,
        impactScreenToggleKey,
        impactWidgetToggleKey;
export 'src/ui/impact_highlight.dart'
    show ImpactHighlight, ImpactHighlighter, ImpactHighlightPainter, typeNameOf;
export 'src/ui/impact_source.dart'
    show FileSource, HttpSource, ImpactSource, impactSourceFromEnv;
