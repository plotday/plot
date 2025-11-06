import 'package:plot/widget/widget.dart';

class LoadingPage extends StatelessWidget {
  const LoadingPage({this.message, super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: 16,
          children: [
            Spinner(),
            if (message != null) Text(message!),
          ],
        ),
      ),
    );
  }
}
