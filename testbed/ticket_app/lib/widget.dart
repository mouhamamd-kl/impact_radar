/// Minimal stand-ins for the Flutter widget classes.
///
/// The scanner only looks at declaration spans and reference edges, never at whether a
/// class really extends StatelessWidget. Using a shim keeps this fixture a pure Dart
/// package: no Flutter SDK, no engine, fast and deterministic.
abstract class Widget {
  const Widget();
}

abstract class StatelessWidget extends Widget {
  const StatelessWidget();
  Widget build(BuildContext context);
}

class BuildContext {}

class Text extends Widget {
  const Text(this.data);
  final String data;
}

class Center extends Widget {
  const Center(this.child);
  final Widget child;
}

class Scaffold extends Widget {
  const Scaffold({this.body});
  final Widget? body;
}

class ListView extends Widget {
  const ListView({this.children = const <Widget>[]});
  final List<Widget> children;
}
