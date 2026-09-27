# `lib/src/scan` — how a scan works

Start here. The pipeline is four steps, and each one lives in a file named after the question
it answers.

```
git diff ──► changed_files.dart ──► seeds.dart ──► graph_walk.dart ──► report
                    "what changed?"   "start where?"   "what depends on it?"
```

`impact_scanner.dart` is only orchestration — read it top to bottom and you have the whole
picture in a minute.

| File | Question it answers | Talks to a subprocess? |
|---|---|---|
| `changed_files.dart` | Which files and lines did the diff touch? | no (runs `git`) |
| `seeds.dart` | Which declarations in those lines do we start from? | no |
| `symbol_tree.dart` | What does this file declare, and what encloses this line? | no |
| `repo_paths.dart` | What is the canonical form of this path? | no |
| `graph_walk.dart` | What transitively depends on the seeds? | no |
| `lsp_client.dart` | How do we talk to the analysis server? | **yes** |
| `report_format.dart` | What does the terminal show? | no |

Everything except `lsp_client.dart` is pure and unit-testable with no server running. If you
are changing anything but the transport, you do not need a 15-second scan to test it.

## The one idea worth knowing

**Seeds are methods. Expansions are classes.**

This is the thing that makes the output clean, and it is easy to get backwards. The scan
borrows the reference index the Dart analysis server already maintains — the same one your
IDE uses for "find references" — and walks it.

Two different questions come up, and they need different granularity:

- *Which thing changed?* A **method**. `getAllTickets` is precise; the class around it is not.
- *What now depends on it?* A **class**. When a reference lands inside `SomeWidget.build`, the
  widget is what matters, because `SomeWidget` is what other code instantiates. Asking about
  `build` returns the entire framework, since the framework calls it everywhere.

So a change inside a widget's `build` seeds the *widget*, while a change to a method outside
any class seeds the *method*. Getting this wrong is what turned 1481 pub-cache files into 48
real ones.

## The two bugs that shaped this code

Both produced **partial** correctness rather than a crash, which is the dangerous kind.

1. **Path shape.** The server returns forward slashes (from `file:` URIs);
   `File.absolute.path` returns backslashes on Windows. Use both as map keys and the symbol
   cache never hits — the walk finds references but cannot expand, and the report's type list
   comes back empty with no error anywhere. `repo_paths.dart` exists to make that impossible.
2. **Skipping a "pointless" read.** Leaving the symbol lookup lazy looked harmless. It meant
   the walk never expanded past depth 0. The cache is now filled at the one point a discovered
   file is guaranteed to pass through on its way into the frontier.

## Where the time goes

A scan issues two kinds of request, and they are counted separately on purpose:

- **reference queries** — one per expanded declaration. This is the walk.
- **symbol lookups** — one per file, cached. Without the cache the closure would re-fetch the
  same `documentSymbol` dozens of times.

An earlier version counted only the first, which made a scan look far cheaper than it was.

## Deliberately not done

- **No ranking or filtering.** Everything reached is reported, nearest first. Depth is
  recorded so a later step can decide what to cut, with data in hand.
- **No test/DI filtering.** They are real edges in the graph. Whether to exclude them is a
  ranking decision, made later.
- **No graph cache.** The analysis server already keeps one; ours would only add
  invalidation bugs.

## Testing

```bash
flutter test                                   # everything, no server needed
powershell -File ../testbed/reset_fixture.ps1  # then edit the fixture, then scan it
```

`testbed/ticket_app` is the end-to-end proof: a repository → use case → cubit → screen chain,
where editing only the repository must still find the screen three hops away.
