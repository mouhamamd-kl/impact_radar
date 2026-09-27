import '../bloc/tickets_cubit.dart';
import '../widget.dart';
import 'tickets/tickets_screen.dart';

/// An unrelated screen. The scanner should NOT reach this one.
class HomeScreen extends StatelessWidget {
  const HomeScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(Text('home')));
}

/// Where the app assembles cubits, one level above the screen.
class AppRoutes {
  static Widget buildTickets(BuildContext context, TicketsCubit cubit) =>
      TicketsScreen(cubit: cubit);
}
