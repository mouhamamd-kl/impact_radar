import '../domain/get_tickets.dart';
import '../models.dart';

/// Holds ticket state. The scanner must walk through this to reach the UI.
class TicketsCubit {
  TicketsCubit(this._getTickets);

  final GetTickets _getTickets;

  List<Ticket> load() => _getTickets();
}
