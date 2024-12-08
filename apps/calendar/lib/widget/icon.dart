import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/material.dart' as material;

class BackIcon extends StatelessWidget {
  const BackIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (context) => const material.BackButtonIcon(),
    );
  }
}

class Icons {
  static const back = BackIcon();
  static const left = FaIcon(FontAwesomeIcons.chevronLeft);
  static const right = FaIcon(FontAwesomeIcons.chevronRight);
  static const todo = FaIcon(FontAwesomeIcons.circle);
  static const done = FaIcon(FontAwesomeIcons.circleCheck);
  static const scheduled = FaIcon(FontAwesomeIcons.alarmClock);
  static const pinned = FaIcon(FontAwesomeIcons.thumbtack);
  static const today = FaIcon(FontAwesomeIcons.circleCalendar);
  static const add = FaIcon(FontAwesomeIcons.plusLarge);
}
