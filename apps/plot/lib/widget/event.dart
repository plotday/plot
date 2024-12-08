import 'package:flutter/material.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class EventWidget extends StatelessWidget {
  const EventWidget({
    required this.event,
    required this.onSelect,
    super.key,
  });

  final Event event;
  final void Function() onSelect;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onSelect(),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 72,
              alignment: Alignment.topRight,
              child:
                  event.id != null || !event.at.start.toTimeOfDay().isMidnight
                      ? TimeWidget(time: event.at.start)
                      : SmallCapsWidget(
                          text: event.at.start.format('EEEE'),
                        ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 20,
                    child: Row(
                      children: [
                        DurationWidget(
                          duration: event.id != null ||
                                  !(event.at.start.toTimeOfDay().isMidnight ||
                                      event.at.end.toTimeOfDay().isMidnight)
                              ? event.at.duration
                              : Duration.zero,
                        ),
                        Expanded(
                          child: Container(
                            height: 0.5,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (event.activity != null)
                    Text(
                      event.activity!.name,
                    ),
                  if (event.name != null)
                    Text(
                      event.name!,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                ],
              ),
            ),
          ],
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
