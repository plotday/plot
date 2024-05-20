import 'package:flutter/widgets.dart';

class MacLayout extends StatefulWidget {
  const MacLayout(this.drawer, this.primary, this.secondary, {super.key});

  @override
  State<MacLayout> createState() {
    return MacLayoutState();
  }

  final Widget primary;
  final Widget secondary;
  final Widget drawer;
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
