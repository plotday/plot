import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode;
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' show sha256;

import 'package:flutter/foundation.dart'
    show kIsWeb, kReleaseMode, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' show Colors;
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
       _onRedirectAuth = onRedirectAuth,
       _twistInstanceId = null,
       _enabledScopeGroups = null,
       _onSuccess = null;

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
       _onSuccess = null,
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
    this.onError,
    super.key,
  }) : _link = null,
       autoSignIn = false,
       _onOIDCAuth = null,
       _onLinkAuth = null,
       _onRedirectAuth = null,
       _twistInstanceId = twistInstanceId,
       _enabledScopeGroups = enabledScopeGroups,
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
          if (state != null) 'state': state,
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
  final Future<void> Function()? _onSuccess;
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

      // Always sign out first to force account selection
      await GoogleSignIn.instance.signOut();

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
      log.warning('Apple sign-in failed', e, t);
      Tracker.captureException(e, t);
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
    final redirectUri = kIsWeb ? Env.webAuthCallbackUrl : _appCallbackUrl;

    try {
      final authUrl = await _generateAuthUrl(redirectUri: redirectUri);

      final result = await FlutterWebAuth2.authenticate(
        url: authUrl.url,
        callbackUrlScheme: redirectUri.split(':').first,
      );

      final responseUri = Uri.parse(result);
      final params = responseUri.queryParameters;

      await widget.onComplete(
        clientId: authUrl.clientId,
        redirectUri: redirectUri,
        code: params['code'],
        state: authUrl.state,
      );
    } catch (e, t) {
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
    final uri = Uri(
      path: '/auth',
      queryParameters: {
        'provider': link.provider.name,
        'scopes': link.scopes,
        'callback': link.callback,
        'redirectUri': effectiveRedirectUri,
        if (platform != null) 'platform': platform,
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

  /// Desktop Google sign-in uses a localhost callback with FlutterWebAuth2's
  /// server mode. Custom URL schemes (plotday://) don't work on Windows because
  /// the OS launches a new app instance instead of routing to the existing one.
  /// Google allows http://localhost with any port for desktop OAuth clients.
  static const _desktopCallbackPort = 23522;
  static const _desktopCallbackUrl = 'http://localhost:$_desktopCallbackPort';

  void _startGoogleAuthDesktop() async {
    setState(() => _isLoading = true);
    try {
      // Use the server to generate the auth URL with state + PKCE.
      // This is an unauthenticated call (user hasn't signed in yet),
      // so use http.get directly instead of api.get which attaches a Bearer token.
      final authUrlRequest = Uri.parse('${Env.apiRoot}/auth').replace(
        queryParameters: {
          'provider': 'google',
          'scopes': ['openid', 'profile', 'email'],
          'redirectUri': _desktopCallbackUrl,
          'platform': 'desktop',
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
      log.warning('Google sign-in failed (desktop)', e, t);
      final message = 'Unable to connect with Google. Please try again.';
      if (widget.onError != null) {
        widget.onError!(message);
      } else if (mounted) {
        context.showToast(message: message, isError: true);
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
        : _appCallbackUrl;

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

    try {
      final authUrl = await TwistApi.getAuthUrl(
        twistInstanceId: widget._twistInstanceId!,
        provider: widget.provider.name,
        redirectUri: redirectUri,
        platform: platform,
        enabledScopeGroups: widget._enabledScopeGroups,
      );

      if (_useNativeGoogleSignInForTwist) {
        await _startTwistNativeGoogle(authUrl);
      } else {
        await _startTwistBrowser(authUrl, redirectUri);
      }

      // Keep the button's spinner on through the activation step the caller
      // performs here; otherwise the modal redisplays a clickable auth button
      // during the tail-end network work and users can trigger a second flow.
      await widget._onSuccess?.call();
    } on GoogleSignInException catch (e, t) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        log.info('Google sign-in cancelled');
        return;
      }
      log.warning('OAuth flow failed for ${widget.provider.name}', e, t);
      Tracker.captureException(e, t);
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
      log.warning('OAuth flow failed for ${widget.provider.name}', e, t);
      Tracker.captureException(e, t);
      if (mounted) _showTwistAuthError();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _startTwistNativeGoogle(TwistAuthUrl authUrl) async {
    // Merge openid and email scopes so the server auth code includes an
    // id_token with email claim. Android GIS only grants explicitly requested
    // scopes; without these the token exchange returns no id_token and the
    // account shows a UUID instead of the user's email.
    final scopes = {...widget.scopes, 'openid', 'email'}.toList();

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

  Future<void> _startTwistBrowser(
    TwistAuthUrl authUrl,
    String redirectUri,
  ) async {
    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.url,
      callbackUrlScheme: redirectUri.split(':').first,
    );

    final responseUri = Uri.parse(result);
    final code = responseUri.queryParameters['code'];
    if (code == null) return;

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
    case AuthProvider.airtable:
      return "assets/airtable.svg";
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
