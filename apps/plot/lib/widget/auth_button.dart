import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode;

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
import 'package:plot/util/google_sign_in.dart' as web;
import 'package:plot/store/store.dart' show AuthLink;
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/api/api.dart' as api;
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
  static bool get _useNativeGoogleSignIn =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.android;

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
    this.autoSignIn = true,
    this.scopes = const [],
    this.onError,
    super.key,
  }) : _link = null,
       _onOIDCAuth = onAuth,
       _onLinkAuth = null;

  // Run an OAuth authorization flow for the given link
  AuthButton.authorize({
    required AuthLink link,
    void Function()? onAuth,
    this.onError,
    super.key,
  }) : _link = link,
       provider = link.provider,
       autoSignIn = false,
       _onOIDCAuth = null,
       _onLinkAuth = onAuth,
       scopes = link.scopes;

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
  final List<String> scopes;
  final AuthLink? _link;
  final void Function(String error)? onError;

  @override
  State<AuthButton> createState() => _AuthButtonState();
}

class _AuthButtonState extends State<AuthButton> {
  bool _isLoading = false;
  Widget? _cachedWebButton;

  @override
  void initState() {
    super.initState();
    if (widget.provider == AuthProvider.google) {
      if (AuthButton._useNativeGoogleSignIn) {
        final GoogleSignIn signIn = GoogleSignIn.instance;

        // On web, listen to the user stream to handle sign-in from the rendered button
        // Only cache the web button for sign-in flows, not authorize flows
        if (kIsWeb && !signIn.supportsAuthenticate() && widget._link == null) {
          // Cache the web button widget to prevent re-rendering
          _cachedWebButton = web.buildGoogleSignInButton();

          signIn.authenticationEvents.listen((event) {
            log.info('Google sign-in event: $event');
            if (event is GoogleSignInAuthenticationEventSignIn) {
              _onGoogleSignIn(event.user);
            }
          });
        }

        if (widget.autoSignIn) {
          unawaited(() async {
            final account = await signIn.attemptLightweightAuthentication();
            if (account != null) {
              _onGoogleSignIn(account);
            }
          }());
        }
      }
    }
  }

  void _onGoogleSignIn(GoogleSignInAccount account) async {
    final googleAuth = account.authentication;
    final idToken = googleAuth.idToken;

    String? accessToken;
    if (widget.scopes.isNotEmpty) {
      final GoogleSignInClientAuthorization authorization = await account
          .authorizationClient
          .authorizeScopes(widget.scopes);
      accessToken = authorization.accessToken;
    }

    String? code;
    if (widget.scopes.isNotEmpty) {
      final GoogleSignInServerAuthorization? serverAuth = await account
          .authorizationClient
          .authorizeServer(widget.scopes);
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
      // Always sign out first to force account selection
      await GoogleSignIn.instance.signOut();

      // Authenticate with full account picker
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: widget.scopes,
      );
      _onGoogleSignIn(account);
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
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _startAppleAuth() async {
    setState(() => _isLoading = true);
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        webAuthenticationOptions: kIsWeb
            ? WebAuthenticationOptions(
                clientId: Env.appleClientId,
                redirectUri: Uri.parse(Env.authCallbackUrl),
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

    try {
      log.info('Starting OAuth flow for ${widget.provider.name}');
      final authUrl = await _generateAuthUrl();
      log.info('Generated auth URL for ${widget.provider.name}', {
        'clientId': authUrl.clientId,
        'hasState': authUrl.state.isNotEmpty,
      });

      final result = await FlutterWebAuth2.authenticate(
        url: authUrl.url,
        callbackUrlScheme: Env.authCallbackUrl.split(':').first,
      );

      final responseUri = Uri.parse(result);
      final params = responseUri.queryParameters;

      log.info('OAuth callback received for ${widget.provider.name}', {
        'hasCode': params['code'] != null,
      });

      await widget.onComplete(
        clientId: authUrl.clientId,
        redirectUri: Env.authCallbackUrl,
        code: params['code'],
        state: authUrl.state,
      );

      log.info('OAuth flow completed successfully for ${widget.provider.name}');
    } catch (e, t) {
      log.warning('OAuth flow failed for ${widget.provider.name}', e, t);
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

  Future<_AuthUrlResult> _generateAuthUrl() async {
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
        'redirectUri': Env.authCallbackUrl,
        if (platform != null) 'platform': platform,
      },
    );

    log.info('Requesting auth URL from API', {
      'provider': link.provider.name,
      'scopes': link.scopes.join(', '),
      'platform': platform,
      'uri': uri.toString(),
    });

    try {
      final response = await api.get<Map<String, dynamic>>(uri.toString());
      log.info('Received auth URL response from API', {
        'provider': link.provider.name,
        'hasUrl': response.containsKey('url'),
        'hasClientId': response.containsKey('clientId'),
        'hasState': response.containsKey('state'),
      });
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
    // Return cached web button to prevent re-rendering
    if (_cachedWebButton != null) {
      return _cachedWebButton!;
    }

    final config = _getProviderConfig(widget.provider);
    return FButton(
      mainAxisSize: .min,
      onPress: _isLoading ? null : _onPress,
      style: _buildButtonStyle(context, config),
      prefix: _isLoading
          ? Spinner(color: config.textColor, size: config.iconSize)
          : _ProviderIcon(provider: widget.provider, size: config.iconSize),
      child: Text(
        config.buttonText,
        style: context.theme.typography.base.copyWith(
          fontWeight: config.fontWeight,
          fontFamily: config.fontFamily,
          color: _isLoading ? config.disabledTextColor : config.textColor,
          height: 1,
        ),
      ),
    );
  }

  FButtonStyle _buildButtonStyle(BuildContext context, _ProviderConfig config) {
    return FButtonStyle(
      decoration: FWidgetStateMap({
        WidgetState.any: BoxDecoration(
          color: config.backgroundColor,
          border: Border.all(color: config.borderColor, width: 1),
          borderRadius: tileBorderRadius,
        ),
        WidgetState.hovered: BoxDecoration(
          color: config.hoverColor,
          border: Border.all(color: config.borderColor, width: 1),
          borderRadius: tileBorderRadius,
        ),
        WidgetState.focused: BoxDecoration(
          color: config.backgroundColor,
          border: Border.all(color: config.focusColor, width: 1),
          borderRadius: tileBorderRadius,
        ),
        WidgetState.disabled: BoxDecoration(
          color: config.backgroundColor.withValues(alpha: 0.6),
          border: Border.all(
            color: config.borderColor.withValues(alpha: 0.6),
            width: 1,
          ),
          borderRadius: tileBorderRadius,
        ),
      }),
      contentStyle: FButtonContentStyle(
        padding: context.theme.buttonStyles.secondary.contentStyle.padding,
        textStyle: FWidgetStateMap.all(
          context.theme.typography.base.copyWith(
            fontWeight: config.fontWeight,
            fontFamily: config.fontFamily,
            height: 1,
          ),
        ),
        iconStyle: FWidgetStateMap.all(IconThemeData(size: config.iconSize)),
        circularProgressStyle: FWidgetStateMap.all(
          context.theme.circularProgressStyle,
        ),
      ),
      iconContentStyle: FButtonIconContentStyle(
        iconStyle: FWidgetStateMap.all(IconThemeData(size: config.iconSize)),
      ),
      focusedOutlineStyle: FFocusedOutlineStyle(
        borderRadius: tileBorderRadius,
        color: config.focusColor,
      ),
      tappableStyle: FTappableStyle(),
    );
  }

  void _startGoogleAuthDesktop() async {
    setState(() => _isLoading = true);
    try {
      final clientId = Env.googleDesktopClientId ?? Env.googleClientId;

      final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': clientId,
        'redirect_uri': Env.authCallbackUrl,
        'response_type': 'code',
        'scope': 'openid profile email',
        'access_type': 'offline',
        'prompt': 'select_account',
      });

      final result = await FlutterWebAuth2.authenticate(
        url: authUrl.toString(),
        callbackUrlScheme: Env.authCallbackUrl.split(':').first,
      );

      final responseUri = Uri.parse(result);
      final code = responseUri.queryParameters['code'];
      if (code == null) {
        throw Exception('No authorization code received from Google');
      }

      // POST code to API for server-side token exchange
      final uri = Uri.parse('${Env.apiRoot}/auth').replace(queryParameters: {
        'code': code,
        'clientId': clientId,
        'redirectUri': Env.authCallbackUrl,
        'provider': 'google',
      });
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
        redirectUri: Env.authCallbackUrl,
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
    if (widget.provider == AuthProvider.google) {
      if (!AuthButton._useNativeGoogleSignIn) {
        // On Windows/Linux, use browser-based OAuth for authorize flows,
        // or the all-platforms sign-in for authentication
        if (widget._link != null) {
          _startOAuth();
        } else {
          _startGoogleAuthDesktop();
        }
      } else if (kIsWeb && widget._link != null) {
        // On web, use backend OAuth for authorize flows to avoid:
        // 1. Multiple popup blocking (authorizeScopes/authorizeServer open separate popups)
        // 2. User sign-out when selecting a different account
        _startOAuth();
      } else {
        _startGoogleAuth();
      }
    } else if (widget.provider == AuthProvider.apple) {
      _startAppleAuth();
    } else {
      _startOAuth();
    }
  }

  _ProviderConfig _getProviderConfig(AuthProvider provider) {
    // Uniform sizing for all buttons
    const iconSize = 18.0;
    const spacing = 12.0;
    const fontSize = 14.0;
    const fontWeight = FontWeight.w500;
    const horizontalPadding = 12.0;

    switch (provider) {
      case AuthProvider.google:
        return _ProviderConfig(
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
          buttonText: 'Continue with Google',
        );

      case AuthProvider.microsoft:
        return _ProviderConfig(
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
          fontWeight: fontWeight,
          fontFamily: 'Segoe UI',
          buttonText: 'Continue with Microsoft',
        );

      case AuthProvider.slack:
        return _ProviderConfig(
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
        return _ProviderConfig(
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
          fontWeight: fontWeight,
          fontFamily: 'SF Pro Text',
          buttonText: 'Continue with Apple',
        );

      case AuthProvider.github:
        return _ProviderConfig(
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
        return _ProviderConfig(
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
        return _ProviderConfig(
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
        return _ProviderConfig(
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
        return _ProviderConfig(
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
        return _ProviderConfig(
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
        return _ProviderConfig(
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
        return _ProviderConfig(
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

      default:
        return _ProviderConfig(
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
}

class _ProviderConfig {
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

  const _ProviderConfig({
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

class _ProviderIcon extends StatelessWidget {
  final AuthProvider provider;
  final double size;

  const _ProviderIcon({required this.provider, required this.size});

  @override
  Widget build(BuildContext context) {
    final icon = _getIcon();

    // Return empty widget if no icon is available
    if (icon == null) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: SvgPicture.asset(icon, width: size, height: size),
      ),
    );
  }

  String? _getIcon() {
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
      default:
        return null; // No icon for unknown/other providers
    }
  }
}
