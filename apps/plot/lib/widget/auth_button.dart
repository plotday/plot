import 'dart:io' show Platform;
import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:forui/forui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/env.dart';
import 'package:plot/widget/alert.dart';
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
  static Future<void> init() async {
    late final String clientId;
    String? serverClientId;
    if (kIsWeb) {
      clientId = Env.googleClientId;
    } else if (Platform.isAndroid) {
      clientId = Env.googleAndroidClientId;
      serverClientId = Env.googleClientId;
    } else if (Platform.isIOS || Platform.isMacOS) {
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
            'level': _link.level,
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
      final GoogleSignIn signIn = GoogleSignIn.instance;

      // On web, listen to the user stream to handle sign-in from the rendered button
      if (kIsWeb && !signIn.supportsAuthenticate()) {
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
        log.info('Google sign-in cancelled by user');
        return;
      }
      log.warning('Google sign-in failed', e, t);
      final message = e.description ?? 'Google sign-in failed';
      if (widget.onError != null) {
        widget.onError!(message);
      } else {
        if (mounted) {
          Alert.show(context, message);
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
      final message = e.message.isEmpty ? 'Apple sign-in failed' : e.message;
      if (widget.onError != null) {
        widget.onError!(message);
      } else {
        if (mounted) {
          Alert.show(context, message);
        }
      }
      return;
    } catch (e, t) {
      log.warning('Apple sign-in failed', e, t);
      if (widget.onError != null) {
        widget.onError!('Apple sign-in failed: $e');
      } else {
        if (mounted) {
          Alert.show(context, 'Apple sign-in failed: $e');
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
      final authUrl = await _generateAuthUrl();

      final result = await FlutterWebAuth2.authenticate(
        url: authUrl.url,
        callbackUrlScheme: Env.authCallbackUrl.split(':').first,
      );

      final responseUri = Uri.parse(result);
      final params = responseUri.queryParameters;

      await widget.onComplete(
        clientId: authUrl.clientId,
        redirectUri: Env.authCallbackUrl,
        code: params['code'],
        state: authUrl.state,
      );
    } catch (e) {
      if (mounted) {
        if (widget.onError != null) {
          widget.onError!(e.toString());
        } else {
          Alert.show(context, '$e');
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
    } else if (Platform.isAndroid) {
      platform = 'android';
    } else if (Platform.isIOS) {
      platform = 'ios';
    } else if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      platform = 'desktop';
    }

    final link = widget._link!;
    final uri = Uri(
      path: '/auth',
      queryParameters: {
        'provider': link.provider.name,
        'level': link.level,
        'scopes': link.scopes,
        'callback': link.callback,
        'redirectUri': Env.authCallbackUrl,
        if (platform != null) 'platform': platform,
      },
    );
    final response = await api.get<Map<String, dynamic>>(uri.toString());
    return _AuthUrlResult(response);
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
          ? FCircularProgress()
          : _ProviderIcon(provider: widget.provider, size: config.iconSize),
      child: Text(
        config.buttonText,
        style: context.theme.typography.base.copyWith(
          fontWeight: config.fontWeight,
          fontFamily: config.fontFamily,
          color: _isLoading ? config.disabledTextColor : config.textColor,
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
        padding: widgetPadding,
        textStyle: FWidgetStateMap.all(
          context.theme.typography.base.copyWith(
            fontWeight: config.fontWeight,
            fontFamily: config.fontFamily,
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

  void _onPress() {
    if (_isLoading) return;
    if (widget.provider == AuthProvider.google) {
      _startGoogleAuth();
    } else if (widget.provider == AuthProvider.apple) {
      _startAppleAuth();
    } else {
      _startOAuth();
    }
  }

  _ProviderConfig _getProviderConfig(AuthProvider provider) {
    switch (provider) {
      case AuthProvider.google:
        return _ProviderConfig(
          backgroundColor: Colors.white,
          textColor: const Color(0xFF3C4043),
          borderColor: const Color(0xFFDADBDD),
          horizontalPadding: 12,
          hoverColor: const Color(0xFFF8F9FA),
          focusColor: const Color(0xFF4285F4),
          loadingColor: const Color(0xFF4285F4),
          disabledTextColor: const Color(0xFF9AA0A6),
          iconSize: 18,
          spacing: 12,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontFamily: 'Roboto',
          buttonText: 'Continue with Google',
        );

      case AuthProvider.microsoft:
        return _ProviderConfig(
          backgroundColor: Colors.white,
          textColor: const Color(0xFF5E5E5E), // Microsoft's text color
          borderColor: const Color(0xFF8C8C8C), // Darker border than Google
          horizontalPadding: 12,
          hoverColor: const Color(0xFFF3F2F1), // Microsoft's hover color
          focusColor: const Color(0xFF0078D4), // Microsoft Blue
          loadingColor: const Color(0xFF0078D4),
          disabledTextColor: const Color(0xFFA19F9D),
          iconSize: 16, // Smaller icon
          spacing: 8, // Less spacing
          fontSize: 13, // Smaller font
          fontWeight: FontWeight.w400, // Regular weight
          fontFamily: 'Segoe UI', // Microsoft's font
          buttonText: 'Continue with Microsoft',
        );

      case AuthProvider.slack:
        return _ProviderConfig(
          backgroundColor: const Color(0xFF4A154B), // Slack Purple
          textColor: Colors.white,
          borderColor: const Color(0xFF4A154B),
          horizontalPadding: 16, // More padding
          hoverColor: const Color(0xFF611F69), // Darker purple on hover
          focusColor: const Color(0xFF611F69),
          loadingColor: Colors.white,
          disabledTextColor: const Color(0xFFB8A5BA),
          iconSize: 20, // Larger icon
          spacing: 12,
          fontSize: 15, // Slightly larger font
          fontWeight: FontWeight.w600, // Semi-bold
          fontFamily: 'Lato', // Slack's font
          buttonText: 'Continue with Slack',
        );

      case AuthProvider.apple:
        return _ProviderConfig(
          backgroundColor: Colors.white,
          textColor: Colors.black,
          borderColor: const Color(0xFFDADBDD),
          horizontalPadding: 16,
          hoverColor: const Color(0xFF1D1D1F),
          focusColor: const Color(0xFF0071E3), // Apple Blue
          loadingColor: Colors.white,
          disabledTextColor: const Color(0xFF86868B),
          iconSize: 18,
          spacing: 8,
          fontSize: 16, // Larger font
          fontWeight: FontWeight.w600,
          fontFamily: 'SF Pro Text', // Apple's font
          buttonText: 'Continue with Apple',
        );

      case AuthProvider.github:
        return _ProviderConfig(
          backgroundColor: const Color(0xFF24292E), // GitHub dark
          textColor: Colors.white,
          borderColor: const Color(0xFF24292E),
          horizontalPadding: 16,
          hoverColor: const Color(0xFF2F363D),
          focusColor: const Color(0xFF0366D6), // GitHub Blue
          loadingColor: Colors.white,
          disabledTextColor: const Color(0xFF959DA5),
          iconSize: 18,
          spacing: 12,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontFamily: 'system-ui', // System font
          buttonText: 'Continue with GitHub',
        );

      case AuthProvider.discord:
        return _ProviderConfig(
          backgroundColor: const Color(0xFF5865F2), // Discord Blurple
          textColor: Colors.white,
          borderColor: const Color(0xFF5865F2),
          horizontalPadding: 16,
          hoverColor: const Color(0xFF4752C4),
          focusColor: const Color(0xFF4752C4),
          loadingColor: Colors.white,
          disabledTextColor: const Color(0xFFB5BAF2),
          iconSize: 20,
          spacing: 12,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontFamily: 'system-ui',
          buttonText: 'Continue with Discord',
        );

      default:
        return _ProviderConfig(
          backgroundColor: Colors.white,
          textColor: const Color(0xFF3C4043),
          borderColor: const Color(0xFFDADBDD),
          horizontalPadding: 12,
          hoverColor: const Color(0xFFF8F9FA),
          focusColor: const Color(0xFF4285F4),
          loadingColor: const Color(0xFF4285F4),
          disabledTextColor: const Color(0xFF9AA0A6),
          iconSize: 18,
          spacing: 12,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontFamily: 'Roboto',
          buttonText: 'Continue with $provider',
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
    // In a real implementation, you'd use proper SVG assets or icon fonts
    // This is a placeholder showing the structure
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        decoration: BoxDecoration(
          color: _getIconColor(),
          borderRadius: BorderRadius.circular(size * 0.1),
        ),
        child: SvgPicture.asset(
          _getIcon(),
          width: size * 0.7,
          height: size * 0.7,
        ),
      ),
    );
  }

  Color _getIconColor() {
    switch (provider) {
      case AuthProvider.slack:
      case AuthProvider.apple:
      case AuthProvider.github:
      case AuthProvider.discord:
        return Colors.white;
      default:
        return Colors.transparent;
    }
  }

  String _getIcon() {
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
      default:
        return "assets/google.svg";
    }
  }
}
