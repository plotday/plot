import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/context.dart';

class NotesPage extends StatelessWidget {
  const NotesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
        builder: (buildContext, state) => const Text('Notes'));
  }
}
