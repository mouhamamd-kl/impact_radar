# Fixture — do not edit by hand

A tiny Dart app used to test the scanner's transitive closure. The point is the chain:

```
TicketRepository.getAllTickets()      <- the "API" the AI edits
  -> GetTickets                      (use case)
    -> TicketsCubit                  (state)
      -> TicketsScreen               (the screen we want flagged)
        -> TicketCard                (a widget composed into the screen)
```

`AppRoutes` in `home_screen.dart` genuinely references `TicketsCubit` and `TicketsScreen`, so
that file **is** a real hit — an earlier note here claimed it should not be, which was
wrong. A genuinely unrelated screen would be one that references none of the chain.

## Verified result

Editing only `lib/data/ticket_repository.dart`:

```
=== 4 affected file(s)   [d0:1  d1:1  d2:2] ===
  d0  lib/domain/get_tickets.dart        <- TicketRepository
  d1  lib/bloc/tickets_cubit.dart        <- GetTickets
  d2  lib/ui/home_screen.dart            <- TicketsCubit, TicketsScreen
  d2  lib/ui/tickets/tickets_screen.dart <- TicketsCubit
6 queries, 5 type name(s), 1.0s
```

`TicketsScreen` appears in `affectedTypes`, so `ImpactGate` fires on it. This is the case
from the original idea: an API edit, and the tool names the screen.


Pure Dart on purpose: no Flutter SDK, so the fixture resolves fast and deterministically.
`widget.dart` is a shim; the scanner reads declaration spans, not superclasses.

## Running it

```bash
cd testbed/ticket_app
git init && git add -A && git commit -m baseline

# then edit lib/data/ticket_repository.dart, and:
cd ../..
dart run impact_radar:impact_scan --project testbed/ticket_app
```

Expect: `tickets_screen.dart` and `ticket_card.dart` in the report, at depth >= 2.
