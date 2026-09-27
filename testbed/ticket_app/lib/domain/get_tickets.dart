import '../data/ticket_repository.dart';
import '../models.dart';

/// Use case sitting between the repository and the cubit.
class GetTickets {
  const GetTickets(this._repository);

  final TicketRepository _repository;

  List<Ticket> call() => _repository.getAllTickets();
}
