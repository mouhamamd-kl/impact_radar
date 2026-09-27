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
export 'src/ui/impact_gate.dart' show ImpactGate;
