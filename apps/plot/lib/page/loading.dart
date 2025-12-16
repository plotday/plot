import 'dart:async';

import 'package:plot/widget/widget.dart';

class LoadingPage extends StatefulWidget {
  const LoadingPage({this.message, super.key});

  final String? message;

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  bool _showSpinner = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Delay showing the spinner to avoid flashing for quick transitions
    _timer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        setState(() {
          _showSpinner = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      center: true,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: 16,
          children: [
            if (_showSpinner) Spinner(),
            if (widget.message != null) Text(widget.message!),
          ],
        ),
      ),
    );
  }
}
