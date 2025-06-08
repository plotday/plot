import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class AgendaHeader extends StatelessWidget {
  AgendaHeader({
    List<PriorityAncestor>? priorityAncestry,
    this.event,
    this.date,
    this.now = false,
    this.selected = false,
    this.onHover,
    super.key,
  }) : priorityAncestry =
           priorityAncestry ?? event?.priority?.ancestors(includeSelf: true);

  final Event? event;
  final Date? date;
  final bool now;
  final List<PriorityAncestor>? priorityAncestry;

  final bool selected;
  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    // Handle date header case
    if (date != null && event == null) {
      return ListTile(
        leading: Text(
          date!.format(format: 'EEE'),
          textAlign: TextAlign.end,
          style: TextStyle(
            fontSize: context.theme.typography.xs.fontSize,
          ),
        ),
        leadingPadding: true,
        body: Text(
          date!.format(format: 'MMM d'),
          textAlign: TextAlign.start,
          style: TextStyle(
            color: context.theme.colors.mutedForeground,
            fontSize: context.theme.typography.xs.fontSize,
          ),
        ),
        leadingWidth: 60,
        selected: selected,
        onHover: onHover,
      );
    }
    
    // Handle event header case
    return ListTile(
      // icon: PlotIcon.event,
      leading:
          event == null
              ? SizedBox()
              : Text(
                event!.start.toTimeOfDay().isMidnight
                    ? ''
                    : event!.start.toTimeOfDay().format(context),
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: context.theme.colors.mutedForeground,
                  fontSize: context.theme.typography.xs.fontSize,
                ),
              ),
      leadingWidth: 60.0,
      leadingPadding: true,
      command:
          priorityAncestry?.isNotEmpty == true
              ? ChangeCurrentPriority.byId(priorityAncestry!.last.id)
              : null,
      selected: selected,
      onHover: onHover,
      body: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        spacing: 8.0,
        children: [
          Expanded(child: PriorityLabel(ancestors: priorityAncestry)),
          if (event != null && event!.duration.inSeconds > 0)
            Text(
              event!.duration.format(),
              style: TextStyle(
                color: context.theme.colors.mutedForeground,
                fontSize: context.theme.typography.xs.fontSize,
              ),
            ),
        ],
      ),
    );
  }
}

class EventWidget extends StatelessWidget {
  const EventWidget({
    required this.event,
    this.context,
    this.selected = false,
    this.onHover,
    super.key,
  });

  final Event event;

  /// Display priority relative to this priority.
  final Priority? context;

  final bool selected;
  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      icon: PlotIcon.event,
      leadingWidth: 60.0,
      leadingPadding: true,
      command:
          event.priority != null
              ? ChangeCurrentPriority(event.priority!)
              : null,
      selected: selected,
      onHover: onHover,
      title: event.name ?? 'Untitled Event',
    );
  }
}
