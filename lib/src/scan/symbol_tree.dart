/// Interpreting the analysis server's `documentSymbol` output.
///
/// This is pure: it turns the raw JSON maps the server returns into declarations anchored at
/// their own names. Nothing here talks to the server, so all of it is unit-testable with
/// hand-written symbol trees — see `test/symbol_tree_test.dart`.
///
/// The one idea worth knowing before reading on:
///
/// **Seeds are methods. Expansions are classes.**
///
/// A changed method is the precise thing to start a scan from, but the thing to *expand* is
/// the class around it. A reference landing inside `SomeWidget.build` means the widget uses
/// the changed thing, and `SomeWidget` is what someone else can reference. `build` itself
/// is called by the framework everywhere, so asking about it returns noise.
library;

/// A declaration, anchored at its own name, ready to be asked about via `textDocument/references`.
class DeclarationRef {
  const DeclarationRef({
    required this.path,
    required this.name,
    required this.line,
    required this.character,
  });

  /// Absolute path, forward slashes. Keys are built from this, so every `DeclarationRef` in
  /// a scan must agree on the form or the same declaration gets expanded twice.
  final String path;

  final String name;

  /// 0-based, as LSP uses.
  final int line;
  final int character;

  String get key => '$path#$name@$line';

  @override
  String toString() => '$name@$path:${line + 1}';
}

/// A class-like declaration together with the line range it covers, so we can answer
/// "which type encloses this line?" without re-walking the tree.
class TypeSpan {
  const TypeSpan({required this.from, required this.to, required this.ref});

  /// Inclusive, 0-based.
  final int from;
  final int to;
  final DeclarationRef ref;

  int get size => to - from;

  bool contains(int line) => line >= from && line <= to;
}

/// Members the framework calls, so nothing in user code references them directly.
///
/// Asking "who references `build`?" returns the whole framework. If a widget's `build`
/// changed, the thing worth flagging is the *widget*, so these names resolve to their
/// enclosing type instead.
const Set<String> frameworkCalledMembers = <String>{
  'build', 'initState', 'dispose', 'didChangeDependencies', 'didUpdateWidget',
  'deactivate', 'activate', 'reassemble', 'createState', 'toString', 'noSuchMethod',
};

/// The LSP `SymbolKind` values we care about. Named rather than bare integers so the sets
/// below read as what they mean.
abstract final class SymbolKind {
  /// A class. Also used by Dart for enums, class type aliases and mixins.
  static const int cls = 5;
  static const int method = 6;
  static const int property = 7;
  static const int field = 8;
  static const int constructor = 9;
  static const int enumType = 10;
  static const int interface = 11;
  static const int function = 12;
  static const int variable = 13;
  static const int constant = 14;
  static const int enumMember = 22;

  /// Dart records, and anything else that behaves like a class.
  static const int struct = 23;
}

/// Kinds that name a type, rather than a member of one.
const Set<int> _typeKinds = <int>{
  SymbolKind.cls,
  SymbolKind.enumType,
  SymbolKind.interface,
  SymbolKind.struct,
};

/// Kinds that name something another file can reference.
///
/// `Namespace` (3) and `Package` (4) are deliberately absent: they are file-level
/// containers, never useful as a query anchor.
const Set<int> _referenceableKinds = <int>{
  SymbolKind.cls,
  SymbolKind.method,
  SymbolKind.property,
  SymbolKind.field,
  SymbolKind.constructor,
  SymbolKind.enumType,
  SymbolKind.interface,
  SymbolKind.function,
  SymbolKind.variable,
  SymbolKind.constant,
  SymbolKind.enumMember,
  SymbolKind.struct,
};

/// The declarations one file contains, indexed so a scan can ask questions of them.
class SymbolTree {
  SymbolTree({required this.path, required List<Map<String, dynamic>> nodes})
    : _nodes = nodes;

  /// Absolute, forward-slash path of the file these symbols came from.
  final String path;

  final List<Map<String, dynamic>> _nodes;

  late final List<TypeSpan> _typeSpans = _parseTypeSpans(_nodes);

  /// Class-like declarations, outermost first, for enclosing lookups and for seeding new
  /// files.
  List<TypeSpan> get typeSpans => _typeSpans;

  /// Names of every class-like declaration in the file. Feeds the report's type list, which
  /// is what the runtime matches against mounted widgets.
  late final Set<String> typeNames = <String>{
    for (final span in _typeSpans) span.ref.name,
  };

  /// The subset of [typeNames] that are actually widgets.
  ///
  /// Identified by a child symbol named `build`, which every `StatelessWidget` subclass and
  /// every `StatefulWidget`'s `State` class has. That is a good enough signal for a dev tool
  /// and costs nothing: the tree is already parsed and already searched for `build` to seed
  /// changes, this just records which classes had one.
  ///
  /// Narrowing to widgets matters for correctness, not tidiness. The report's
  /// [typeNames] is a flat union of every class in every affected file, so a `Ticket` *model*
  /// in that list would match a `Ticket` *widget* on screen.
  late final Set<String> widgetTypeNames = _findWidgetTypes();

  Set<String> _findWidgetTypes() {
    final out = <String>{};
    void walk(List<Map<String, dynamic>> list) {
      for (final node in list) {
        final children = node['children'];
        if (children is! List) continue;
        final kids = children.cast<Map<String, dynamic>>();
        if (_typeKinds.contains(_int(node['kind']))) {
          final name = node['name'];
          if (name is String && kids.any((c) => c['name'] == 'build')) {
            out.add(name);
          }
        }
        walk(kids);
      }
    }

    walk(_nodes);
    return out;
  }

  /// The innermost class-like declaration whose range contains [line], or null if the line is
  /// outside every class in the file.
  ///
  /// [line] is 0-based. Used to decide what to expand next when a reference lands somewhere:
  /// see the "seeds are methods, expansions are classes" note at the top of this file.
  DeclarationRef? enclosingTypeAt(int line) {
    TypeSpan? best;
    for (final span in _typeSpans) {
      if (!span.contains(line)) continue;
      if (best == null || span.size < best.size) best = span;
    }
    return best?.ref;
  }

  /// Every class-like declaration in the file, as seeds.
  ///
  /// Used for newly added files, where every line is new and the only sensible question is
  /// "who uses the things this file declares?".
  List<DeclarationRef> declaredTypes() => <DeclarationRef>[
    for (final span in _typeSpans) span.ref,
  ];

  /// The declarations to start a scan from, given the lines that changed.
  ///
  /// [changedLines] is 0-based. Returns the *outermost* matching declarations, because
  /// asking about a class and about each of its members yields the same references plus
  /// noise — one collapsed class query is cheaper and clearer than five member queries.
  ///
  /// A changed framework-called member (`build`, `initState`, …) resolves to its enclosing
  /// type instead, since the framework is what calls it.
  List<DeclarationRef> declarationsCovering(Iterable<int> changedLines) {
    final wanted = changedLines.toSet();
    if (wanted.isEmpty) return const <DeclarationRef>[];

    final out = <DeclarationRef>[];
    final seen = <String>{};

    void add(DeclarationRef ref) {
      if (seen.add(ref.key)) out.add(ref);
    }

    void walk(List<Map<String, dynamic>> nodes, DeclarationRef? enclosingType) {
      for (final node in nodes) {
        final kind = _int(node['kind']);
        final range = _rangeOf(node);
        if (range == null) continue;

        final from = range.$1;
        final to = range.$2;
        if (!_coversAny(from, to, wanted)) continue;

        final ref = _refOf(node);
        if (ref == null) continue;

        final isType = _typeKinds.contains(kind);
        final children = node['children'];
        if (children is List) {
          walk(
            children.cast<Map<String, dynamic>>(),
            isType ? ref : enclosingType,
          );
        }

        if (isType) {
          add(ref);
        } else if (frameworkCalledMembers.contains(ref.name)) {
          // The framework calls it everywhere; the enclosing widget is what matters.
          if (enclosingType != null) add(enclosingType);
        } else if (_referenceableKinds.contains(kind)) {
          add(ref);
        }
      }
    }

    walk(_nodes, null);
    return out;
  }

  /// True if any 0-based line in [from]..[to] is in [wanted].
  static bool _coversAny(int from, int to, Set<int> wanted) {
    for (var line = from; line <= to; line++) {
      if (wanted.contains(line)) return true;
    }
    return false;
  }

  List<TypeSpan> _parseTypeSpans(List<Map<String, dynamic>> nodes) {
    final out = <TypeSpan>[];
    void walk(List<Map<String, dynamic>> list) {
      for (final node in list) {
        final kind = _int(node['kind']);
        if (_typeKinds.contains(kind)) {
          final range = _rangeOf(node);
          final ref = _refOf(node);
          if (range != null && ref != null) {
            out.add(TypeSpan(from: range.$1, to: range.$2, ref: ref));
          }
        }
        final children = node['children'];
        if (children is List) walk(children.cast<Map<String, dynamic>>());
      }
    }

    walk(nodes);
    return out;
  }

  /// The line range a symbol covers, as `(from, to)`, both inclusive and 0-based.
  ///
  /// Returns null for any node the server sent in a shape we do not recognise, rather than
  /// throwing: one malformed symbol should not lose the whole file.
  static (int, int)? _rangeOf(Map<String, dynamic> node) {
    final range = node['range'];
    if (range is! Map) return null;
    final start = range['start'];
    final end = range['end'];
    if (start is! Map || end is! Map) return null;
    final from = _int(start['line']);
    final to = _int(end['line']);
    if (from == null || to == null) return null;
    return (from, to);
  }

  /// A declaration anchored at its *name*, not at its body, so `references` resolves the
  /// symbol itself rather than whatever token happens to be at `range.start`.
  DeclarationRef? _refOf(Map<String, dynamic> node) {
    final name = node['name'];
    if (name is! String) return null;
    final range = node['range'];
    final selection = node['selectionRange'];
    final anchor = (selection is Map && selection['start'] is Map)
        ? selection
        : range;
    if (anchor is! Map) return null;
    final start = anchor['start'];
    if (start is! Map) return null;
    final line = _int(start['line']);
    final character = _int(start['character']);
    if (line == null || character == null) return null;
    return DeclarationRef(
      path: path,
      name: name,
      line: line,
      character: character,
    );
  }

  static int? _int(Object? value) => value is int ? value : null;
}
