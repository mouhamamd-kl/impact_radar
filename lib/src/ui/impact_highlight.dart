/// The outline layer: a scrim over the app with holes punched where affected widgets are.
///
/// Extracted from `impact_gate.dart` because it is the part with the fiddly bits — global
/// coordinate maths, viewport clipping, and the "colour is never the only cue" rule — and
/// none of that belongs in the same file as the banner's layout.
library;

import 'package:flutter/widgets.dart';

/// One outlined widget.
class ImpactHighlight {
  const ImpactHighlight({required this.rect, required this.depth, required this.isNearest});

  /// In global (screen) coordinates, already clipped to the viewport.
  final Rect rect;

  /// Hops from the change. Lower is closer to what was actually edited.
  final int depth;

  /// True when this is one of the closest hits on screen, so it reads loudest.
  final bool isNearest;

  @override
  bool operator ==(Object other) =>
      other is ImpactHighlight &&
      other.rect == rect &&
      other.depth == depth &&
      other.isNearest == isNearest;

  @override
  int get hashCode => Object.hash(rect, depth, isNearest);
}

/// Finds the on-screen rects of every mounted instance of an affected widget.
class ImpactHighlighter {
  ImpactHighlighter({required this.affectedTypes, required this.typeDepths});

  /// Class names to outline.
  final Set<String> affectedTypes;

  /// Class name -> depth, so the nearest hit can be emphasised.
  final Map<String, int> typeDepths;

  static const int _maxDepth = 60;

  /// Elements currently mounted whose type is in [affectedTypes].
  ///
  /// Cached and reused across frames: finding them means walking the element tree, which is
  /// far more expensive than turning them into rects. This is why the gate walks the tree on
  /// a timer and only recomputes rects per frame.
  List<Element> findAffectedElements(Element root) {
    final out = <Element>[];
    if (affectedTypes.isEmpty) return out;

    void walk(Element element, int depth) {
      if (depth > _maxDepth) return;
      if (affectedTypes.contains(typeNameOf(element.widget.runtimeType))) {
        out.add(element);
      }
      element.visitChildElements((child) => walk(child, depth + 1));
    }

    walk(root, 0);
    return out;
  }

  /// Turns cached elements into clipped, viewport-relative rects.
  ///
  /// Three hazards, all of which produce *partial* correctness rather than a crash:
  ///  * an off-screen widget still has global coordinates, so every rect is clipped
  ///  * `findRenderObject` returns null for a widget that renders nothing
  ///  * a defunct element holds a stale render object
  List<ImpactHighlight> highlightsFor(
    List<Element> elements,
    Size viewport,
  ) {
    if (elements.isEmpty || viewport.isEmpty) return const <ImpactHighlight>[];

    var nearest = 1 << 30;
    for (final element in elements) {
      final depth = depthOf(element);
      if (depth < nearest) nearest = depth;
    }

    final bounds = Offset.zero & viewport;
    final out = <ImpactHighlight>[];
    for (final element in elements) {
      final rect = _rectOf(element);
      if (rect == null) continue;
      // Off-screen widgets still report a rect; without this they draw over unrelated UI.
      final clipped = rect.intersect(bounds);
      if (clipped.isEmpty || clipped.width <= 0 || clipped.height <= 0) continue;
      final depth = depthOf(element);
      out.add(
        ImpactHighlight(
          rect: clipped,
          depth: depth,
          isNearest: depth == nearest,
        ),
      );
    }
    return out;
  }

  int depthOf(Element element) =>
      typeDepths[typeNameOf(element.widget.runtimeType)] ?? _maxDepth;

  static Rect? _rectOf(Element element) {
    try {
      final object = element.findRenderObject();
      if (object is! RenderBox) return null;
      if (!object.hasSize || !object.attached) return null;
      return object.localToGlobal(Offset.zero) & object.size;
    } catch (_) {
      // A defunct element can throw here. Skipping one box is better than losing the frame.
      return null;
    }
  }

  /// `HomeScreen<Profile>` -> `HomeScreen`
  ///
  /// [Type.toString] on a generic instantiation includes the type arguments, which would
  /// never match a plain name from the report.
  static String typeNameOf(Type type) {
    final raw = type.toString();
    final i = raw.indexOf('<');
    return i < 0 ? raw : raw.substring(0, i);
  }
}

/// `HomeScreen<Profile>` -> `HomeScreen`.
///
/// [Type.toString] on a generic instantiation includes the type arguments, which would never
/// match a plain name from the report.
String typeNameOf(Type type) {
  final raw = type.toString();
  final i = raw.indexOf('<');
  return i < 0 ? raw : raw.substring(0, i);
}

/// Paints the scrim and the outlines.
///
/// Nearest hits get a solid 2px border *and* a corner dot; transitive hits get a 1px border
/// at reduced opacity and no dot. Colour is never the only cue — an outline alone is
/// invisible to colourblind users, and to anyone who simply does not notice the box.
class ImpactHighlightPainter extends CustomPainter {
  ImpactHighlightPainter({
    required this.highlights,
    required this.scrimColor,
    required this.nearColor,
    required this.farColor,
    required this.markerColor,
  });

  final List<ImpactHighlight> highlights;
  final Color scrimColor;
  final Color nearColor;
  final Color farColor;
  final Color markerColor;

  static const Radius _corner = Radius.circular(6);
  static const double _markerRadius = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (highlights.isEmpty) return;

    _paintScrim(canvas, size);

    for (final highlight in highlights) {
      final rrect = RRect.fromRectAndRadius(highlight.rect, _corner);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = highlight.isNearest ? 2.0 : 1.0
        ..color = highlight.isNearest ? nearColor : farColor;
      canvas.drawRRect(rrect, paint);

      if (highlight.isNearest) {
        // A shape difference, so the cue survives greyscale and colour blindness.
        canvas.drawCircle(
          highlight.rect.topLeft + const Offset(1, 1),
          _markerRadius,
          Paint()..color = markerColor,
        );
      }
    }
  }

  void _paintScrim(Canvas canvas, Size size) {
    if (scrimColor.a == 0) return;
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, Paint()..color = scrimColor);

    // dstOut removes the destination where the source is drawn, which is how a hole is
    // punched through the dim.
    final holes = Path()..fillType = PathFillType.evenOdd;
    holes.addRect(Offset.zero & size);
    for (final highlight in highlights) {
      holes.addRRect(RRect.fromRectAndRadius(highlight.rect, _corner));
    }
    canvas.drawPath(holes, Paint()..blendMode = BlendMode.dstOut);
    canvas.restore();
  }

  @override
  bool shouldRepaint(ImpactHighlightPainter oldDelegate) =>
      oldDelegate.highlights != highlights ||
      oldDelegate.scrimColor != scrimColor ||
      oldDelegate.nearColor != nearColor ||
      oldDelegate.farColor != farColor ||
      oldDelegate.markerColor != markerColor;
}
