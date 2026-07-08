import 'dart:async' show Timer, unawaited;
import 'dart:convert' show jsonDecode;
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' show sha256;

import 'package:flutter/foundation.dart'
    show
        kIsWeb,
        kReleaseMode,
        defaultTargetPlatform,
        TargetPlatform,
        visibleForTesting;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:forui/forui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/env.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/widget/toast.dart';
import 'package:plot/store/store.dart' show AuthUserAction;
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart' show ApiException;
import 'package:plot/api/twist_api.dart' show TwistApi, TwistAuthUrl;
import 'package:plot/analytics/tracker.dart';
import 'package:plot/style/layout.dart';
import 'logging.dart';

export 'package:plot/store/types.dart' show AuthProvider;

typedef OIDCCallback =
    Future<void> Function({
      required String idToken,
      required String? accessToken,
    });

class _AuthUrlResult {
  final String url;
  final String clientId;
  final String state;

  _AuthUrlResult(dynamic json)
    : url = json['url'] as String,
      clientId = json['clientId'] as String,
      state = json['state'] as String;
}

class AuthButton extends StatefulWidget {
  /// Whether native google_sign_in is supported on this platform.
  /// On web, Clerk JS handles all Google auth (One Tap + redirect), so
  /// google_sign_in is not used — initializing both would cause
  /// google.accounts.id.initialize() to be called twice.
  static bool get _useNativeGoogleSignIn =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.android);

  /// Windows can't receive a custom-scheme callback because the runner
  /// doesn't register `plotday://`. Instead the app receives OAuth callbacks
  /// on `http://localhost:<port>` via FlutterWebAuth2's local server mode
  /// (`useWebview: false`). For providers other than Google, we also force
  /// the server to route through `/auth/bridge` so they don't have to accept
  /// loopback redirects directly. Google's Desktop OAuth client accepts
  /// loopback natively, so it skips the bridge.
  static bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static Future<void> init() async {
    if (_useNativeGoogleSignIn) {
      late final String clientId;
      String? serverClientId;
      if (kIsWeb) {
        clientId = Env.googleClientId;
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        clientId = Env.googleAndroidClientId;
        serverClientId = Env.googleClientId;
      } else if (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS) {
        clientId = Env.googleIosClientId;
        serverClientId = Env.googleClientId;
      } else {
        clientId = Env.googleClientId;
      }

      await GoogleSignIn.instance.initialize(
        clientId: clientId,
        serverClientId: serverClientId,
      );
    }
  }

  // Run an OIDC authentication flow for the given provider
  const AuthButton.authenticate({
    required this.provider,
    required OIDCCallback onAuth,
    Future<void> Function()? onRedirectAuth,
    this.autoSignIn = true,
    this.scopes = const [],
    this.onError,
    super.key,
  }) : _link = null,
       _onOIDCAuth = onAuth,
       _onLinkAuth = null,
       // ignore: prefer_initializing_formals
       _onRedirectAuth = onRedirectAuth,
       _twistInstanceId = null,
       _enabledScopeGroups = null,
       _accountHint = null,
       _onSuccess = null,
       keepSpinnerOnSuccess = false;

  // Run an OAuth authorization flow for the given link
  AuthButton.authorize({
    required AuthUserAction link,
    void Function()? onAuth,
    this.onError,
    super.key,
  }) : _link = link,
       provider = link.provider,
       autoSignIn = false,
       _onOIDCAuth = null,
       _onLinkAuth = onAuth,
       _onRedirectAuth = null,
       _twistInstanceId = null,
       _enabledScopeGroups = null,
       _accountHint = null,
       _onSuccess = null,
       keepSpinnerOnSuccess = false,
       scopes = link.scopes;

  // Run an OAuth connect flow for a twist integration. Unlike authorize(),
  // which consumes a pre-issued AuthUserAction, this path requests the auth
  // URL from the twist endpoint so it can pass `enabledScopeGroups` and tie
  // the callback to a specific twist instance.
  const AuthButton.connect({
    required this.provider,
    required this.scopes,
    required String twistInstanceId,
    required Future<void> Function() onSuccess,
    List<String>? enabledScopeGroups,
    String? accountHint,
    this.keepSpinnerOnSuccess = false,
    this.onError,
    super.key,
  }) : _link = null,
       autoSignIn = false,
       _onOIDCAuth = null,
       _onLinkAuth = null,
       _onRedirectAuth = null,
       // ignore: prefer_initializing_formals
       _twistInstanceId = twistInstanceId,
       // ignore: prefer_initializing_formals
       _enabledScopeGroups = enabledScopeGroups,
       // ignore: prefer_initializing_formals
       _accountHint = accountHint,
       // ignore: prefer_initializing_formals
       _onSuccess = onSuccess;

  Future<void> onComplete({
    required String clientId,
    required String redirectUri,
    String? idToken,
    String? accessToken,
    String? code,
    String? state,
  }) async {
    if (_onOIDCAuth != null && idToken != null) {
      await _onOIDCAuth(idToken: idToken, accessToken: accessToken);
    }
    if (_link != null && code != null) {
      final callbackUri = Uri(
        path: '/auth',
        queryParameters: {
          'code': code,
          'clientId': clientId,
          'redirectUri': redirectUri,
          // For Google Sign-In, send auth parameters directly instead of state
          'state': ?state,
          if (state == null) ...{
            'provider': _link.provider.name,
            'scopes': _link.scopes.join(','),
            'callback': _link.callback,
          },
        },
      );
      await api.post<Map<String, dynamic>>(callbackUri.toString());

      _onLinkAuth?.call();
    }
  }

  final AuthProvider provider;
  final bool autoSignIn;
  final OIDCCallback? _onOIDCAuth;
  final void Function()? _onLinkAuth;
  final Future<void> Function()? _onRedirectAuth;
  final List<String> scopes;
  final AuthUserAction? _link;
  final String? _twistInstanceId;
  final List<String>? _enabledScopeGroups;
  final String? _accountHint;
  final Future<void> Function()? _onSuccess;

  /// When true, the button keeps its loading spinner running after a successful
  /// [_onSuccess] instead of clearing it. Used by the initial connect flow,
  /// where [_onSuccess] hands off to a separate setup modal (via
  /// [Modal.popForSwap]) that keeps THIS modal displayed while it loads:
  /// clearing the spinner the instant [_onSuccess] resolves would leave the
  /// button looking idle during that hand-off gap. The button is disposed when
  /// the next modal swaps in, so the spinner never needs re-clearing. Error and
  /// cancel paths still clear it so the user can retry.
  final bool keepSpinnerOnSuccess;

  final void Function(String error)? onError;

  @override
  State<AuthButton> createState() => _AuthButtonState();
}

class _AuthButtonState extends State<AuthButton>
    with WidgetsBindingObserver {
  bool _isLoading = false;

  /// True only when the loading spinner was started by a flow that navigates
  /// the browser away and never returns to the awaiting Dart code (i.e. the
  /// Clerk web-redirect flow). Other flows await the auth session and reset
  /// _isLoading in their own `finally` blocks — clearing it on resume would
  /// drop the spinner while post-OAuth work (e.g. activation) is still running.
  bool _resetLoadingOnResume = false;

  /// Pre-computed nonce so GoogleSignIn is ready when the user taps.
  /// Re-generated after each sign-in attempt.
  String? _pendingNonce;

  @override
  void initState() {
    super.initState();
    // On web, the Google auth flow navigates the browser away and `_isLoading`
    // never resolves in Dart. If the user comes back (browser back, bfcache
    // restore, tab regaining focus), we'd be stuck showing a loading spinner
    // forever. Listen for lifecycle resume events and clear `_isLoading` so
    // the button is usable again.
    WidgetsBinding.instance.addObserver(this);

    if (widget.provider == AuthProvider.google) {
      if (AuthButton._useNativeGoogleSignIn) {
        final GoogleSignIn signIn = GoogleSignIn.instance;

        if (widget.autoSignIn) {
          unawaited(() async {
            final account = await signIn.attemptLightweightAuthentication();
            if (account != null) {
              _onGoogleSignIn(account);
            }
          }());
        }

        // Pre-initialize GoogleSignIn with a nonce so the sign-in prompt
        // appears faster when the user taps the button.
        if (widget._onOIDCAuth != null) {
          _preInitGoogleSignIn();
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _isLoading &&
        _resetLoadingOnResume &&
        mounted) {
      setState(() {
        _isLoading = false;
        _resetLoadingOnResume = false;
      });
    }
  }

  /// Pre-initialize GoogleSignIn with a fresh nonce in the background.
  void _preInitGoogleSignIn() {
    _pendingNonce = _generateNonce();
    unawaited(() async {
      late final String clientId;
      String? serverClientId;
      if (defaultTargetPlatform == TargetPlatform.android) {
        clientId = Env.googleAndroidClientId;
        serverClientId = Env.googleClientId;
      } else if (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS) {
        clientId = Env.googleIosClientId;
        serverClientId = Env.googleClientId;
      } else {
        clientId = Env.googleClientId;
      }
      await GoogleSignIn.instance.initialize(
        clientId: clientId,
        serverClientId: serverClientId,
        nonce: _pendingNonce,
      );
    }());
  }

  Future<void> _onGoogleSignIn(GoogleSignInAccount account) async {
    final googleAuth = account.authentication;
    final idToken = googleAuth.idToken;

    // Merge openid and email scopes so the server auth code includes an
    // id_token with email claim. Android GIS only grants explicitly requested
    // scopes; without these the token exchange returns no id_token and the
    // account shows a UUID instead of the user's email.
    final scopes = {...widget.scopes, 'openid', 'email'}.toList();

    String? accessToken;
    if (widget.scopes.isNotEmpty) {
      final GoogleSignInClientAuthorization authorization = await account
          .authorizationClient
          .authorizeScopes(scopes);
      accessToken = authorization.accessToken;
    }

    String? code;
    if (widget.scopes.isNotEmpty) {
      final GoogleSignInServerAuthorization? serverAuth = await account
          .authorizationClient
          .authorizeServer(scopes);
      code = serverAuth?.serverAuthCode;
    }

    await widget.onComplete(
      clientId: Env.googleClientId,
      redirectUri: Env.authServerCallbackUrl,
      code: code,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  void _startGoogleAuth() async {
    setState(() => _isLoading = true);
    try {
      // Re-initialize GoogleSignIn with a fresh nonce before authenticating.
      // The nonce is embedded in the ID token; without it Clerk can reject
      // the token as "not authorized" (confirmed on Android, preventive on
      // iOS/macOS).
      // If we pre-initialized in initState, skip the re-init to reduce delay.
      if (!kIsWeb && _pendingNonce == null) {
        late final String clientId;
        String? serverClientId;
        if (defaultTargetPlatform == TargetPlatform.android) {
          clientId = Env.googleAndroidClientId;
          serverClientId = Env.googleClientId;
        } else if (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS) {
          clientId = Env.googleIosClientId;
          serverClientId = Env.googleClientId;
        } else {
          clientId = Env.googleClientId;
        }
        await GoogleSignIn.instance.initialize(
          clientId: clientId,
          serverClientId: serverClientId,
          nonce: _generateNonce(),
        );
      }
      // Consume the pre-warmed nonce so the next attempt re-initializes fresh.
      _pendingNonce = null;

      // Always sign out first to force account selection. On Android this
      // routes through CredentialManager.clearCredentialState, which throws
      // when no credential provider is registered for clearing — that's
      // non-fatal for our purposes, so swallow it and continue.
      try {
        await GoogleSignIn.instance.signOut();
      } on PlatformException catch (e) {
        if (e.code != 'Clear Failed') rethrow;
        log.info('Google sign-out skipped', {
          'code': e.code,
          'message': e.message,
        });
      }

      // Authenticate with full account picker
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: widget.scopes,
      );
      await _onGoogleSignIn(account);
    } on GoogleSignInException catch (e, t) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        // In release builds, cancellation can occur if the SHA-1 fingerprint
        // is not registered in Google Cloud Console. Log additional context.
        log.info('Google sign-in cancelled', {
          'code': e.code.toString(),
          'description': e.description,
          'hint': kReleaseMode
              ? 'If this happens immediately after account selection in release builds, '
                    'verify the release keystore SHA-1 is registered in Google Cloud Console'
              : null,
        });
        return;
      }
      if (shouldReportGoogleSignInFailure(e.code)) {
        log.warning('Google sign-in failed', e, t);
        Tracker.captureException(e, t);
      } else {
        // Environmental failure (e.g. providerConfigurationError): the device's
        // auth SDK / Google Play Services is unavailable or has no registered
        // credential provider. The user sees the message below, so don't report
        // it as a bug — it's noise in error tracking.
        log.info('Google sign-in unavailable', {
          'code': e.code.toString(),
          'description': e.description,
        });
      }
      final message = 'Unable to connect with Google. Please try again.';
      if (widget.onError != null) {
        widget.onError!(message);
      } else {
        if (mounted) {
          context.showToast(message: message, isError: true);
        }
      }
      return;
    } catch (e, t) {
      log.warning('Google sign-in failed', e, t);
      Tracker.captureException(e, t);
      final message = 'Unable to connect with Google. Please try again.';
      if (widget.onError != null) {
        widget.onError!(message);
      } else {
        if (mounted) {
          context.showToast(message: message, isError: true);
        }
      }
      return;
    } finally {
      // Pre-initialize for the next attempt so it's fast if they retry.
      if (mounted && widget._onOIDCAuth != null) {
        _preInitGoogleSignIn();
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _startAppleAuth() async {
    setState(() => _isLoading = true);
    try {
      // Generate a cryptographic nonce for Apple Sign In.
      // Clerk requires the identity token to contain a nonce claim.
      final rawNonce = _generateNonce();
      final hashedNonce = sha256.convert(rawNonce.codeUnits).toString();

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
        webAuthenticationOptions: kIsWeb ||
                defaultTargetPlatform == TargetPlatform.android
            ? WebAuthenticationOptions(
                clientId: Env.appleClientId,
                redirectUri: Uri.parse(Env.webAuthCallbackUrl),
              )
            : null,
      );

      await widget.onComplete(
        clientId: Env.appleClientId,
        redirectUri: Env.authCallbackUrl,
        idToken: credential.identityToken,
        code: credential.authorizationCode,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        log.info('Apple sign-in cancelled by user');
        return;
      }
      // Apple auth errors (e.g. error 1000 for missing 2FA, provisioning
      // issues, keychain problems) are external device/account issues, not
      // bugs in our code. Log but don't report to error tracking since the
      // user already sees the error toast.
      log.warning('Apple sign-in failed: ${e.code} - ${e.message}');
      final message = 'Unable to connect with Apple. Please try again.';
      if (widget.onError != null) {
        widget.onError!(message);
      } else {
        if (mounted) {
          context.showToast(message: message, isError: true);
        }
      }
      return;
    } catch (e, t) {
      // The web Sign in with Apple popup can fail without it being a Plot bug:
      // the user closes/dismisses it, the popup is blocked, or Apple's JS SDK
      // is unreachable. The sign_in_with_apple_web plugin surfaces these either
      // as a SignInWithAppleCredentialsException or — when its own
      // `e as SignInErrorI` cast (sign_in_with_apple_web.dart:61) meets a
      // non-JS rejection — as a "not a subtype of type 'JSObject'" TypeError
      // that masks the real cause. The user still sees the retry toast below,
      // but neither should be reported to error tracking.
      if (isAppleWebSignInFailure(e)) {
        log.info('Apple sign-in (web) did not complete: $e');
      } else {
        log.warning('Apple sign-in failed', e, t);
        Tracker.captureException(e, t);
      }
      final message = 'Unable to connect with Apple. Please try again.';
      if (widget.onError != null) {
        widget.onError!(message);
      } else {
        if (mounted) {
          context.showToast(message: message, isError: true);
        }
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _startOAuth() async {
    setState(() => _isLoading = true);

    // On non-web platforms, use the custom URL scheme so FlutterWebAuth2
    // intercepts the callback directly instead of navigating to a web page.
    // Windows is the exception: see [AuthButton._isWindows] for the loopback path.
    final redirectUri = kIsWeb
        ? Env.webAuthCallbackUrl
        : (AuthButton._isWindows ? _desktopCallbackUrl : _appCallbackUrl);

    try {
      final authUrl = await _generateAuthUrl(redirectUri: redirectUri);

      // Keep the spinner on through a short grace period after launching the
      // popup. The popup can lag the authenticate() call by several seconds, and
      // dropping the spinner immediately makes the button look idle while the
      // user is still waiting for the popup to appear. runWithPopupSpinnerGrace
      // drops it after the grace so the button doesn't look stuck for a user who
      // closed/abandoned the popup (on web the call doesn't resolve until the
      // callback arrives or FlutterWebAuth2's ~5-min timeout elapses). Restored
      // below for the token exchange.
      final result = await runWithPopupSpinnerGrace(
        dropSpinner: () {
          if (mounted) setState(() => _isLoading = false);
        },
        authenticate: () => FlutterWebAuth2.authenticate(
          url: authUrl.url,
          callbackUrlScheme: AuthButton._isWindows
              ? _desktopCallbackUrl
              : redirectUri.split(':').first,
          options: AuthButton._isWindows
              ? const FlutterWebAuth2Options(useWebview: false)
              : const FlutterWebAuth2Options(),
        ),
      );

      // Back in the app doing invisible token-exchange work — ensure the
      // spinner is on (the grace timer may have dropped it) and re-guard against
      // a second tap during the tail.
      if (mounted) setState(() => _isLoading = true);

      final responseUri = Uri.parse(result);
      final params = responseUri.queryParameters;

      await widget.onComplete(
        clientId: authUrl.clientId,
        redirectUri: redirectUri,
        code: params['code'],
        state: authUrl.state,
      );
    } catch (e, t) {
      if (isAuthUserCanceled(e)) {
        log.info('OAuth flow cancelled by user (${widget.provider.name})');
        return;
      }
      if (isAuthCallbackTimeout(e)) {
        // The user saw the popup and didn't finish (closed/abandoned it). By
        // now the grace timer has long since cleared the spinner (the web
        // timeout is ~5 min) and the finally clears it again, so just move on
        // quietly — no toast, and not a bug to report.
        log.info(
          'OAuth flow timed out awaiting callback (${widget.provider.name})',
        );
        return;
      }
      log.warning('OAuth flow failed for ${widget.provider.name}', e, t);
      Tracker.captureException(e, t);
      if (mounted) {
        // Create a user-friendly error message based on the provider
        final providerName =
            widget.provider.name[0].toUpperCase() +
            widget.provider.name.substring(1);
        final message =
            'Unable to connect with $providerName. Please try again.';
        if (widget.onError != null) {
          widget.onError!(message);
        } else {
          context.showToast(message: message, isError: true);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<_AuthUrlResult> _generateAuthUrl({String? redirectUri}) async {
    final effectiveRedirectUri = redirectUri ?? Env.authCallbackUrl;

    String? platform;
    if (kIsWeb) {
      platform = null;
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      platform = 'android';
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      platform = 'ios';
    } else if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      platform = 'desktop';
    }

    final link = widget._link!;
    // Windows can't receive a custom-scheme callback; route every provider
    // except Google through the server bridge so the bridge can deep-link to
    // the localhost loopback the FlutterWebAuth2 server is listening on.
    // Google's Desktop client accepts loopback directly, so it skips this.
    final forceBridge =
        AuthButton._isWindows && widget.provider != AuthProvider.google;
    final uri = Uri(
      path: '/auth',
      queryParameters: {
        'provider': link.provider.name,
        'scopes': link.scopes,
        'callback': link.callback,
        'redirectUri': effectiveRedirectUri,
        'platform': ?platform,
        if (forceBridge) 'forceBridge': 'true',
      },
    );

    try {
      final response = await api.get<Map<String, dynamic>>(uri.toString());
      return _AuthUrlResult(response);
    } catch (e, t) {
      log.severe(
        'Failed to generate auth URL from API for ${link.provider.name} (uri: ${uri.toString()})',
        e,
        t,
      );
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = getAuthProviderConfig(widget.provider);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: FButton(
        mainAxisSize: .min,
        onPress: _isLoading ? null : _onPress,
        style: buildAuthButtonStyle(context, config),
        prefix: _isLoading
            ? Spinner(color: config.textColor, size: config.iconSize)
            : _ProviderIcon(provider: widget.provider, size: config.iconSize),
        child: Text(
          config.buttonText,
          style: context.theme.typography.md.copyWith(
            fontWeight: config.fontWeight,
            fontFamily: config.fontFamily,
            color: _isLoading ? config.disabledTextColor : config.textColor,
            height: 1,
          ),
        ),
      ),
    );
  }

  /// Custom URL scheme callback for non-web OAuth flows.
  /// On native platforms, FlutterWebAuth2 intercepts this scheme directly,
  /// avoiding the issue where https:// callbacks load a web page instead of
  /// routing back to the app.
  static const _appCallbackUrl = 'plotday://auth/callback';

  /// Desktop Google flows use a localhost callback with FlutterWebAuth2's
  /// server mode. Custom URL schemes (plotday://) don't work on Windows because
  /// the OS launches a new app instance instead of routing to the existing one.
  /// The desktop OAuth client (used by the connect/authorize flows) accepts
  /// loopback on any port natively; the web client (used by sign-in — see
  /// [_startGoogleAuthDesktop]) must list this exact URL as an authorized
  /// redirect URI in the Google Cloud console.
  static const _desktopCallbackPort = 23522;
  static const _desktopCallbackUrl = 'http://localhost:$_desktopCallbackPort';

  void _startGoogleAuthDesktop() async {
    setState(() => _isLoading = true);
    try {
      // Use the server to generate the auth URL with state + PKCE.
      // This is an unauthenticated call (user hasn't signed in yet),
      // so use http.get directly instead of api.get which attaches a Bearer token.
      //
      // Deliberately omit `platform: 'desktop'` so the server uses the base
      // web Google client (AUTH_GOOGLE_ID) rather than the desktop client
      // (AUTH_GOOGLE_DESKTOP_ID). The resulting id_token must be `aud`-ienced
      // to a Google client that Clerk trusts: Clerk's `idTokenSignIn`
      // (google_one_tap strategy) validates the token's audience against the
      // single web client configured in the Clerk dashboard. A desktop-client
      // token is rejected as "The provided Google One Tap token is invalid",
      // which is why this Windows sign-in path failed while macOS/iOS/Android
      // (google_sign_in's `serverClientId` = web client) and web (Clerk JS)
      // succeed. The web client must list http://localhost:$_desktopCallbackPort
      // as an authorized redirect URI. The connect/authorize flows
      // (_startOAuth / _startTwistAuth) still use the desktop client — they
      // fetch Google API tokens and never go through Clerk.
      final authUrlRequest = Uri.parse('${Env.apiRoot}/auth').replace(
        queryParameters: {
          'provider': 'google',
          'scopes': ['openid', 'profile', 'email'],
          'redirectUri': _desktopCallbackUrl,
        },
      );
      final authUrlResponse = await http.get(authUrlRequest);
      if (authUrlResponse.statusCode != 200) {
        throw Exception(
          'Failed to generate auth URL (${authUrlResponse.statusCode}): ${authUrlResponse.body}',
        );
      }
      final authData =
          jsonDecode(authUrlResponse.body) as Map<String, dynamic>;
      final authUrl = authData['url'] as String;
      final clientId = authData['clientId'] as String;
      final state = authData['state'] as String;

      final result = await FlutterWebAuth2.authenticate(
        url: authUrl,
        callbackUrlScheme: _desktopCallbackUrl,
        options: const FlutterWebAuth2Options(useWebview: false),
      );

      final responseUri = Uri.parse(result);
      // Google redirects back to the loopback with `?error=...` when consent
      // fails (e.g. `access_denied` if the user declines). A redirect-URI
      // mismatch, by contrast, never reaches this callback at all — Google
      // shows its own error page and the loopback server times out (surfaced
      // as a cancel in the catch below).
      final oauthError = responseUri.queryParameters['error'];
      if (oauthError != null) {
        if (oauthError == 'access_denied') {
          log.info('Google sign-in (desktop) declined by user');
          return;
        }
        throw Exception('Google returned an OAuth error: $oauthError');
      }
      final code = responseUri.queryParameters['code'];
      if (code == null) {
        throw Exception('No authorization code received from Google');
      }

      // POST code + state to API for server-side token exchange with PKCE
      final uri = Uri.parse('${Env.apiRoot}/auth').replace(
        queryParameters: {
          'code': code,
          'clientId': clientId,
          'redirectUri': _desktopCallbackUrl,
          'state': state,
        },
      );
      final tokenResponse = await http.post(uri);

      if (tokenResponse.statusCode != 200) {
        throw Exception(
          'Token exchange failed (${tokenResponse.statusCode}): ${tokenResponse.body}',
        );
      }

      final tokens = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      final idToken = tokens['id_token'] as String?;
      if (idToken == null) {
        throw Exception('No id_token in token response');
      }

      await widget.onComplete(
        clientId: clientId,
        redirectUri: _desktopCallbackUrl,
        idToken: idToken,
        accessToken: tokens['access_token'] as String?,
      );
    } catch (e, t) {
      if (isAuthUserCanceled(e) || isAuthCallbackTimeout(e)) {
        // On Windows/Linux, flutter_web_auth_2's loopback server throws
        // CANCELED both when the user dismisses the browser AND when no
        // callback arrives before the timeout — the two are indistinguishable
        // here (see flutter_web_auth_2 server.dart). A missing callback most
        // often means a redirect_uri_mismatch (the web Google client must list
        // http://localhost:$_desktopCallbackPort as an authorized redirect URI)
        // or localhost being blocked; both surface in the browser, so don't
        // report them as bugs. Emit a breadcrumb so a field-wide spike in
        // never-completed desktop sign-ins (e.g. a redirect-URI regression)
        // stays visible without polluting error tracking.
        log.info('Google sign-in (desktop) did not complete (cancel/timeout)');
        Tracker.track('google_signin_desktop_incomplete');
      } else {
        // Surfaces the steps that only run on Windows/Linux — auth-URL
        // generation, the browser OAuth round-trip, and the server-side token
        // exchange — where there's no debugger and stdout is invisible in a
        // release build, so PostHog is the only channel. The thrown messages
        // embed the failing step and HTTP status/body. (The Clerk
        // signInWithIdToken leg lives in onComplete, which handles its own
        // errors and never rethrows here, so this won't double-report it.)
        log.warning('Google sign-in failed (desktop)', e, t);
        Tracker.captureException(
          e,
          t,
          properties: const <String, dynamic>{'flow': 'google_signin_desktop'},
        );
        final message = 'Unable to connect with Google. Please try again.';
        if (widget.onError != null) {
          widget.onError!(message);
        } else if (mounted) {
          context.showToast(message: message, isError: true);
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onPress() {
    if (_isLoading) return;
    if (widget._twistInstanceId != null) {
      _startTwistAuth();
      return;
    }
    if (widget.provider == AuthProvider.google) {
      if (kIsWeb) {
        // On web, Clerk JS handles all Google auth. Use backend OAuth for
        // authorize flows, or Clerk's redirect for authentication.
        if (widget._link != null) {
          _startOAuth();
        } else if (widget._onRedirectAuth != null) {
          setState(() {
            _isLoading = true;
            _resetLoadingOnResume = true;
          });
          widget._onRedirectAuth!();
        } else {
          _startOAuth();
        }
      } else if (!AuthButton._useNativeGoogleSignIn) {
        // On Windows/Linux, use browser-based OAuth for authorize flows,
        // or the all-platforms sign-in for authentication
        if (widget._link != null) {
          _startOAuth();
        } else {
          _startGoogleAuthDesktop();
        }
      } else {
        _startGoogleAuth();
      }
    } else if (widget.provider == AuthProvider.apple) {
      _startAppleAuth();
    } else {
      _startOAuth();
    }
  }

  /// Connect a twist integration. Asks the twist endpoint for an auth URL
  /// (which applies per-integration scope groups), runs the platform-
  /// appropriate OAuth flow, posts the code back to /auth, and then calls
  /// [AuthButton._onSuccess].
  bool get _useNativeGoogleSignInForTwist =>
      !kIsWeb &&
      widget.provider == AuthProvider.google &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<void> _startTwistAuth() async {
    setState(() => _isLoading = true);

    final redirectUri = kIsWeb
        ? Env.webAuthCallbackUrl
        : (AuthButton._isWindows ? _desktopCallbackUrl : _appCallbackUrl);
    // See _generateAuthUrl: Google's Desktop client accepts the loopback
    // directly, so skip the server bridge for it.
    final forceBridge =
        AuthButton._isWindows && widget.provider != AuthProvider.google;

    String? platform;
    if (!kIsWeb) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        platform = 'android';
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        platform = 'ios';
      } else {
        platform = 'desktop';
      }
    }

    // When the caller hands off to another modal on success (see
    // [AuthButton.keepSpinnerOnSuccess]), keep the spinner on past [_onSuccess]
    // so the button doesn't look idle during the hand-off gap. Set only after
    // [_onSuccess] resolves without throwing — error/cancel paths leave it
    // false so the finally clears the spinner and the user can retry.
    var keepSpinning = false;
    try {
      final authUrl = await TwistApi.getAuthUrl(
        twistInstanceId: widget._twistInstanceId!,
        provider: widget.provider.name,
        redirectUri: redirectUri,
        platform: platform,
        forceBridge: forceBridge,
        enabledScopeGroups: widget._enabledScopeGroups,
        accountHint: widget._accountHint,
      );

      if (_useNativeGoogleSignInForTwist) {
        await _startTwistNativeGoogle(authUrl);
      } else {
        final completed = await _startTwistBrowser(authUrl, redirectUri);
        // User cancelled or the provider returned an error. When there's
        // a message worth showing, _startTwistBrowser already popped the
        // toast — skip the success path so the caller doesn't advance.
        if (!completed) return;
      }

      // Keep the button's spinner on through the activation step the caller
      // performs here; otherwise the modal redisplays a clickable auth button
      // during the tail-end network work and users can trigger a second flow.
      await widget._onSuccess?.call();
      keepSpinning = widget.keepSpinnerOnSuccess;
    } on GoogleSignInException catch (e, t) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        log.info('Google sign-in cancelled');
        return;
      }
      log.warning('OAuth flow failed for ${widget.provider.name}', e, t);
      // Only report codes that point at a real, fixable defect (a misconfigured
      // client/provider). The rest — unknownError (native SDK hiccups such as
      // Android GIS code 8 INTERNAL_ERROR), interrupted, uiUnavailable, and
      // userMismatch — are transient or user-driven failures the user already
      // sees via the toast below, so capturing them only adds noise to error
      // tracking.
      if (e.code == GoogleSignInExceptionCode.clientConfigurationError ||
          e.code == GoogleSignInExceptionCode.providerConfigurationError) {
        Tracker.captureException(e, t);
      }
      if (mounted) _showTwistAuthError();
    } on ApiException catch (e, t) {
      // Surface server-provided messages for client errors (e.g. 409 when the
      // account is already linked to another Plot user). 5xx descriptions may
      // contain internal details, so fall back to the generic message there.
      log.warning('OAuth flow failed for ${widget.provider.name}', e, t);
      if (e.statusCode >= 500) Tracker.captureException(e, t);
      if (mounted) {
        final serverMessage = e.statusCode >= 400 && e.statusCode < 500
            ? e.description.trim()
            : '';
        _showTwistAuthError(
          message: serverMessage.isEmpty ? null : serverMessage,
        );
      }
    } catch (e, t) {
      if (isAuthUserCanceled(e)) {
        log.info('OAuth flow cancelled by user (${widget.provider.name})');
        return;
      }
      if (isAuthCallbackTimeout(e)) {
        // The user saw the popup and didn't finish (closed/abandoned it). By
        // now the grace timer has long since cleared the spinner (the web
        // timeout is ~5 min) and the finally clears it again, so just move on
        // quietly — no toast, and not a bug to report.
        log.info(
          'OAuth flow timed out awaiting callback (${widget.provider.name})',
        );
        return;
      }
      log.warning('OAuth flow failed for ${widget.provider.name}', e, t);
      Tracker.captureException(e, t);
      if (mounted) _showTwistAuthError();
    } finally {
      if (mounted && !keepSpinning) setState(() => _isLoading = false);
    }
  }

  Future<void> _startTwistNativeGoogle(TwistAuthUrl authUrl) async {
    // Request the scopes the server resolved from the enabled scope groups, not
    // the connector's static [widget.scopes]. For combined connectors the
    // required scopes are empty and the products live in optional scope groups,
    // so [widget.scopes] alone would drop every product scope (e.g. Tasks)
    // from the native consent screen. The browser flow already uses the
    // server-built URL; this keeps native consistent. Fall back to
    // [widget.scopes] only if an older server omitted the resolved list.
    final resolved =
        authUrl.scopes.isNotEmpty ? authUrl.scopes : widget.scopes;
    // Merge openid and email scopes so the server auth code includes an
    // id_token with email claim. Android GIS only grants explicitly requested
    // scopes; without these the token exchange returns no id_token and the
    // account shows a UUID instead of the user's email.
    final scopes = {...resolved, 'openid', 'email'}.toList();

    await GoogleSignIn.instance.signOut();

    final GoogleSignInServerAuthorization? serverAuth;
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      // On Apple platforms, authorizeServer on the instance-level client
      // (null userId) triggers combined sign-in + authorization: one prompt
      // with account picker + consent + server auth code.
      serverAuth = await GoogleSignIn.instance.authorizationClient
          .authorizeServer(scopes);
    } else {
      // On Android, GIS separates authentication from authorization.
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: scopes,
      );
      serverAuth = await account.authorizationClient.authorizeServer(scopes);
    }
    final code = serverAuth?.serverAuthCode;
    if (code == null) {
      throw Exception('No server auth code received from Google');
    }

    final callbackUri = Uri(
      path: '/auth',
      queryParameters: {
        'code': code,
        'clientId': Env.googleClientId,
        'redirectUri': Env.authServerCallbackUrl,
        'provider': 'google',
        'scopes': scopes.join(','),
        'callback': authUrl.callback,
      },
    );
    await api.post<Map<String, dynamic>>(callbackUri.toString());
  }

  /// Returns true when the OAuth flow completed successfully. Returns false
  /// when the user cancelled or the provider redirected back with an error
  /// (e.g. Slack's workspace install gate, or Google granular-consent where
  /// the user unchecked a required permission). For Slack the bridge page
  /// stays visible so the user reads the message there; for everything
  /// else the bridge auto-redirects and the user only sees the flash, so
  /// we re-surface the error as a toast in the app.
  ///
  /// Two success shapes are possible: bridge flows (requiresHttpsRedirect
  /// providers like Slack) return `?state=…&success=1` because the API
  /// already completed the token exchange server-side before rendering the
  /// bridge page, so there's no `code` for us to POST. Non-bridge flows
  /// return `?code=…&state=…` and we POST the code here.
  Future<bool> _startTwistBrowser(
    TwistAuthUrl authUrl,
    String redirectUri,
  ) async {
    // Keep the button spinner on through a short grace period after launching
    // the popup. The popup can lag the authenticate() call by several seconds
    // (notably LinkedIn/Unipile hosted auth), and dropping the spinner the
    // instant we call authenticate() makes the button look idle while the user
    // is still waiting for the popup to appear. runWithPopupSpinnerGrace drops
    // it after the grace so the button doesn't look stuck for a user who
    // closed/abandoned the popup (on web the call doesn't resolve until the
    // callback arrives or FlutterWebAuth2's ~5-min timeout elapses). Restored
    // below once we're back doing invisible work (token exchange + the caller's
    // activation step).
    final result = await runWithPopupSpinnerGrace(
      dropSpinner: () {
        if (mounted) setState(() => _isLoading = false);
      },
      authenticate: () => FlutterWebAuth2.authenticate(
        url: authUrl.url,
        callbackUrlScheme: AuthButton._isWindows
            ? _desktopCallbackUrl
            : redirectUri.split(':').first,
        options: AuthButton._isWindows
            ? const FlutterWebAuth2Options(useWebview: false)
            : const FlutterWebAuth2Options(),
      ),
    );

    final responseUri = Uri.parse(result);
    final params = responseUri.queryParameters;
    if (params['error'] != null) {
      // Drop the spinner so the user can read the error toast and retry (the
      // grace timer may not have fired yet if the error came back quickly).
      if (mounted) setState(() => _isLoading = false);
      final errorParam = params['error']!.trim();
      if (mounted) {
        _showTwistAuthError(
          message: errorParam.isEmpty ? null : errorParam,
        );
      }
      return false;
    }

    // Success (code exchange or bridge `success=1`) — ensure the spinner is on
    // (the grace timer may have dropped it) for the token exchange and the
    // caller's [AuthButton._onSuccess] activation.
    if (mounted) setState(() => _isLoading = true);

    final code = params['code'];
    if (code != null) {
      final callbackUri = Uri(
        path: '/auth',
        queryParameters: {
          'code': code,
          'clientId': authUrl.clientId,
          'redirectUri': redirectUri,
          'state': authUrl.state,
        },
      );
      await api.post<Map<String, dynamic>>(callbackUri.toString());
    }
    return true;
  }

  void _showTwistAuthError({String? message}) {
    final providerName =
        widget.provider.name[0].toUpperCase() +
        widget.provider.name.substring(1);
    final finalMessage =
        message ?? 'Unable to connect with $providerName. Please try again.';
    if (widget.onError != null) {
      widget.onError!(finalMessage);
    } else {
      context.showToast(message: finalMessage, isError: true);
    }
  }

  /// Generate a random nonce string for Apple Sign In.
  static String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }
}

/// True when [e] is a user-cancellation of the OAuth web view. On native
/// platforms FlutterWebAuth2 throws `PlatformException('CANCELED', …)` when the
/// user dismisses the browser/sheet. Not a bug — don't report it.
bool isAuthUserCanceled(Object e) =>
    e is PlatformException && e.code == 'CANCELED';

/// True when the web OAuth flow ended because the popup never returned a
/// callback before FlutterWebAuth2's poll timeout — i.e. the user closed or
/// abandoned the popup (the web equivalent of cancelling), or the callback
/// handshake never completed. flutter_web_auth_2's web implementation throws
/// `PlatformException('error', 'Timeout waiting for callback value')` in this
/// case (see flutter_web_auth_2 `src/web.dart`). Expected and user-recoverable,
/// so the caller surfaces a retry toast but must NOT report it to error
/// tracking. Matched on the exact message so genuine provider/runtime errors
/// (which also use code `error`) are still reported.
bool isAuthCallbackTimeout(Object e) =>
    e is PlatformException &&
    e.code == 'error' &&
    e.message == 'Timeout waiting for callback value';

/// True when a web Sign in with Apple attempt failed for a user-recoverable or
/// environmental reason rather than a bug in Plot — the user closing/dismissing
/// the popup, a blocked popup, or Apple's JS SDK being unreachable.
///
/// The `sign_in_with_apple_web` plugin reports a failed sign-in by casting
/// Apple's JS rejection inside its own error handler (`e as SignInErrorI`,
/// sign_in_with_apple_web.dart:61, where `SignInErrorI` is an extension type
/// implementing `JSObject`). Two shapes reach us, neither a Plot bug:
///  * a [SignInWithAppleCredentialsException] — the rejection was a JS object
///    (e.g. the user closed the popup → `popup_closed_by_user`), so the plugin
///    wrapped it as intended; and
///  * a `type '…' is not a subtype of type 'JSObject'` [TypeError] — the
///    rejection was not a JS object (popup blocked, `AppleID.auth` unreachable),
///    so the plugin's own cast crashed and masked the real cause.
///
/// Both surface a retry toast to the user; neither should be captured to error
/// tracking (PostHog issue 019f43c5, "type '…' is not a subtype of type
/// 'JSObject'"), matching how Google cancellations and native Apple
/// cancellations are already treated.
@visibleForTesting
bool isAppleWebSignInFailure(Object e) =>
    e is SignInWithAppleCredentialsException ||
    (e is TypeError && isAppleWebInteropCastFailure(e.toString()));

/// Matches the `sign_in_with_apple_web` interop cast crash by its error message
/// (see [isAppleWebSignInFailure]). Concrete type names are minified in release
/// web builds (e.g. `minified:ahF`), but the `'JSObject'` target type stays
/// literal, so the invariant tail of the message is the reliable signal.
@visibleForTesting
bool isAppleWebInteropCastFailure(String errorMessage) =>
    errorMessage.contains("not a subtype of type 'JSObject'");

/// How long the auth button keeps its spinner running after launching the
/// OAuth popup. The popup can take several seconds to actually appear (notably
/// LinkedIn/Unipile hosted auth), and FlutterWebAuth2 exposes no "popup is
/// visible" signal, so the spinner stands in for "still launching" until this
/// elapses. See [runWithPopupSpinnerGrace].
const Duration _authPopupSpinnerGrace = Duration(seconds: 5);

/// Runs [authenticate] (the OAuth popup) while keeping the button spinner on
/// for a grace period, then calling [dropSpinner].
///
/// Dropping the spinner the instant we call authenticate() makes the button
/// look idle while the user is still waiting for the popup to appear — the
/// popup can lag the call by several seconds (notably LinkedIn/Unipile hosted
/// auth) and there's no reliable signal for when it becomes visible. We instead
/// keep the spinner on until [grace] elapses (a proxy for "the popup should be
/// up by now"), then call [dropSpinner] — so the button doesn't look stuck for
/// a user who closed/abandoned the popup (on web authenticate() won't resolve
/// until the callback arrives or its ~5-min timeout fires).
///
/// The grace timer is cancelled as soon as [authenticate] settles, so a fast
/// or cancelled flow never drops the spinner mid-work — keeping it on a little
/// longer than the popup needs is harmless (the popup is the user's focus by
/// then). Returns the [authenticate] result and rethrows its errors.
@visibleForTesting
Future<T> runWithPopupSpinnerGrace<T>({
  required Future<T> Function() authenticate,
  required void Function() dropSpinner,
  Duration grace = _authPopupSpinnerGrace,
}) async {
  final timer = Timer(grace, dropSpinner);
  try {
    return await authenticate();
  } finally {
    timer.cancel();
  }
}

/// Whether a [GoogleSignInException] with this code should be reported to error
/// tracking.
///
/// Some sign-in failures are environmental or user-driven conditions on the
/// device, not bugs in Plot. The user is already shown an error, so capturing
/// these just adds noise:
///
/// - [GoogleSignInExceptionCode.canceled]: the user dismissed the picker.
/// - [GoogleSignInExceptionCode.providerConfigurationError]: the device's
///   underlying auth SDK (Google Play Services / the Android Credential
///   Manager) is unavailable or has no registered credential provider. Seen in
///   the wild on Android as "getCredentialAsync no provider dependencies
///   found".
///
/// All other codes (e.g. [GoogleSignInExceptionCode.clientConfigurationError],
/// which signals an app-side misconfiguration) are genuine bugs worth
/// reporting.
@visibleForTesting
bool shouldReportGoogleSignInFailure(GoogleSignInExceptionCode code) =>
    code != GoogleSignInExceptionCode.canceled &&
    code != GoogleSignInExceptionCode.providerConfigurationError;

FButtonStyle buildAuthButtonStyle(
  BuildContext context,
  AuthProviderConfig config,
) {
  final baseTextStyle = context.theme.typography.md.copyWith(
    fontWeight: config.fontWeight,
    fontFamily: config.fontFamily,
    height: 1,
  );
  final baseIconStyle = IconThemeData(size: config.iconSize);
  final baseProgressStyle = FCircularProgressStyle(
    iconStyle: baseIconStyle,
  );

  return FButtonStyle(
    decoration: FVariants(
      BoxDecoration(
        color: config.backgroundColor,
        border: Border.all(color: config.borderColor, width: 1),
        borderRadius: tileBorderRadius,
      ),
      variants: {
        [FTappableVariantConstraint.hovered]: BoxDecoration(
          color: Color.lerp(config.backgroundColor, config.textColor, 0.07)!,
          border: Border.all(color: config.borderColor, width: 1),
          borderRadius: tileBorderRadius,
        ),
        [FTappableVariantConstraint.focused]: BoxDecoration(
          color: config.backgroundColor,
          border: Border.all(color: config.focusColor, width: 1),
          borderRadius: tileBorderRadius,
        ),
        [FTappableVariantConstraint.disabled]: BoxDecoration(
          color: config.backgroundColor,
          border: Border.all(color: config.borderColor, width: 1),
          borderRadius: tileBorderRadius,
        ),
      },
    ),
    contentStyle: FButtonContentStyle(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      textStyle: FVariants(baseTextStyle, variants: {
        [FTappableVariantConstraint.disabled]: baseTextStyle,
      }),
      iconStyle: FVariants(baseIconStyle, variants: {
        [FTappableVariantConstraint.disabled]: baseIconStyle,
      }),
      circularProgressStyle: FVariants(baseProgressStyle, variants: {
        [FTappableVariantConstraint.disabled]: baseProgressStyle,
      }),
    ),
    iconContentStyle: FButtonIconContentStyle(
      iconStyle: FVariants(baseIconStyle, variants: {}),
    ),
    focusedOutlineStyle: FFocusedOutlineStyle(
      borderRadius: tileBorderRadius,
      color: config.focusColor,
    ),
    tappableStyle: FTappableStyle(),
  );
}

AuthProviderConfig getAuthProviderConfig(AuthProvider provider) {
  const iconSize = 18.0;
  const spacing = 12.0;
  const fontSize = 14.0;
  const fontWeight = FontWeight.w500;
  const horizontalPadding = 12.0;

  switch (provider) {
    case AuthProvider.google:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF1F1F1F),
        borderColor: const Color(0xFF747775),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFF8F9FA),
        focusColor: const Color(0xFF4285F4),
        loadingColor: const Color(0xFF4285F4),
        disabledTextColor: const Color(0xFF9AA0A6),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'Roboto',
        buttonText: 'Continue with Google',
      );

    case AuthProvider.microsoft:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF5E5E5E),
        borderColor: const Color(0xFF8C8C8C),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFF3F2F1),
        focusColor: const Color(0xFF0078D4),
        loadingColor: const Color(0xFF0078D4),
        disabledTextColor: const Color(0xFFA19F9D),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        fontFamily: 'Segoe UI',
        buttonText: 'Continue with Microsoft',
      );

    case AuthProvider.slack:
      return AuthProviderConfig(
        backgroundColor: const Color(0xFF4A154B),
        textColor: Colors.white,
        borderColor: const Color(0xFF4A154B),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFF611F69),
        focusColor: const Color(0xFF611F69),
        loadingColor: Colors.white,
        disabledTextColor: const Color(0xFFB8A5BA),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'Lato',
        buttonText: 'Continue with Slack',
      );

    case AuthProvider.apple:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: Colors.black,
        borderColor: const Color(0xFFDADBDD),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFF1D1D1F),
        focusColor: const Color(0xFF0071E3),
        loadingColor: Colors.white,
        disabledTextColor: const Color(0xFF86868B),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        fontFamily: 'SF Pro Text',
        buttonText: 'Continue with Apple',
      );

    case AuthProvider.github:
      return AuthProviderConfig(
        backgroundColor: const Color(0xFF24292E),
        textColor: Colors.white,
        borderColor: const Color(0xFF24292E),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFF2F363D),
        focusColor: const Color(0xFF0366D6),
        loadingColor: Colors.white,
        disabledTextColor: const Color(0xFF959DA5),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with GitHub',
      );

    case AuthProvider.discord:
      return AuthProviderConfig(
        backgroundColor: const Color(0xFF5865F2),
        textColor: Colors.white,
        borderColor: const Color(0xFF5865F2),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFF4752C4),
        focusColor: const Color(0xFF4752C4),
        loadingColor: Colors.white,
        disabledTextColor: const Color(0xFFB5BAF2),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Discord',
      );

    case AuthProvider.notion:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: Colors.black,
        borderColor: const Color(0xFFDADBDD),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFF7F6F3),
        focusColor: const Color(0xFF000000),
        loadingColor: const Color(0xFF000000),
        disabledTextColor: const Color(0xFF9AA0A6),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Notion',
      );

    case AuthProvider.atlassian:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF172B4D),
        borderColor: const Color(0xFFDFE1E6),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFF4F5F7),
        focusColor: const Color(0xFF0052CC),
        loadingColor: const Color(0xFF0052CC),
        disabledTextColor: const Color(0xFF8993A4),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Atlassian',
      );

    case AuthProvider.linear:
      return AuthProviderConfig(
        backgroundColor: const Color(0xFF5E6AD2),
        textColor: Colors.white,
        borderColor: const Color(0xFF5E6AD2),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFF505AC0),
        focusColor: const Color(0xFF505AC0),
        loadingColor: Colors.white,
        disabledTextColor: const Color(0xFFB5B9E8),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Linear',
      );

    case AuthProvider.monday:
      return AuthProviderConfig(
        backgroundColor: const Color(0xFFFF3D57),
        textColor: Colors.white,
        borderColor: const Color(0xFFFF3D57),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFE63549),
        focusColor: const Color(0xFFE63549),
        loadingColor: Colors.white,
        disabledTextColor: const Color(0xFFFFB5BF),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Monday',
      );

    case AuthProvider.asana:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF151B26),
        borderColor: const Color(0xFFE8ECEE),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFFCF1F0),
        focusColor: const Color(0xFFF95353),
        loadingColor: const Color(0xFFF95353),
        disabledTextColor: const Color(0xFF9CA6AF),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Asana',
      );

    case AuthProvider.hubspot:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF33475B),
        borderColor: const Color(0xFFCBD6E2),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFF5F8FA),
        focusColor: const Color(0xFFFF7A59),
        loadingColor: const Color(0xFFFF7A59),
        disabledTextColor: const Color(0xFF99ACC2),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with HubSpot',
      );

    case AuthProvider.todoist:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF202020),
        borderColor: const Color(0xFFE2E5EA),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFFCF1F0),
        focusColor: const Color(0xFFE44332),
        loadingColor: const Color(0xFFE44332),
        disabledTextColor: const Color(0xFF9AA4B2),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Todoist',
      );

    case AuthProvider.airtable:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF1D1F25),
        borderColor: const Color(0xFFE2E5EA),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFF5F8FB),
        focusColor: const Color(0xFF18BFFF),
        loadingColor: const Color(0xFF18BFFF),
        disabledTextColor: const Color(0xFF9AA4B2),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Airtable',
      );

    case AuthProvider.linkedin:
      return AuthProviderConfig(
        backgroundColor: const Color(0xFF0A66C2),
        textColor: Colors.white,
        borderColor: const Color(0xFF0A66C2),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFF0959AC),
        focusColor: const Color(0xFF0959AC),
        loadingColor: Colors.white,
        disabledTextColor: const Color(0xFFB6CFE7),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with LinkedIn',
      );

    case AuthProvider.whatsapp:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF111B21),
        borderColor: const Color(0xFFDADBDD),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFF6FBF7),
        focusColor: const Color(0xFF25D366),
        loadingColor: const Color(0xFF25D366),
        disabledTextColor: const Color(0xFF8696A0),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with WhatsApp',
      );

    case AuthProvider.instagram:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF1F1F1F),
        borderColor: const Color(0xFFDADBDD),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFFBF6F9),
        focusColor: const Color(0xFFE4405F),
        loadingColor: const Color(0xFFE4405F),
        disabledTextColor: const Color(0xFF9AA0A6),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'system-ui',
        buttonText: 'Continue with Instagram',
      );

    default:
      return AuthProviderConfig(
        backgroundColor: Colors.white,
        textColor: const Color(0xFF3C4043),
        borderColor: const Color(0xFFDADBDD),
        horizontalPadding: horizontalPadding,
        hoverColor: const Color(0xFFF8F9FA),
        focusColor: const Color(0xFF4285F4),
        loadingColor: const Color(0xFF4285F4),
        disabledTextColor: const Color(0xFF9AA0A6),
        iconSize: iconSize,
        spacing: spacing,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: 'Roboto',
        buttonText:
            'Continue with ${provider.name[0].toUpperCase()}${provider.name.substring(1)}',
      );
  }
}

class AuthProviderConfig {
  final Color backgroundColor;
  final Color textColor;
  final Color borderColor;
  final double horizontalPadding;
  final Color hoverColor;
  final Color focusColor;
  final Color loadingColor;
  final Color disabledTextColor;
  final double iconSize;
  final double spacing;
  final double fontSize;
  final FontWeight fontWeight;
  final String fontFamily;
  final String buttonText;

  const AuthProviderConfig({
    required this.backgroundColor,
    required this.textColor,
    required this.borderColor,
    required this.horizontalPadding,
    required this.hoverColor,
    required this.focusColor,
    required this.loadingColor,
    required this.disabledTextColor,
    required this.iconSize,
    required this.spacing,
    required this.fontSize,
    required this.fontWeight,
    required this.fontFamily,
    required this.buttonText,
  });
}

String? authProviderIconAsset(AuthProvider provider) {
  switch (provider) {
    case AuthProvider.google:
      return "assets/google.svg";
    case AuthProvider.microsoft:
      return "assets/microsoft.svg";
    case AuthProvider.slack:
      return "assets/slack.svg";
    case AuthProvider.apple:
      return "assets/apple.svg";
    case AuthProvider.github:
      return "assets/github_dark.svg";
    case AuthProvider.discord:
      return "assets/discord.svg";
    case AuthProvider.notion:
      return "assets/notion.svg";
    case AuthProvider.atlassian:
      return "assets/atlassian.svg";
    case AuthProvider.linear:
      return "assets/linear.svg";
    case AuthProvider.monday:
      return "assets/monday.svg";
    case AuthProvider.asana:
      return "assets/asana.svg";
    case AuthProvider.hubspot:
      return "assets/hubspot.svg";
    case AuthProvider.todoist:
      return "assets/todoist.svg";
    case AuthProvider.airtable:
      return "assets/airtable.svg";
    case AuthProvider.linkedin:
      return "assets/linkedin.svg";
    case AuthProvider.whatsapp:
      return "assets/whatsapp.svg";
    case AuthProvider.instagram:
      return "assets/instagram.svg";
    default:
      return null;
  }
}

Widget buildAuthProviderIcon(AuthProvider provider, double size) {
  final icon = authProviderIconAsset(provider);
  if (icon == null) {
    return SizedBox(width: size, height: size);
  }
  return SizedBox(
    width: size,
    height: size,
    child: Center(
      child: SvgPicture.asset(icon, width: size, height: size),
    ),
  );
}

class _ProviderIcon extends StatelessWidget {
  final AuthProvider provider;
  final double size;

  const _ProviderIcon({required this.provider, required this.size});

  @override
  Widget build(BuildContext context) {
    if (authProviderIconAsset(provider) == null) {
      return const SizedBox.shrink();
    }
    return buildAuthProviderIcon(provider, size);
  }
}
