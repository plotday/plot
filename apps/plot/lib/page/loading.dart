import 'dart:async';

import 'package:plot/state/user.dart';
import 'package:plot/widget/widget.dart';

class LoadingPage extends StatefulWidget {
  const LoadingPage({this.message, super.key});

  final String? message;

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  bool _showSpinner = false;
  String? _slowMessage;
  Timer? _spinnerTimer;
  Timer? _slowTimer;
  Timer? _stuckTimer;

  @override
  void initState() {
    super.initState();
    // Delay showing the spinner to avoid flashing for quick transitions
    _spinnerTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        setState(() {
          _showSpinner = true;
        });
      }
    });

    _slowTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(() {
          _slowMessage = 'Still loading...';
        });
      }
    });

    _stuckTimer = Timer(const Duration(seconds: 60), () {
      if (mounted) {
        setState(() {
          _slowMessage = 'Something may have gone wrong';
        });
      }
    });
  }

  @override
  void dispose() {
    _spinnerTimer?.cancel();
    _slowTimer?.cancel();
    _stuckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      center: true,
      body: Stack(
        alignment: Alignment.center,
        children: [
          if (_showSpinner) Spinner(size: 22),
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: ValueListenableBuilder<String?>(
              valueListenable: UserBloc.statusNotifier,
              builder: (context, status, _) {
                final displayMessage =
                    _slowMessage ?? status ?? widget.message;
                if (displayMessage == null) return const SizedBox.shrink();
                return Text(
                  displayMessage,
                  style: TextStyle(
                    color: context.theme.colors.mutedForeground,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
