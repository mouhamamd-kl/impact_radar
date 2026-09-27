import '../../bloc/tickets_cubit.dart';
import '../../models.dart';
import '../../widget.dart';
import 'widgets/ticket_card.dart';

/// The screen the scanner has to reach. Only a full transitive walk finds this from a
/// repository edit: repo -> use case -> cubit -> screen is three hops.
class TicketsScreen extends StatelessWidget {
  const TicketsScreen({required this.cubit});

  final TicketsCubit cubit;

  @override
  Widget build(BuildContext context) {
    final List<Ticket> tickets = cubit.load();
    return Scaffold(
      body: ListView(
        children: <Widget>[
          for (final t in tickets) TicketCard(ticket: t),
        ],
      ),
    );
  }
}
