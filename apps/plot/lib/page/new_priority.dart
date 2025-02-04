import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';

class NewPriorityPage extends StatelessWidget {
  const NewPriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) => Dialog(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                onSubmitted: (name) async {
                  final priority = Priority(
                    name: name,
                    parent:
                        state is PrioritySelectedState ? state.current : null,
                    order: Order.first(),
                  );
                  await priority.save();
                  if (context.mounted) {
                    Navigator.of(context).pop(priority);
                  }
                },
                label: "Add an priority",
                maxLines: 1,
                autofocus: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
