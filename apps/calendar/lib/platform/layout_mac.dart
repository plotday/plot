import 'package:flutter/widgets.dart';

class MacLayout extends StatefulWidget {
  const MacLayout(this.panels, {super.key});

  @override
  State<MacLayout> createState() {
    return MacLayoutState();
  }

  final List<Widget> panels;
}

class MacLayoutState extends State<MacLayout> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return const Text('Mac Layout');
  }
}
