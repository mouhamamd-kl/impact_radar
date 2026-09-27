import 'package:flutter_test/flutter_test.dart';
import 'package:impact_radar/src/scan/symbol_tree.dart';

/// Builds a `documentSymbol` node the way the analysis server sends one.
Map<String, dynamic> node(
  String name,
  int kind,
  int from,
  int to, {
  int? nameLine,
  int? nameChar,
  List<Map<String, dynamic>>? children,
}) => <String, dynamic>{
  'name': name,
  'kind': kind,
  'range': <String, dynamic>{
    'start': <String, dynamic>{'line': from, 'character': 0},
    'end': <String, dynamic>{'line': to, 'character': 40},
  },
  'selectionRange': <String, dynamic>{
    'start': <String, dynamic>{
      'line': nameLine ?? from,
      'character': nameChar ?? 6,
    },
    'end': <String, dynamic>{'line': nameLine ?? from, 'character': 20},
  },
  if (children != null) 'children': children,
};

/// A tree shaped like a real widget: a class whose build method uses a dependency.
List<Map<String, dynamic>> widgetTree({
  int classFrom = 0,
  int classTo = 40,
  int buildFrom = 5,
  int buildTo = 30,
}) => <Map<String, dynamic>>[
  node('TicketScreen', SymbolKind.cls, classFrom, classTo, children: <Map<String, dynamic>>[
    node('build', SymbolKind.method, buildFrom, buildTo, nameLine: classFrom + 1),
    node('cubit', SymbolKind.field, classFrom + 2, classFrom + 2),
  ]),
  node('AppRoutes', SymbolKind.cls, 50, 70),
];

void main() {
  group('SymbolTree.enclosingTypeAt', () {
    test('finds the class containing a line', () {
      final tree = SymbolTree(path: '/p/a.dart', nodes: widgetTree());

      expect(tree.enclosingTypeAt(10)?.name, 'TicketScreen');
      expect(tree.enclosingTypeAt(60)?.name, 'AppRoutes');
    });

    test('returns null for a line outside every class', () {
      final tree = SymbolTree(path: '/p/a.dart', nodes: widgetTree());

      expect(tree.enclosingTypeAt(45), isNull);
    });

    test('prefers the innermost class when they nest', () {
      // Outer class spans 0..50, inner spans 10..20. A reference on line 15 belongs to the
      // inner one, because that is the type something else can reference.
      final tree = SymbolTree(
        path: '/p/a.dart',
        nodes: <Map<String, dynamic>>[
          node('Outer', SymbolKind.cls, 0, 50, children: <Map<String, dynamic>>[
            node('Inner', SymbolKind.cls, 10, 20),
          ]),
        ],
      );

      expect(tree.enclosingTypeAt(15)?.name, 'Inner');
      expect(tree.enclosingTypeAt(30)?.name, 'Outer');
    });
  });

  group('SymbolTree.declarationsCovering', () {
    test('returns the class when a method inside it changed', () {
      // A changed `build` resolves to its enclosing widget, not to `build`. Asking about
      // `build` returns the whole framework.
      final tree = SymbolTree(path: '/p/a.dart', nodes: widgetTree());

      final seeds = tree.declarationsCovering(<int>[10]);

      expect(seeds.map((d) => d.name), <String>['TicketScreen']);
    });

    test('a changed method yields both the method and its class', () {
      // The class is redundant here — asking "who references Thing" already covers
      // "who references doWork" — so this costs one extra query per changed method. It is
      // kept because narrowing it to the class alone would change the report, and this is a
      // refactor. Worth revisiting as a separate, measured change.
      final tree = SymbolTree(
        path: '/p/a.dart',
        nodes: <Map<String, dynamic>>[
          node('Thing', SymbolKind.cls, 0, 40, children: <Map<String, dynamic>>[
            node('doWork', SymbolKind.method, 5, 30, nameLine: 1),
          ]),
        ],
      );

      final seeds = tree.declarationsCovering(<int>[10]);

      expect(seeds.map((d) => d.name), <String>['doWork', 'Thing']);
    });

    test('collapses several changed lines in one class to a single seed', () {
      // Three changed lines inside one class is one question, not three. Asking about the
      // class and each of its members gives the same references plus noise.
      final tree = SymbolTree(path: '/p/a.dart', nodes: widgetTree());

      final seeds = tree.declarationsCovering(<int>[8, 10, 12]);

      expect(seeds, hasLength(1));
      expect(seeds.single.name, 'TicketScreen');
    });

    test('anchors on the name, not the start of the body', () {
      // If we asked at range.start for a method we would sit on `void` and resolve nothing.
      final tree = SymbolTree(
        path: '/p/a.dart',
        nodes: <Map<String, dynamic>>[
          node('doWork', SymbolKind.method, 5, 30, nameLine: 5, nameChar: 2),
        ],
      );

      final seed = tree.declarationsCovering(<int>[10]).single;

      expect(seed.line, 5);
      expect(seed.character, 2);
    });

    test('returns nothing when no line falls inside a symbol', () {
      final tree = SymbolTree(path: '/p/a.dart', nodes: widgetTree());

      expect(tree.declarationsCovering(<int>[45]), isEmpty);
    });

    test('ignores namespaces and packages, which nothing references', () {
      final tree = SymbolTree(
        path: '/p/a.dart',
        nodes: <Map<String, dynamic>>[node('my_lib', 4, 0, 100)],
      );

      expect(tree.declarationsCovering(<int>[10]), isEmpty);
    });

    test('a malformed node is skipped without losing its siblings', () {
      // One bad symbol from the server should not cost us the whole file.
      final tree = SymbolTree(
        path: '/p/a.dart',
        nodes: <Map<String, dynamic>>[
          <String, dynamic>{'name': 'Broken', 'kind': SymbolKind.cls},
          node('Good', SymbolKind.cls, 10, 20),
        ],
      );

      expect(tree.typeNames, <String>{'Good'});
    });
  });

  group('SymbolTree types', () {
    test('declaredTypes is for seeding a brand new file', () {
      final tree = SymbolTree(path: '/p/a.dart', nodes: widgetTree());

      expect(
        tree.declaredTypes().map((d) => d.name).toSet(),
        <String>{'TicketScreen', 'AppRoutes'},
      );
    });

    test('typeNames includes nested classes', () {
      final tree = SymbolTree(
        path: '/p/a.dart',
        nodes: <Map<String, dynamic>>[
          node('Outer', SymbolKind.cls, 0, 50, children: <Map<String, dynamic>>[
            node('Inner', SymbolKind.cls, 10, 20),
          ]),
        ],
      );

      expect(tree.typeNames, <String>{'Outer', 'Inner'});
    });
  });

  test('DeclarationRef.key is stable and distinguishes same-named decls', () {
    const a = DeclarationRef(path: '/p/a.dart', name: 'X', line: 3, character: 2);
    const b = DeclarationRef(path: '/p/a.dart', name: 'X', line: 9, character: 2);
    const c = DeclarationRef(path: '/p/b.dart', name: 'X', line: 3, character: 2);

    expect(a.key, isNot(b.key));
    expect(a.key, isNot(c.key));
    expect(
      a,
      const DeclarationRef(path: '/p/a.dart', name: 'X', line: 3, character: 2),
    );
  });
}
