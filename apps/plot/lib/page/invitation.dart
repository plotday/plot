import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/store/store.dart' hide Link;
import 'package:plot/command/settings.dart';
import 'package:plot/state/user.dart';
import 'package:logging/logging.dart';
import 'logging.dart';

@RoutePage()
class InvitationPage extends StatefulWidget {
  const InvitationPage({super.key});

  @override
  State<InvitationPage> createState() => _InvitationPageState();
}

class _InvitationPageState extends State<InvitationPage> {
  final TextEditingController _codeController = TextEditingController();
  String? _errorMessage;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _redeemCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _errorMessage = "Please enter an invitation code";
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await api.post<Map<String, dynamic>>('/activate', body: {'code': code});

      // Refresh session to get updated JWT with active status
      await Base.refreshSession();
    } catch (e) {
      log.warning('Error activating account', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().contains('Invalid invitation')
            ? 'Invalid invitation code'
            : e.toString().contains('no remaining uses')
            ? 'This invitation code has no remaining uses'
            : 'Failed to activate account';
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      scrollable: false,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerRight,
              child: Button.icon(SignOut()),
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 400),
                child: Column(
                  spacing: 16,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Invitation Code',
                      style: context.theme.typography.xl2.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      'Plot is currently in private testing. Please enter your invitation code to continue.',
                      style: context.theme.typography.base.copyWith(
                        height: 1.5,
                      ),
                    ),
                    TextField(
                      controller: _codeController,
                      label: 'Invitation Code',
                      autofocus: true,
                      maxLines: 1,
                      onSubmitted: (_) => _redeemCode(),
                    ),
                    FButton(
                      onPress: _isSubmitting ? null : _redeemCode,
                      style: FButtonStyle.primary(),
                      child: _isSubmitting ? Spinner() : Text('Redeem Code'),
                    ),
                    if (_errorMessage != null)
                      FAlert(
                        style: FAlertStyle.destructive(),
                        title: Text(_errorMessage ?? ''),
                      ),
                    Link(
                      uri: Uri.parse('https://plot.day/start'),
                      child: Text(
                        "Don't have an invitation yet? Join the waitlist.",
                        style: TextStyle(color: context.theme.colors.primary),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
