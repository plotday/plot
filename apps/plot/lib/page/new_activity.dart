import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/command/command.dart';

@RoutePage(name: "NewActivityRoute")
class NewActivityPage extends StatelessWidget {
  const NewActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        return Scaffold(
          translucent: true,
          header: Header(title: 'New Activity'),
          body: ActivityEditor(
            onAdd: (activity) async {
              await context.read<PriorityBloc>().add(activity);
              if (!context.mounted) return;
              await context.run(ChangeCurrentActivity(activity));
            },
            draft: state.draft,
          ),
        );
      },
    );
  }
}
