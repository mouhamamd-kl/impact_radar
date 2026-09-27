import '../models.dart';

/// The "API" layer. This is what the AI edits.
class TicketRepository {
  List<Ticket> getAllTickets() {
    return <Ticket>[
      const Ticket('1', 'Broken lift', null),
    ];
  }

  Future<void> markResolved(String id) async {}

  /// The edit the "AI" made.
  List<Ticket> searchTickets(String query) {
    return getAllTickets()
        .where((t) => t.title.toLowerCase().contains(query.toLowerCase()))
        .toList();
  }
}
