/// The in-app side: shows what a recent code change touched, on the widgets themselves.
///
/// Router-agnostic on purpose. It never inspects routes or navigators; it walks the mounted
/// element tree and asks whether an affected widget class is on screen. That is what lets it
/// work with Navigator, go_router, GetX, or a hand-rolled router it has never heard of.
///
/// Install it once, in the app's root `builder`:
///
/// ```dart
/// builder: (context, child) => ImpactGate(
///   child: DevicePreview.appBuilder(context, child) ?? const SizedBox.shrink(),
/// )
/// ```
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../model/impact_report.dart';
import 'impact_highlight.dart';
import 'impact_source.dart';

export 'impact_highlight.dart' show ImpactHighlight;

/// Keys exposed for tests and for anyone driving the gate from a harness.
const Key impactHighlightsKey = ValueKey<String>('impact_radar.highlights');
const Key impactCardKey = ValueKey<String>('impact_radar.card');
const Key impactScreenToggleKey = ValueKey<String>('impact_radar.mode.screen');
const Key impactWidgetToggleKey = ValueKey<String>('impact_radar.mode.widget');
const Key impactDismissKey = ValueKey<String>('impact_radar.dismiss');
const Key impactCollapseKey = ValueKey<String>('impact_radar.collapse');
const Key impactExpandKey = ValueKey<String>('impact_radar.expand');

/// How much to show.
enum ImpactMode {
  /// A card only: "something on this screen changed."
  screen,

  /// A card *plus* an outline on every mounted instance of every affected widget.
  ///
  /// Every instance, not a sample. If `CustomButton` changed, all twenty buttons on screen
  /// genuinely are affected, and hiding some would be a lie by omission. The dimmed
  /// background is what makes twenty boxes readable.
  widget,
}

class ImpactGate extends StatefulWidget {
  const ImpactGate({
    super.key,
    required this.child,
    this.source,
    this.reportPath = 'impact.json',
    this.pollInterval = const Duration(milliseconds: 700),
    this.enabled = true,
    this.mode = ImpactMode.widget,
    this.cardPosition = ImpactCardPosition.topStart,
    this.dimScreen = true,
  });

  final Widget child;

  /// Where the report comes from.
  ///
  /// Defaults to [impactSourceFromEnv], which reads `IMPACT_URL` and falls back to
  /// [reportPath] on this machine. Pass a source explicitly to override.
  final ImpactSource? source;

  /// Where the scanner wrote its report, when running on the same machine.
  ///
  /// Ignored if [source] is given. Useful for tests, which have no tunnel to talk to.
  final String reportPath;

  final Duration pollInterval;

  /// Set false to turn the whole thing off without removing it.
  final bool enabled;

  final ImpactMode mode;

  final ImpactCardPosition cardPosition;

  /// Dim the screen behind the outlines in [ImpactMode.widget].
  final bool dimScreen;

  @override
  State<ImpactGate> createState() => _ImpactGateState();
}

/// Where the card sits. Every app collides with something different — a bottom nav, a FAB,
/// an app bar — so this is configurable rather than assumed.
enum ImpactCardPosition { topStart, topEnd, bottomStart, bottomEnd }

/// TickerProviderStateMixin, not SingleTickerProviderStateMixin: the highlight ticker is
/// created and destroyed as the mode toggles, and the single-ticker mixin refuses to be used
/// more than once.
class _ImpactGateState extends State<ImpactGate> with TickerProviderStateMixin {
  ImpactReport? _report;
  List<Element> _affected = const <Element>[];
  List<ImpactHighlight> _highlights = const <ImpactHighlight>[];
  ImpactMode _mode = ImpactMode.widget;
  bool _collapsed = false;
  String? _dismissedChange;

  Timer? _pollTimer;
  Ticker? _frameTicker;
  final GlobalKey _stackKey = GlobalKey();

  ImpactSource get _source =>
      widget.source ?? FileSource(widget.reportPath);

  @override
  void initState() {
    super.initState();
    _mode = widget.mode;
    if (!widget.enabled) return;
    // Fire and forget: the first paint has nothing to show yet, and _poll picks up the
    // result a moment later. Awaiting here would delay the first frame for no gain.
    unawaited(_poll());
    _pollTimer = Timer.periodic(widget.pollInterval, (_) => unawaited(_poll()));
  }

  @override
  void didUpdateWidget(ImpactGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) _mode = widget.mode;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _frameTicker?.dispose();
    super.dispose();
  }

  // --- polling: cheap, but only every interval ----------------------------------------

  Future<void> _poll() async {
    if (!mounted) return;
    final report = await _source.read();
    if (!mounted) return;

    // A failed read returns null. Keeping the previous report is deliberate: the app should
    // hold the last known state rather than blanking when the tunnel hiccups.
    if (report == null) return;

    final changed = report.generatedAt != _report?.generatedAt;

    final elements = _findAffectedElements();

    final typesChanged = elements.length != _affected.length;
    final stillMounted = !typesChanged && _sameElements(elements);

    if (changed || typesChanged || !stillMounted) {
      setState(() {
        _report = report;
        _affected = elements;
        if (changed) _dismissedChange = null; // a new scan re-arms the card
      });
      _syncFrameTicker();
    }
  }

  List<Element> _findAffectedElements() {
    final report = _report;
    if (report == null) return const <Element>[];
    final root = _appElement();
    if (root == null) return const <Element>[];
    return _highlighter(report).findAffectedElements(root);
  }

  /// The app's own element, not ours.
  ///
  /// The Stack's first child is `child`; everything after it is the overlay. Walking from
  /// the Stack instead would let the overlay highlight itself.
  Element? _appElement() {
    final stack = _stackKey.currentContext;
    if (stack is! Element) return null;
    Element? first;
    // visitChildren takes a void callback and visits everything, so use it and bail out by
    // leaving `first` set. visitChildElements is the short-circuiting variant but wants a
    // bool return; either is fine, this one keeps the "take the first" intent obvious.
    stack.visitChildren((child) {
      first ??= child;
    });
    return first;
  }

  ImpactHighlighter _highlighter(ImpactReport report) => ImpactHighlighter(
    affectedTypes: report.widgetTypes.toSet(),
    typeDepths: report.typeDepths,
  );

  bool _sameElements(List<Element> a) {
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], _affected[i])) return false;
    }
    return true;
  }

  // --- per frame: expensive, but only while something is outlined --------------------

  void _syncFrameTicker() {
    final needsFrames = _mode == ImpactMode.widget && _affected.isNotEmpty;
    if (needsFrames && _frameTicker == null) {
      _frameTicker = createTicker((_) => _recomputeRects())..start();
    } else if (!needsFrames && _frameTicker != null) {
      _frameTicker!.dispose();
      _frameTicker = null;
      _highlights = const <ImpactHighlight>[];
    }
  }

  void _recomputeRects() {
    if (!mounted) return;
    final report = _report;
    if (report == null) return;
    // maybeSizeOf, not sizeOf: the gate can be used outside a MediaQuery, and a banner that
    // throws on mount is worse than one that cannot clip.
    final size = MediaQuery.maybeSizeOf(context);
    if (size == null) return;
    final next = _highlighter(report).highlightsFor(_affected, size);
    // `child` is the identical widget instance, so setState here does not rebuild the app.
    setState(() => _highlights = next);
  }

  // --- what to show ------------------------------------------------------------------

  /// The affected types currently on screen, and the depth of each.
  Map<String, int> get _liveTypes {
    final report = _report;
    if (report == null) return const <String, int>{};
    final out = <String, int>{};
    for (final element in _affected) {
      final base = typeNameOf(element.widget.runtimeType);
      out[base] = report.typeDepths[base] ?? 0;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final report = _report;
    final live = _liveTypes;
    final stale = report != null &&
        DateTime.now().difference(report.generatedAt) >
            const Duration(hours: 2);
    final dismissed = report == null ||
        _dismissedChange == report.generatedAt.toIso8601String();
    final visible = report != null && live.isNotEmpty && !dismissed;

    return Stack(
      key: _stackKey,
      children: <Widget>[
        widget.child,
        if (_mode == ImpactMode.widget)
          Positioned.fill(
            // IgnorePointer so the outlined widgets stay usable while you inspect them.
            child: IgnorePointer(
              child: CustomPaint(
                key: impactHighlightsKey,
                painter: ImpactHighlightPainter(
                  highlights: _highlights,
                  scrimColor: widget.dimScreen
                      ? const Color(0x8A000000)
                      : const Color(0x00000000),
                  nearColor: const Color(0xFFE5484D),
                  farColor: const Color(0x99E5484D),
                  markerColor: const Color(0xFFFFFFFF),
                ),
              ),
            ),
          ),
        if (visible)
          // Positioned.fill + Align, with pointer events enabled. IgnorePointer here would
          // make every control on the card dead, which is exactly what it did until the
          // widget tests caught it. Only the highlight *layer* ignores pointers.
          Positioned.fill(
            child: Align(
              alignment: _alignmentFor(widget.cardPosition),
              child: _card(report, live, stale),
            ),
          ),
      ],
    );
  }

  /// Keys exposed for tests and for anyone driving this from a test harness.

  static Alignment _alignmentFor(ImpactCardPosition position) =>
      switch (position) {
        ImpactCardPosition.topStart => Alignment.topLeft,
        ImpactCardPosition.topEnd => Alignment.topRight,
        ImpactCardPosition.bottomStart => Alignment.bottomLeft,
        ImpactCardPosition.bottomEnd => Alignment.bottomRight,
      };

  Widget _card(ImpactReport report, Map<String, int> live, bool stale) {
    final names = live.keys.toList()..sort();
    final shown = names.take(3).join(', ');
    final more = names.length > 3 ? '  +${names.length - 3} more' : '';
    final direct = live.values.where((d) => d == 0).length;
    final dependent = live.length - direct;

    if (_collapsed) {
      return _CardShell(
        key: impactCardKey,
        accent: stale ? _staleAccent : _warningAccent,
        collapsed: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: stale ? _staleAccent : _warningAccent,
            ),
            const SizedBox(width: 6),
            Text(
              '${names.length}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
            const SizedBox(width: 2),
            _MiniButton(
              key: impactExpandKey,
              icon: Icons.open_in_full,
              onPressed: () => setState(() => _collapsed = false),
            ),
          ],
        ),
      );
    }

    return _CardShell(
      key: impactCardKey,
      accent: stale ? _staleAccent : _warningAccent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: stale ? _staleAccent : _warningAccent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  stale
                      ? 'Unverified change (report is old)'
                      : 'Unverified change',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
              _MiniButton(
                key: impactCollapseKey,
                icon: Icons.close,
                onPressed: () => setState(() => _collapsed = true),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$shown$more',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
          Text(
            <String>[
              if (direct > 0) '$direct direct',
              if (dependent > 0) '$dependent dependent',
              '${report.affectedFiles.length} file(s)',
              if (report.truncated) 'INCOMPLETE',
            ].join('  '),
            style: TextStyle(
              fontSize: 10.5,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _ModeToggle(
                mode: _mode,
                onChanged: (next) {
                  setState(() => _mode = next);
                  _syncFrameTicker();
                  if (next == ImpactMode.widget) _recomputeRects();
                },
              ),
              const SizedBox(width: 10),
              // Quiet inline action, not a filled button: a dev tool should not shout.
              TextButton(
                key: impactDismissKey,
                onPressed: () => setState(
                  () => _dismissedChange = report.generatedAt.toIso8601String(),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: Colors.black87,
                  textStyle: const TextStyle(fontSize: 11.5),
                ),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static const Color _warningAccent = Color(0xFFB26A00);
  static const Color _staleAccent = Color(0xFF6D4C41);
}

/// Tinted surface with dark text, a left accent bar, and a soft edge.
///
/// A saturated red slab reads as an emergency and is fatiguing when you are looking at it for
/// an hour; a tint reads as a state. Saturated red is kept for the outline, which is small.
class _CardShell extends StatelessWidget {
  const _CardShell({
    super.key,
    required this.child,
    required this.accent,
    this.collapsed = false,
  });

  final Widget child;
  final Color accent;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    // SizedBox with a bounded width rather than IntrinsicHeight: an unbounded
    // IntrinsicHeight inside the Stack's Align asks its child for an infinite size, and the
    // Scaffold under it then blows up. The card is chrome, so clamp it and let the text wrap
    // or ellipsize inside.
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: const Color(0xFFFFF6E5),
              // A uniform border, because BoxBorder refuses a borderRadius on non-uniform
              // sides and we want the accent bar to be its own colour.
              border: Border.all(color: const Color(0x1F000000)),
              // A tight box shadow rather than Material's elevation. Material's shadow uses a
              // non-uniform blur mask, and the scrim's even-odd saveLayer asserts that a
              // saveLayer's paint must be uniform. The two are mutually exclusive; the scrim
              // matters more, so the card gives up elevation.
              boxShadow: collapsed
                  ? const []
                  : const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x1A000000),
                        blurRadius: 6,
                        spreadRadius: 0,
                        offset: Offset(0, 2),
                      ),
                    ],
            ),
            // IntrinsicHeight is safe now that ConstrainedBox bounds the width; it makes the
            // accent bar span the card's full height without hardcoding one.
            child: IntrinsicHeight(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(width: 3, color: accent),
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(9, 8, 8, 8),
                      // The card is app chrome, not app content.
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: child,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 28px icon button with no tooltip.
///
/// Tooltips build an `Overlay` entry, which is a `Material` with an elevation shadow. That is
/// the same non-uniform shadow problem as above, and it fires whenever the card is rebuilt.
class _MiniButton extends StatelessWidget {
  const _MiniButton({super.key, required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onPressed,
    behavior: HitTestBehavior.opaque,
    child: SizedBox(
      width: 28,
      height: 28,
      child: Icon(icon, size: 14, color: Colors.black87),
    ),
  );
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});
  final ImpactMode mode;
  final ValueChanged<ImpactMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget button(ImpactMode value, String label, Key key) {
      final selected = mode == value;
      return GestureDetector(
        key: key,
        onTap: () => onChanged(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? accentFor(value) : const Color(0x00000000),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? accentFor(value) : const Color(0x33000000),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected ? Colors.white : Colors.black87,
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0x14000000),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          button(ImpactMode.screen, 'Screen', impactScreenToggleKey),
          button(ImpactMode.widget, 'Widget', impactWidgetToggleKey),
        ],
      ),
    );
  }

  static Color accentFor(ImpactMode mode) =>
      mode == ImpactMode.widget ? const Color(0xFFB26A00) : const Color(0xFF5B6B7A);
}
