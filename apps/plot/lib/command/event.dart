// class PickEventResponse extends ShowCommands {
//   PickEventResponse(Event event)
//     : super(
//         title: 'Change Response',
//         icon: PlotIcon.event,
//         actions: (context) => Future.value(
//           Actions(
//             prompt: 'Select response',
//             groups: [
//               StaticCommandGroup(
//                 title: 'Response Options',
//                 commands: [
//                   ChangeEventResponse(
//                     event,
//                     EventResponse.accepted,
//                     title: 'Accepted',
//                     subtitle: 'Accept this event',
//                     icon: PlotIcon.done,
//                   ),
//                   ChangeEventResponse(
//                     event,
//                     EventResponse.declined,
//                     title: 'Declined',
//                     subtitle: 'Decline this event',
//                     icon: PlotIcon.archived,
//                   ),
//                   ChangeEventResponse(
//                     event,
//                     EventResponse.tentative,
//                     title: 'Tentative',
//                     subtitle: 'Maybe attend this event',
//                     icon: PlotIcon.priority,
//                   ),
//                 ],
//               ),
//             ],
//           ),
//         ),
//       );
// }
//
// class ChangeEventResponse extends Command {
//   ChangeEventResponse(
//     this.event,
//     this.response, {
//     required super.title,
//     super.subtitle,
//     super.icon,
//   });
//   final Event event;
//   final EventResponse response;
//
//   @override
//   Future<CommandReturn> run(BuildContext context) async {
//     await event
//         .copyWith(
//           response: Value(response),
//           archivedAt: response == EventResponse.declined
//               ? Value(DateTime.now())
//               : Value(null),
//         )
//         .save();
//     return const CommandDone();
//   }
// }
