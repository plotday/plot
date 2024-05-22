import 'package:flutter/widgets.dart';

class ScrollControllerContext extends InheritedWidget {
  static ScrollController of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ScrollControllerContext>()!
        .controller;
  }

  const ScrollControllerContext({
    required this.controller,
    required super.child,
    super.key,
  });
  final ScrollController controller;

  @override
  bool updateShouldNotify(ScrollControllerContext oldWidget) {
    return controller != oldWidget.controller;
  }
}
