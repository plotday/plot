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
  bool _isEmailLoading = false;

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

  /// Clerk already has a live session (a prior OAuth redirect completed,
  /// another tab signed in, or a sign-in that succeeded after its caller
  /// timed out) but the app is still on the sign-in page because the Plot
  /// identity hasn't been resolved. Don't surface this as an error — resolve
  /// identity so UserBloc transitions to ready and the app navigates into the
  /// workspace.
  Future<void> _resolveExistingSession() async {
    if (mounted) {
      setState(() => _isLoading = true);
    }
    try {
      await Base.resolveIdentityResilient();
      // On success UserBloc emits and this page is replaced — nothing more
      // to do here.
    } catch (e, t) {
      // Resolution genuinely failed (e.g. the session token is invalid).
      // Drop back to the sign-in buttons so the user can retry instead of
      // being stranded on a spinner. Transient backend stalls are already
      // absorbed by resolveIdentityResilient's retries, so this isn't a
      // surprising failure worth reporting.
      log.warning('Failed to resolve existing Clerk session', e, t);
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
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
    // If Clerk already has a live session but we've landed on the sign-in
    // page (e.g. an OAuth redirect completed yet the running app never
    // resolved the Plot identity), don't strand the user here — resolve
    // identity and move on. Skip when the session was force-expired so the
    // "session expired" banner shows and the user re-authenticates
    // deliberately. Also skip right after an explicit sign-out: signOut()
    // awaits Clerk sign-out last, so isSignedIn can still read true here, and
    // auto-resolving would lift the sign-out latch and resurrect the session.
    if (Base.auth.isSignedIn &&
        !Base.wasForceSignedOut &&
        !Base.wasExplicitlySignedOut) {
      _isLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveExistingSession();
      });
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
      // Establish the Clerk session. This leg is normally fast; give it its
      // own budget so a slow /activate can't eat into it.
      await Future(() async {
        await Base.auth.signInWithIdToken(provider: provider, idToken: idToken);
        // If Clerk indicates this should become a sign-up, transfer the flow.
        await Base.auth.transfer();
      }).timeout(const Duration(seconds: 20));

      // Resolve identity via /activate, retrying transient backend stalls.
      await Base.resolveIdentityResilient();
      // UserBloc will pick up the emission and transition to UserReady
    } on TimeoutException catch (e, t) {
      // Reached here only after the resolve retries were exhausted (or Clerk
      // itself stalled). Capture it — the prior code swallowed this path,
      // which is exactly why a reviewer's timed-out sign-in was invisible.
      Tracker.captureException(e, t);
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
        // Clerk already has a session (e.g. a prior attempt timed out after
        // sign-in succeeded) — just resolve identity, with the same retries.
        await _resolveExistingSession();
        return;
      }
      log.warning('Error signing in with OAuth', e, t);
      if (_isExternalAccountNotFound(e)) {
        try {
          log.info('External account not found, attempting sign-up');
          await Future(() async {
            await Base.auth.signUpWithIdToken(
              provider: provider,
              idToken: idToken,
            );
            await Base.auth.transfer();
          }).timeout(const Duration(seconds: 20));
          await Base.resolveIdentityResilient();
          return;
        } on TimeoutException catch (timeoutError, timeoutTrace) {
          Tracker.captureException(timeoutError, timeoutTrace);
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
      // Single capture point for this leg. Tag with the raw Clerk error code
      // so PostHog can tell otherwise-identical failures apart — audience
      // rejection, authorization_invalid (missing client token), and a
      // disabled Google strategy all share the same call-stack fingerprint and
      // would collapse into one issue without it.
      Tracker.captureException(
        errorToShow,
        t,
        properties: <String, dynamic>{
          'flow': 'oauth_idtoken_signin',
          if (errorToShow.clerkCode != null) 'clerk_code': errorToShow.clerkCode,
        },
      );
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
        // Already captured above — surface the generic message without
        // re-reporting (the previous _showGenericError call here double-counted
        // every server-side sign-in failure in error tracking).
        context.showToast(
          message: 'Something went wrong. Try again later.',
          isError: true,
        );
        setState(() {
          _isLoading = false;
        });
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
                              "assets/plot.svg",
                              width: 240,
                              height: 240 * 252 / 803.735,
                            ),
                          ),
                          if (Base.wasForceSignedOut)
                            FAlert(
                              variant: FAlertVariant.destructive,
                              title: const Text('Your session expired'),
                              subtitle: const Text(
                                'Sign in again to resume syncing and receive notifications.',
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
                                          ' and make progress on what matters.',
                                    ),
                                  ],
                                ),
                              )
                            else
                              Text(
                                "You've been invited to collaborate on Plot.\nSign up or sign in to link your email and make progress on what matters.",
                                textAlign: TextAlign.center,
                                style: context.theme.typography.md,
                              ),
                          ] else
                            Text(
                              'Sign in to make progress on what matters',
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
                              // If Clerk already has a session (a prior
                              // redirect completed, or another tab signed in),
                              // starting another redirect throws "You're
                              // already signed in." Resolve identity and
                              // navigate in instead of erroring.
                              if (Base.auth.isSignedIn) {
                                await _resolveExistingSession();
                                return;
                              }
                              // Don't swap the page for LoadingPage here —
                              // Google's OAuth brand policy expects the flow
                              // from click → consent screen to be direct, and
                              // the AuthButton already shows its own spinner
                              // during the redirect prep. Page state is lost
                              // once the browser navigates to Google anyway.
                              try {
                                await Base.auth.signInWithRedirect(
                                  provider: IdTokenProvider.google,
                                );
                              } on AuthError catch (e, t) {
                                // A session can appear between the check above
                                // and the redirect call (Clerk rejects the
                                // redirect because one already exists). Treat
                                // that as success, not an error.
                                if (_isAlreadySignedIn(e)) {
                                  await _resolveExistingSession();
                                  return;
                                }
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
                            onPress: _isEmailLoading
                                ? null
                                : () async {
                                    setState(() => _isEmailLoading = true);
                                    await context.router.navigate(
                                      EmailSignInRoute(
                                        returnTo: widget.returnTo,
                                      ),
                                    );
                                    if (mounted) {
                                      setState(() => _isEmailLoading = false);
                                    }
                                  },
                            variant: FButtonVariant.secondary,
                            prefix: _isEmailLoading
                                ? Spinner(
                                    color: context.theme.colors.foreground,
                                  )
                                : FaIcon(
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
