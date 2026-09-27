# impact_radar

**You change some code → the running app tells you which screen to go look at.**

That is the whole product. Everything else is later.

## Why it is small

Dart's analysis server **already knows** the dependency graph — that is how your IDE
answers "find references" instantly, using an index it maintains itself. So this tool does
not build a graph, does not cache one, and has no index to invalidate. It asks the server a
question and reads the answer.

## Install

```bash
flutter pub add --dev impact_radar
```

## Use it

### 1. Scan

After a change, from your app's directory:

```bash
dart run impact_radar:impact_scan
```

It diffs against `HEAD`, asks the analysis server "who references what you changed?", and
writes `impact.json` plus a summary to the terminal.

If the app's Dart SDK is not the one on your `PATH`, point at it:

```bash
dart run impact_radar:impact_scan --dart C:\path\to\flutter_sdk\bin\dart.exe
```

Useful flags: `--base <ref>`, `--staged`, `--out <path>`, `--max-queries <n>`, `-v`.

### 2. Show it

Once, in the app's root `builder`:

```dart
import 'package:impact_radar/impact_radar.dart';

MaterialApp(
  builder: (context, child) => ImpactGate(
    child: DevicePreview.appBuilder(context, child) ?? const SizedBox.shrink(),
  ),
)
```

`ImpactGate` walks the mounted widget tree every 700ms. If any widget class named in
`impact.json` is on screen, a red banner drops down and stays until you tap **Done**.

No routes, no annotations, no per-screen edits. It does not know what your navigator is.

## How it works

1. `git diff --unified=0` → which files and lines changed
2. For each changed file, `textDocument/documentSymbol` → the declarations covering those
   lines. New files seed from everything they declare.
3. For each seed, `textDocument/references` → everywhere it is used
4. For each hit, find the **class** enclosing it, and ask about *that* → the walk
   continues. This is what gets you from a repository edit to the screen that renders it.
5. Record the depth of every file reached. 0 means directly edited, 2 means two hops away.
6. The app checks whether any affected class name is currently mounted

### Seeds are methods, expansions are classes

A changed method is the precise thing to start from, but the thing to *expand* is the class
around it. A reference landing inside `SomeWidget.build` means the widget uses the changed
thing — and `SomeWidget` is what someone else can reference. `build` itself is called by the
framework everywhere, which is why asking about it is useless.

### Walk limits

`--max-depth` (8), `--max-files` (2000), `--max-queries` (5000). These are safety valves,
not the design. If one trips, the report sets `truncated: true` and names the cap. A
partial answer is fine; a *silent* one is not.

## Current limits (v1, on purpose)

- **Desktop only at runtime.** The app reads `impact.json` from disk, so this works when
  you run from a desktop target. A real device needs a different source; not built yet.
- **Dart changes only.** Editing `assets/lang/*.json` is not picked up.
- **No ranking.** Everything reached is reported, ordered by depth. Filtering is a later
  step; depth is recorded so that step has data to work with.
- **One flat list across both apps.** A `tam_worker` hit appears in a `tam_supervisor`
  report. Harmless at runtime (a worker-only widget is never mounted in supervisor) but
  noisy in the terminal.
- **No persistence.** Tapping Done lasts until the next scan.
- **Cold start is slow** — around 2 minutes on a large monorepo, nearly all of it the
  analysis server indexing. Fine for "the AI finished, what do I check", too slow for
  anything live.

## Tests

```bash
flutter test                              # diff parsing + the gate's behaviour
```

### The fixture (proves the closure works)

`testbed/ticket_app` is a pure-Dart app with a deliberate chain:

```
TicketRepository.getAllTickets()      <- the "API" the AI edits
  -> GetTickets                      (use case)
    -> TicketsCubit                  (state)
      -> TicketsScreen               (the screen we want flagged)
        -> TicketCard                (a widget composed into the screen)
```

Pure Dart on purpose: no Flutter SDK, so it resolves fast and deterministically.
`widget.dart` is a shim — the scanner reads declaration spans, not superclasses.

The fixture needs its own git repo, because the scanner diffs against real history. That
repo is not committed (git would record the directory as an embedded repo and clones would
get a broken pointer), so recreate it first:

```bash
# PowerShell
powershell -ExecutionPolicy Bypass -File testbed/reset_fixture.ps1

# then add a searchTickets method to testbed/ticket_app/lib/data/ticket_repository.dart
dart run impact_radar:impact_scan --project testbed/ticket_app
```

Expected: `tickets_screen.dart` in the report at depth 2, in about 1 second. Editing only
the repository and finding the screen three hops away is the case the whole tool exists
for, so it is the test worth keeping green.


