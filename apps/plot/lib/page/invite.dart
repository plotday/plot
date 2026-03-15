import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/user.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

/// Singleton to store a pending invitation token across the auth flow.
/// Set when the user navigates to /invite/:token and cleared after redemption.
class PendingInvite {
  PendingInvite._();

  static String? token;
  static String? email;
  static String? inviterName;

  static void clear() {
    token = null;
    email = null;
    inviterName = null;
  }
}

@RoutePage()
class InvitePage extends StatefulWidget {
  const InvitePage({@PathParam('token') required this.token, super.key});

  final String token;

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  String? _inviteEmail;
  String? _errorMessage;
  bool _isLoading = true;
  bool _isRedeeming = false;

  @override
  void initState() {
    super.initState();
    PendingInvite.token = widget.token;
    _fetchInviteInfo();
  }

  Future<void> _fetchInviteInfo() async {
    try {
      final result = await api.get<Map<String, dynamic>>(
        '/invitation/${widget.token}',
      );
      if (!mounted) return;
      setState(() {
        _inviteEmail = result['email'] as String?;
        PendingInvite.email = _inviteEmail;
        PendingInvite.inviterName = result['inviterName'] as String?;
        _isLoading = false;
      });
    } on ApiException catch (e) {
      log.warning('Failed to fetch invitation info', e);
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'This invitation link is invalid or has already been used.';
        _isLoading = false;
      });
    } on NetworkException catch (e) {
      log.warning('Network error fetching invitation info', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to connect. Please check your internet.';
        _isLoading = false;
      });
    }
  }

  Future<void> _redeemInvitation() async {
    setState(() {
      _isRedeeming = true;
      _errorMessage = null;
    });

    try {
      final result = await api.post<Map<String, dynamic>>(
        '/invitation/redeem',
        body: {'token': widget.token},
      );

      final error = result['error'] as String?;
      if (error != null) {
        if (!mounted) return;
        setState(() {
          _errorMessage = _errorMessageForCode(error);
          _isRedeeming = false;
        });
        return;
      }

      // Clear the pending invite
      PendingInvite.clear();

      // Navigate to the main app
      if (mounted) {
        context.router.replaceAll([EmptyShellRoute("Now")()]);
      }
    } on ApiException catch (e) {
      log.warning('Error redeeming invitation', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = _errorMessageForCode(e.description);
        _isRedeeming = false;
      });
    } on NetworkException catch (e) {
      log.warning('Network error redeeming invitation', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to connect. Please check your internet.';
        _isRedeeming = false;
      });
    } catch (e) {
      log.warning('Unexpected error redeeming invitation', e);
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to accept invitation. Please try again.';
        _isRedeeming = false;
      });
    }
  }

  String _errorMessageForCode(String code) {
    switch (code) {
      case 'invalid_token':
        return 'This invitation link is invalid or has already been used.';
      case 'already_redeemed_by_different_user':
        return 'This invitation has already been accepted by another account.';
      case 'contact_linked_to_other_user':
        return 'This invitation was sent to a different account.';
      default:
        return 'Failed to accept invitation. Please try again.';
    }
  }

  Future<void> _signOut() async {
    await Base.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final userState = context.read<UserBloc>().state;
    final accountEmail =
        userState is UserReady ? userState.user.primaryEmail : null;

    return Scaffold(
      center: true,
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: _isLoading
              ? const Center(child: Spinner())
              : Column(
                  spacing: 16,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Center(
                      child: SvgPicture.asset(
                        'assets/p.svg',
                        width: 120,
                        height: 120,
                      ),
                    ),
                    if (_errorMessage != null && _inviteEmail == null) ...[
                      Text(
                        'Invitation',
                        style: context.theme.typography.xl2.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      FAlert(
                        variant: FAlertVariant.destructive,
                        title: Text(_errorMessage!),
                      ),
                    ] else ...[
                      Text(
                        'Link New Email\nto Your Plot Account',
                        style: context.theme.typography.xl2.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      RichText(
                        textAlign: TextAlign.left,
                        text: TextSpan(
                          style: context.theme.typography.md.copyWith(
                            height: 1.5,
                          ),
                          children: [
                            const TextSpan(
                                text: 'You\'re accepting an invitation to '),
                            TextSpan(
                              text: _inviteEmail ?? 'a new email',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const TextSpan(
                                text: ' with your existing Plot account'),
                            if (accountEmail != null) ...[
                              const TextSpan(text: ' ('),
                              TextSpan(
                                text: accountEmail,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              const TextSpan(text: ')'),
                            ],
                            const TextSpan(
                                text:
                                    '. This will link those addresses so any new invitations to either will show up in your account.'),
                          ],
                        ),
                      ),
                      FButton(
                        onPress: _isRedeeming ? null : _redeemInvitation,
                        variant: FButtonVariant.primary,
                        child: _isRedeeming
                            ? const Spinner()
                            : const Text('Link Email'),
                      ),
                      if (_errorMessage != null)
                        FAlert(
                          variant: FAlertVariant.destructive,
                          title: Text(_errorMessage!),
                        ),
                      RichText(
                        textAlign: TextAlign.left,
                        text: TextSpan(
                          style: context.theme.typography.sm.copyWith(
                            height: 1.5,
                            color: context.theme.colors.mutedForeground,
                          ),
                          children: [
                            const TextSpan(
                                text:
                                    'If you want to accept this invitation with a new account, '),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: GestureDetector(
                                onTap: _signOut,
                                child: Text(
                                  'sign out',
                                  style: context.theme.typography.sm.copyWith(
                                    color: context.theme.colors.primary,
                                    decoration: TextDecoration.underline,
                                    decorationColor:
                                        context.theme.colors.primary,
                                  ),
                                ),
                              ),
                            ),
                            const TextSpan(
                                text:
                                    ' and click the link again. If you don\'t want to link this email, you can ignore this.'),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
