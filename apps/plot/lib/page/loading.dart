import 'package:flutter/widgets.dart';

import 'package:plot/widget/widget.dart';

class LoadingPage extends StatelessWidget {
  const LoadingPage({this.message, super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 16,
        children: [
          Spinner(),
          if (message != null) Text(message!),
        ],
      ),
    );
  }
}
