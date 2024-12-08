import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/material.dart' as material;

class PlotIcon extends FaIcon {
  PlotIcon.back({super.size, super.color, super.key})
      : super(PlatformResolver.current(
          macOSResolver: () => material.Icons.arrow_back_ios_new_rounded,
          iOSResolver: () => material.Icons.arrow_back_ios_new_rounded,
          defaultResolver: () => material.Icons.arrow_back,
        ));
  const PlotIcon.left({super.size, super.color, super.key})
      : super(FontAwesomeIcons.chevronLeft);
  const PlotIcon.right({super.size, super.color, super.key})
      : super(FontAwesomeIcons.chevronRight);
  const PlotIcon.todo({super.size, super.color, super.key})
      : super(FontAwesomeIcons.circle);
  const PlotIcon.done({super.size, super.color, super.key})
      : super(FontAwesomeIcons.circleCheck);
  const PlotIcon.scheduled({super.size, super.color, super.key})
      : super(FontAwesomeIcons.alarmClock);
  const PlotIcon.pinned({super.size, super.color, super.key})
      : super(FontAwesomeIcons.thumbtack);
  const PlotIcon.today({super.size, super.color, super.key})
      : super(FontAwesomeIcons.calendar);
  const PlotIcon.add({super.size, super.color, super.key})
      : super(FontAwesomeIcons.plusLarge);
}
