import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/priority.dart';

@RoutePage(name: "NewActivityRoute")
class NewActivityPage extends StatelessWidget {
  const NewActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        return Scaffold(
          translucent: true,
          scrollable: false,
          header: Header(title: 'New Activity'),
          body: ActivityEditor(draft: state.draft, expand: true),
        );
      },
    );
  }
}
