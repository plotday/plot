import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/context.dart';

class NoteWidget extends StatelessWidget {
  const NoteWidget({
    required this.note,
    super.key,
  });

  final Note note;

  @override
  Widget build(BuildContext context) {
    return Tapable(
      onTap: () => context.read<ContextBloc>().setTopic(note.topicId),
      child: Row(
        children: [
          Expanded(
            child: Text(note.body),
          ),
        ],
      ),
    );
  }
}
