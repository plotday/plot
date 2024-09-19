import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/now.dart';
import 'package:plot/store/store.dart';

class EventMenu extends StatelessWidget {
  const EventMenu({required this.event, super.key});

  final Event event;

  Future<void> _rsvp(EventResponse response) async {
    await event.copyWith(response: response).save();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
        builder: (context, state) => MenuAnchor(
              builder: (BuildContext context, MenuController controller,
                  Widget? child) {
                return Row(
                  children: [
                    if (event.at.end.isAfter(DateTime.now()))
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => {_rsvp(EventResponse.declined)},
                        tooltip: 'Remove',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                      ),
                    IconButton(
                      onPressed: () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
                      icon: const Icon(Icons.more_horiz),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Show menu',
                    )
                  ],
                );
              },
              menuChildren: [
                if (event.at.isNow())
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.add),
                    child: const Text('More time'),
                    onPressed: () {
                      context.read<NowBloc>().add(ContextTimeIncreased());
                    },
                  ),
                if (event.at.isNow())
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.remove),
                    child: const Text('Less time'),
                    onPressed: () {
                      context.read<NowBloc>().add(ContextTimeDecreased());
                    },
                  ),
              ],
            ));
  }
}
