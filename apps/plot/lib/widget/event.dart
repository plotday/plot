import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class DayHeader extends StatelessWidget {
  const DayHeader({
    this.date,
    this.now = false,
    this.selected = false,
    super.key,
  });

  final Date? date;
  final bool now;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      body: Align(
        alignment: Alignment.center,
        child: Text(
          date!.format(format: 'EEEE, MMMM d, yyyy'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.theme.colors.mutedForeground,
            fontSize: context.theme.typography.xs.fontSize,
          ),
        ),
      ),
      selected: selected,
    );
  }
}

class AgendaHeader extends StatelessWidget {
  const AgendaHeader({
    this.priority,
    this.context,
    this.event,
    this.now = false,
    this.selected = false,
    super.key,
  });

  final Event? event;
  final bool now;
  final Priority? priority;
  final Priority? context;

  final bool selected;

  @override
  Widget build(BuildContext context) {
    // Compute priority ancestry from the priority or event
    final currentPriority = priority ?? event?.priority;

    // Compute ancestry relative to priorityContext
    final priorityAncestry = currentPriority?.ancestors(
      context: this.context,
      includeSelf: true,
    );

    return ListTile(
      command: event?.draft == false
          ? ChangeCurrentEvent(event!)
          : priorityAncestry?.isNotEmpty == true
          ? CommandWrapper(
              OpenPriority.byId(priorityAncestry!.last.id),
              icon: Value(null),
            )
          : null,
      selected: selected,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8.0,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            spacing: 8.0,
            children: [
              if (event != null) ...[
                Text(
                  event!.start.toTimeOfDay().isMidnight
                      ? ''
                      : event!.start.toTimeOfDay().format(context),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: context.theme.colors.mutedForeground,
                    fontSize: context.theme.typography.xs.fontSize,
                  ),
                ),
                if (event!.duration.inSeconds > 0 &&
                    !(event!.draft &&
                        event!.end == event!.start.startOfDay.addDays(1)))
                  Text(
                    event!.duration.format(),
                    style: TextStyle(
                      color: context.theme.colors.mutedForeground,
                      fontSize: context.theme.typography.xs.fontSize,
                    ),
                  ),
              ],
              Expanded(
                child: currentPriority?.id == this.context?.id
                    ? Text(
                        'Other',
                        style: DefaultTextStyle.of(context).style.copyWith(
                          color: context.theme.colors.mutedForeground,
                          fontSize: context.theme.typography.xs.fontSize,
                        ),
                      )
                    : PriorityLabel(ancestors: priorityAncestry),
              ),
            ],
          ),
          if (event?.name != null)
            Row(
              spacing: 4.0,
              children: [
                Icon(PlotIcon.event, size: 12, color: context.colour.muted),
                Text(
                  event!.name ?? 'Untitled Event',
                  textAlign: TextAlign.start,
                  style: DefaultTextStyle.of(context).style.copyWith(
                    color: context.theme.colors.foreground,
                    fontSize: context.theme.typography.xs.fontSize,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
