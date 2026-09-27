/// Domain model. Leaf of the chain, referenced by the repository.
class Ticket {
  const Ticket(this.id, this.title, this.resolvedAt);

  final String id;
  final String title;
  final DateTime? resolvedAt;

  @override
  String toString() => 'Ticket($id)';
}
