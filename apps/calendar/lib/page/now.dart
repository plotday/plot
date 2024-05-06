import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/now.dart';

class NowPage extends StatelessWidget {
  const NowPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(builder: (context, state) {
      return Scaffold(
        appBar: AppBar(
          title: Text(state.context?.name ?? 'Everything else'),
          actions: const [],
        ),
      );
    });
  }
}
