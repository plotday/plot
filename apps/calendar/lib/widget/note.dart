import 'package:flutter/widgets.dart';

import 'text_field.dart';

class Note extends StatelessWidget {
  const Note({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return const TextField(label: 'Add a note');
  }
}
