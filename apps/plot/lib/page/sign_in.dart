import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/auth/auth_service.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/auth_button.dart';
import 'package:plot/app_info.dart';
import 'package:plot/base.dart';
import 'package:plot/page/invite.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/router.dart' show EmailSignInRoute;
import 'logging.dart';

@RoutePage()
class SignInPage extends StatefulWidget {
  const SignInPage({this.returnTo, super.key});

  final String? returnTo;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  bool _isLoading = false;

  bool _isExternalAccountNotFound(AuthError error) {
    // Use the error code (mapped from Clerk's 'external_account_not_found')
    // instead of fragile string matching on the error message.
    return error.code == AuthErrorCode.noAssociatedStrategy;
  }

  bool _isAlreadySignedIn(AuthError error) {
    // Don't rely on error message strings — check if Clerk actually has
    // an active session regardless of which error was thrown.
    return Base.auth.isSignedIn;
  }

  void _showGenericError(Object error, StackTrace? stackTrace) {
    Tracker.captureException(error, stackTrace);
    if (!mounted) return;
    context.showToast(
      message: 'Something went wrong. Try again later.',
      isError: true,
    );
    setState(() {
      _isLoading = false;
    });
  }

  @override
  void initState() {
    super.initState();
    if (PendingInvite.token != null && PendingInvite.email == null) {
      _fetchInviteInfo();
    }
  }

  Future<void> _fetchInviteInfo() async {
    try {
      final result = await api.get<Map<String, dynamic>>(
        '/invitation/${PendingInvite.token}',
      );
      if (!mounted) return;
      setState(() {
        PendingInvite.email = result['email'] as String?;
        PendingInvite.inviterName = result['inviterName'] as String?;
      });
    } on ApiException catch (e) {
      log.warning('Failed to fetch invitation info', e);
    } on NetworkException catch (e) {
      log.warning('Network error fetching invitation info', e);
    }
  }

  Future<void> _handleOAuthSignIn({
    required IdTokenProvider provider,
    required String idToken,
  }) async {
    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      await Future(() async {
        try {
          await Base.auth.signInWithIdToken(
            provider: provider,
            idToken: idToken,
          );
        } catch (e) {
          rethrow;
        }
        try {
          // If Clerk indicates this should become a sign-up, transfer the flow.
          await Base.auth.transfer();
        } catch (e) {
          log.warning('transfer failed', e);
          rethrow;
        }

        // Call /activate to get user identity
        await Base.resolveIdentity();
        // UserBloc will pick up the emission and transition to UserReady
      }).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      if (!mounted) return;
      context.showToast(
        message: 'Sign-in is taking too long. Please try again.',
        isError: true,
      );
      setState(() {
        _isLoading = false;
      });
    } on AuthError catch (e, t) {
      AuthError errorToShow = e;
      if (_isAlreadySignedIn(e)) {
        // Clerk already has a session — just activate to set up identity
        try {
          await Base.resolveIdentity();
          return;
        } catch (activateError) {
          log.warning('Failed to activate existing session', activateError);
        }
        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });
        return;
      }
      log.warning('Error signing in with OAuth', e, t);
      Tracker.captureException(e, t);
      if (_isExternalAccountNotFound(e)) {
        try {
          log.info('External account not found, attempting sign-up');
          await Future(() async {
            await Base.auth.signUpWithIdToken(
              provider: provider,
              idToken: idToken,
            );
            await Base.auth.transfer();
            await Base.resolveIdentity();
          }).timeout(const Duration(seconds: 15));
          return;
        } on TimeoutException {
          if (!mounted) return;
          context.showToast(
            message: 'Sign-in is taking too long. Please try again.',
            isError: true,
          );
          setState(() {
            _isLoading = false;
          });
          return;
        } on AuthError catch (signUpError, signUpTrace) {
          log.warning('Error signing up with OAuth', signUpError, signUpTrace);
          errorToShow = signUpError;
        } catch (signUpError, signUpTrace) {
          log.warning('Error during OAuth sign-up', signUpError, signUpTrace);
          _showGenericError(signUpError, signUpTrace);
          return;
        }
      }
      if (!mounted) return;
      String message = errorToShow.toString();
      if (message.contains('google_one_tap') ||
          errorToShow.code == AuthErrorCode.noSuchFirstFactorStrategy) {
        message =
            'Google sign-in is not enabled for this environment. Please try another method.';
      }
      if (message.contains('email_already_linked') ||
          message.contains('already associated')) {
        message =
            'This email is already associated with another account. '
            'Please sign in with the email you originally registered with.';
      }
      if (errorToShow.code == AuthErrorCode.serverErrorResponse ||
          message.contains('error received from server')) {
        _showGenericError(errorToShow, t);
        return;
      }
      context.showToast(message: message, isError: true);
      setState(() {
        _isLoading = false;
      });
    } catch (e, t) {
      log.warning('Error during sign-in', e, t);
      _showGenericError(e, t);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const LoadingPage(message: 'Plotting your success…');
    }

    return Scaffold(
      scrollable: false,
      body: CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Column(
              children: [
                const Spacer(),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        spacing: 16,
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Center(
                            child: SvgPicture.asset(
                              "assets/p.svg",
                              width: 120,
                              height: 120,
                            ),
                          ),
                          if (PendingInvite.token != null) ...[
                            Text(
                              "You've been invited to Plot",
                              style: context.theme.typography.xl2.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            if (PendingInvite.inviterName != null ||
                                PendingInvite.email != null)
                              RichText(
                                textAlign: TextAlign.center,
                                text: TextSpan(
                                  style: context.theme.typography.md.copyWith(
                                    height: 1.5,
                                  ),
                                  children: [
                                    if (PendingInvite.inviterName != null) ...[
                                      TextSpan(text: PendingInvite.inviterName),
                                      const TextSpan(
                                        text:
                                            ' has invited you to collaborate on Plot.\n',
                                      ),
                                    ],
                                    const TextSpan(text: 'Sign up or sign in'),
                                    if (PendingInvite.email != null) ...[
                                      const TextSpan(text: ' to link '),
                                      TextSpan(
                                        text: PendingInvite.email,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                    const TextSpan(
                                      text:
                                          ' and make progress on your priorities.',
                                    ),
                                  ],
                                ),
                              )
                            else
                              Text(
                                "You've been invited to collaborate on Plot.\nSign up or sign in to link your email and make progress on your priorities.",
                                textAlign: TextAlign.center,
                                style: context.theme.typography.md,
                              ),
                          ] else
                            Text(
                              'Sign in to make progress on your priorities',
                              textAlign: TextAlign.center,
                              style: context.theme.typography.md,
                            ),
                          const SizedBox(height: 8),

                          // OAuth buttons
                          AuthButton.authenticate(
                            provider: AuthProvider.google,
                            autoSignIn: false,
                            onAuth: ({required idToken, accessToken}) async {
                              await _handleOAuthSignIn(
                                provider: IdTokenProvider.google,
                                idToken: idToken,
                              );
                            },
                            onRedirectAuth: () async {
                              if (mounted) {
                                setState(() {
                                  _isLoading = true;
                                });
                              }
                              try {
                                await Base.auth.signInWithRedirect(
                                  provider: IdTokenProvider.google,
                                );
                              } on AuthError catch (e, t) {
                                log.warning(
                                  'Google redirect sign-in failed',
                                  e,
                                  t,
                                );
                                Tracker.captureException(e, t);
                                if (context.mounted) {
                                  context.showToast(
                                    message: e.toString(),
                                    isError: true,
                                  );
                                  setState(() {
                                    _isLoading = false;
                                  });
                                }
                              } catch (e, t) {
                                log.warning(
                                  'Google redirect sign-in failed',
                                  e,
                                  t,
                                );
                                _showGenericError(e, t);
                              }
                            },
                            onError: (error) {
                              if (mounted) {
                                context.showToast(
                                  message: error,
                                  isError: true,
                                );
                              }
                            },
                          ),

                          if (defaultTargetPlatform != TargetPlatform.windows)
                            AuthButton.authenticate(
                              provider: AuthProvider.apple,
                              autoSignIn: false,
                              onAuth: ({required idToken, accessToken}) async {
                                await _handleOAuthSignIn(
                                  provider: IdTokenProvider.apple,
                                  idToken: idToken,
                                );
                              },
                              onError: (error) {
                                if (mounted) {
                                  context.showToast(
                                    message: error,
                                    isError: true,
                                  );
                                }
                              },
                            ),

                          // Continue with email button
                          FButton(
                            onPress: () {
                              context.router.navigate(
                                EmailSignInRoute(returnTo: widget.returnTo),
                              );
                            },
                            variant: FButtonVariant.secondary,
                            prefix: FaIcon(
                              FontAwesomeIcons.envelope,
                              color: context.theme.colors.foreground,
                            ),
                            mainAxisSize: .min,
                            child: Text(
                              'Continue with email',
                              style: context.theme.typography.md.copyWith(
                                color: context.theme.colors.foreground,
                                height: 1,
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),
                          const TermsAgreement(),
                        ],
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Text(
                      AppInfo.versionString,
                      style: context.theme.typography.xs.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
