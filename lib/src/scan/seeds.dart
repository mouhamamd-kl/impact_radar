/// Choosing where a scan starts: the declarations the diff actually touched.
library;

import 'dart:io';

import 'changed_files.dart';
import 'graph_walk.dart';
import 'lsp_client.dart';
import 'repo_paths.dart';
import 'symbol_tree.dart';

/// The declarations a scan starts from, one entry per changed Dart file.
class SeedGroup {
  const SeedGroup({required this.file, required this.declarations});
  final String file;
  final List<DeclarationRef> declarations;
}

/// Seeds every changed Dart file, in the order the diff lists them.
///
/// Two cases, and the difference matters:
///
///  * **Modified file** — ask which declarations cover the changed lines. Precise.
///  * **New file** — every line is new, so line-level selection is meaningless; seed
///    everything the file declares instead. Nobody cares that a `Container` appeared on
///    line 40, they care who uses the widget the file defines.
Future<List<SeedGroup>> collectSeeds({
  required LspClient client,
  required SymbolIndex index,
  required RepoPaths paths,
  required List<ChangedFile> changes,
  void Function(String message)? log,
}) async {
  final groups = <SeedGroup>[];

  for (final change in changes) {
    final abs = paths.absolute(change.path);
    // A file can be deleted or renamed away between the diff and now.
    if (!File(abs).existsSync()) continue;

    final tree = await index.treeAt(abs);
    final declarations = change.isNew
        ? tree.declaredTypes()
        // Diff line numbers are 1-based; symbol trees are 0-based, as LSP. Convert once,
        // here, so nothing downstream has to remember which is which.
        : tree.declarationsCovering(change.lines.map((l) => l - 1));

    if (declarations.isEmpty) continue;
    groups.add(SeedGroup(file: change.path, declarations: declarations));
    log?.call(
      '  seed: ${change.path} -> ${declarations.length} declaration(s): '
      '${_preview(declarations)}',
    );
  }

  return groups;
}

String _preview(List<DeclarationRef> declarations) {
  const shown = 4;
  final names = declarations.take(shown).map((d) => d.name).join(', ');
  final extra = declarations.length - shown;
  return extra > 0 ? '$names, +$extra' : names;
}
