import 'package:flutter/widgets.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';

class Header extends StatelessWidget {
  const Header(
      {required this.currentActivity,
      required this.onCurrentActivitySelected,
      super.key});

  final Activity? currentActivity;
  final void Function(Activity?) onCurrentActivitySelected;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: currentActivity == null
          ? const Text('Plot')
          : ActivitySelector(
              selected: currentActivity,
              onSelect: onCurrentActivitySelected,
            ),
    );
  }
}
