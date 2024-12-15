import 'package:flutter/material.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/util/theme_color.dart';

class EventWidget extends StatelessWidget {
  const EventWidget({
    required this.event,
    required this.onSelect,
    this.selected = false,
    ThemeColor? color,
    super.key,
  }) : color = color ?? const ThemeColor.defaultColor();

  final Event event;
  final void Function() onSelect;
  final bool selected;
  final ThemeColor color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onSelect(),
      child: Container(
        color: selected
            ? const ThemeColor.defaultColor().getBackground(context)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 68,
                alignment: Alignment.topRight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    TimeWidget(time: event.at.start),
                    if (!event.draft ||
                        (event.at.start.toTimeOfDay().isMidnight &&
                            event.at.end.toTimeOfDay().isMidnight)) ...[
                      const SizedBox(height: 4),
                      DurationText(
                        duration: !event.draft ||
                                !(event.at.start.toTimeOfDay().isMidnight ||
                                    event.at.end.toTimeOfDay().isMidnight)
                            ? event.at.duration
                            : Duration.zero,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (event.name == null && event.activity == null)
                      const SizedBox(
                        height: 16,
                        child: Squiggle(),
                      ),
                    if (event.name != null)
                      Text(
                        event.name!,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (event.name != null && event.activity != null)
                      const SizedBox(height: 4),
                    if (event.activity != null)
                      Text(
                        event.activity!.name,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// builder: (context, prioritiesState) => Expanded(
//   child: MenuAnchor(
//     builder: (BuildContext context, MenuController controller,
//             Widget? child) =>
//         InkWell(
//       child: Column(
//         crossAxisAlignment: CrossAxisAlignment.start,
//         children: [
//           Text(
//             event.context?.name ?? 'Open',
//           ),
//           if (event.name != null)
//             Text(
//               event.name!,
//               style: const TextStyle(fontWeight: FontWeight.w500),
//             ),
//         ],
//       ),
//       onTap: () {
//         if (controller.isOpen) {
//           controller.close();
//         } else {
//           controller.open();
//         }
//       },
//     ),
//     menuChildren: [
//       if (event.id != null &&
//           event.at.end.isAfter(DateTime.now()))
//         MenuItemButton(
//           leadingIcon: const Icon(Icons.event_busy),
//           onPressed: () {
//             event
//                 .copyWith(
//                   response: EventResponse.declined,
//                 )
//                 .save();
//           },
//           child: const Text('Release time'),
//         ),
//       if (prioritiesState is PriorityLoaded)
//         ...prioritiesState.priorities.map(
//           (priority) => MenuItemButton(
//             onPressed: () {
//               event
//                   .copyWith(
//                     context: priority.context,
//                   )
//                   .save();
//             },
//             child: Text(priority.context?.name ?? 'Other'),
//           ),
//         )
//     ],
//   ),
// ),
