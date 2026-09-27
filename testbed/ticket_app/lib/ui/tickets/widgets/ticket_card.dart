import '../../../models.dart';
import '../../../widget.dart';

/// A small organism, composed into the screen.
class TicketCard extends StatelessWidget {
  const TicketCard({required this.ticket});

  final Ticket ticket;

  @override
  Widget build(BuildContext context) => Text(ticket.title);
}