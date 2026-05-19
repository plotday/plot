import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api_exception.dart' show ApiException;
import 'package:plot/api/twist_api.dart'
    show TwistApi, TwistLinkedInCookieResult;
import 'package:plot/util/value.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/spinner.dart';

/// Modal that hosts an in-app LinkedIn login page, captures the user's
/// `li_at` + `JSESSIONID` session cookies after they sign in, and posts them
/// to the server's LinkedIn cookie endpoint to create the integration.
///
/// LinkedIn does not expose an OAuth scope that grants access to a user's
/// personal messaging, so we cannot use the normal OAuth flow. Capturing the
/// session cookie from a webview that targeted `linkedin.com` directly is the
/// only workable path — and is why the user-agent must remain the webview's
/// platform default (server-side anti-bot heuristics).
///
/// On success the modal pops with a [TwistLinkedInCookieResult] so the caller
/// can advance its setup flow exactly the way the OAuth path does.
class LinkedInLoginModal extends Modal {
  LinkedInLoginModal({required this.twistInstanceId, super.key})
    : super(
        constraints: const BoxConstraints(maxHeight: 720, maxWidth: 560),
        padding: EdgeInsets.zero,
        builder: (context) =>
            _LinkedInLoginModalContent(twistInstanceId: twistInstanceId),
      );

  final String twistInstanceId;

  /// Run the modal. Returns the connected account info on success, or `null`
  /// when the user cancelled or the modal was dismissed.
  Future<TwistLinkedInCookieResult?> run(BuildContext context) {
    return super
        .show<TwistLinkedInCookieResult>(context)
        .then((value) => value.present ? value.value : null);
  }
}

/// LinkedIn login URL. `_l=en_US` keeps the page language stable so our
/// signed-in detection works regardless of the user's locale.
final _kLoginUrl = WebUri('https://www.linkedin.com/login?_l=en_US');

/// LinkedIn cookie domains. Cookies set by the auth flow live on either
/// `.www.linkedin.com` or `.linkedin.com` depending on the platform's cookie
/// store; we query both to be safe.
final _kCookieDomains = [
  WebUri('https://www.linkedin.com'),
  WebUri('https://linkedin.com'),
];

/// Path prefixes that indicate the user has reached a signed-in page on
/// linkedin.com. Any one of these (combined with the presence of both the
/// `li_at` and `JSESSIONID` cookies) is treated as a successful login.
const _kSignedInPathPrefixes = <String>[
  '/feed',
  '/messaging',
  '/in/',
  '/mynetwork',
  '/notifications',
  '/jobs',
  '/checkpoint/lg/welcome',
];

class _LinkedInLoginModalContent extends StatefulWidget {
  const _LinkedInLoginModalContent({required this.twistInstanceId});

  final String twistInstanceId;

  @override
  State<_LinkedInLoginModalContent> createState() =>
      _LinkedInLoginModalContentState();
}

class _LinkedInLoginModalContentState
    extends State<_LinkedInLoginModalContent> {
  InAppWebViewController? _controller;
  bool _isSubmitting = false;
  String? _errorMessage;

  /// Guards against firing the POST twice if the cookie-capture check passes
  /// on multiple navigation events in quick succession.
  bool _captureStarted = false;

  Future<void> _maybeCaptureCookies(WebUri? url) async {
    if (_captureStarted || _isSubmitting) return;
    if (url == null) return;
    if (!_isSignedInUrl(url)) return;

    final cookies = await _readLinkedInCookies();
    final liAt = cookies['li_at'];
    final jsessionid = cookies['JSESSIONID'];
    if (liAt == null || liAt.isEmpty) return;
    if (jsessionid == null || jsessionid.isEmpty) return;

    _captureStarted = true;
    await _submitCookies(liAt: liAt, jsessionid: jsessionid);
  }

  bool _isSignedInUrl(WebUri url) {
    final host = url.host.toLowerCase();
    if (!host.endsWith('linkedin.com')) return false;
    final path = url.path;
    for (final prefix in _kSignedInPathPrefixes) {
      if (path.startsWith(prefix)) return true;
    }
    return false;
  }

  /// Read the LinkedIn cookies we care about from the webview's cookie store.
  /// Returns a map of cookie name → value. Missing cookies are absent from the
  /// map.
  Future<Map<String, String>> _readLinkedInCookies() async {
    final manager = CookieManager.instance();
    final result = <String, String>{};
    for (final domain in _kCookieDomains) {
      final List<Cookie> cookies;
      try {
        cookies = await manager.getCookies(url: domain);
      } catch (e, t) {
        log.warning('LinkedIn cookie read failed for $domain', e, t);
        continue;
      }
      for (final c in cookies) {
        final name = c.name;
        if (name != 'li_at' && name != 'JSESSIONID') continue;
        final raw = c.value;
        // `Cookie.value` is typed `dynamic`; the platform plugins return a
        // String on Android/iOS/macOS. Be defensive — coerce to String,
        // skip empty.
        final value = raw is String ? raw : raw?.toString();
        if (value == null || value.isEmpty) continue;
        // LinkedIn's JSESSIONID is wrapped in quotes (`"ajax:..."`). The
        // server expects the value verbatim, so don't strip them here.
        result.putIfAbsent(name, () => value);
      }
    }
    return result;
  }

  Future<void> _submitCookies({
    required String liAt,
    required String jsessionid,
  }) async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final userAgent = await _readUserAgent() ?? '';
      final result = await TwistApi.postLinkedInCookie(
        twistInstanceId: widget.twistInstanceId,
        liAt: liAt,
        jsessionid: jsessionid,
        userAgent: userAgent,
        platform: _platformLabel(),
      );
      // Clear the webview cookies on success so the user isn't left signed
      // into LinkedIn inside the app's webview store. Their real browser
      // session is unaffected.
      await _clearWebViewCookies();
      if (!mounted) return;
      Modal.pop<TwistLinkedInCookieResult>(context, Value(result));
    } on ApiException catch (e, t) {
      if (e.statusCode == 401) {
        log.info('LinkedIn cookie validation rejected by server', {
          'statusCode': e.statusCode,
        });
        if (!mounted) return;
        setState(() {
          _isSubmitting = false;
          _captureStarted = false;
          _errorMessage =
              'LinkedIn rejected that session. Please sign in again.';
        });
        return;
      }
      log.warning('LinkedIn cookie submission failed', e, t);
      if (e.statusCode >= 500) Tracker.captureException(e, t);
      if (!mounted) return;
      final serverMessage = e.statusCode >= 400 && e.statusCode < 500
          ? e.description.trim()
          : '';
      setState(() {
        _isSubmitting = false;
        _captureStarted = false;
        _errorMessage = serverMessage.isEmpty
            ? 'Unable to connect with LinkedIn. Please try again.'
            : serverMessage;
      });
    } catch (e, t) {
      log.warning('LinkedIn cookie submission failed', e, t);
      Tracker.captureException(e, t);
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _captureStarted = false;
        _errorMessage = 'Unable to connect with LinkedIn. Please try again.';
      });
    }
  }

  Future<String?> _readUserAgent() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final result = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      if (result is String && result.isNotEmpty) return result;
    } catch (e, t) {
      log.warning('Reading webview user agent failed', e, t);
    }
    return null;
  }

  /// Map the running platform to the four labels the server endpoint accepts.
  static String _platformLabel() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return 'desktop';
    }
  }

  Future<void> _clearWebViewCookies() async {
    try {
      final manager = CookieManager.instance();
      for (final domain in _kCookieDomains) {
        final cookies = await manager.getCookies(url: domain);
        for (final c in cookies) {
          await manager.deleteCookie(
            url: domain,
            name: c.name,
            domain: c.domain,
            path: c.path ?? '/',
          );
        }
      }
    } catch (e, t) {
      // Non-fatal — the cookies will at worst persist in the in-app store
      // until the next launch. Don't surface to the user, but log for
      // diagnostics.
      log.warning('Clearing LinkedIn webview cookies failed', e, t);
    }
  }

  void _retry() {
    setState(() {
      _errorMessage = null;
      _captureStarted = false;
    });
    _controller?.loadUrl(urlRequest: URLRequest(url: _kLoginUrl));
  }

  // ---------------------------------------------------------------------------
  // Keyboard shortcuts in text inputs (Cmd/Ctrl+A/V/C/X)
  // ---------------------------------------------------------------------------
  //
  // WKWebView on macOS doesn't reliably receive Cmd-modifier shortcuts when
  // it's embedded inside Flutter — the parent Flutter window grabs the
  // keystrokes first. The result is users can type into LinkedIn's login
  // fields but can't paste their password (a real problem since most people
  // use a password manager). We catch the canonical edit shortcuts at the
  // Flutter layer and forward each one to the webview's focused element via
  // JavaScript.
  //
  // - Cmd/Ctrl+A: `document.execCommand("selectAll")` — still works in WebKit
  //   even though execCommand is deprecated.
  // - Cmd/Ctrl+V: read the system clipboard via Flutter's Clipboard API, then
  //   insert the text into the focused element. We use `insertText` so the
  //   element fires the same `input` event LinkedIn's form would expect.
  // - Cmd/Ctrl+C: read the current Selection, copy to the system clipboard.
  // - Cmd/Ctrl+X: read selection, copy, then delete.

  Future<void> _selectAll() async {
    await _controller?.evaluateJavascript(
      source: 'document.execCommand("selectAll")',
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    // jsonEncode handles every escape we need (newlines, quotes, unicode).
    final js = 'document.execCommand("insertText", false, ${jsonEncode(text)})';
    await _controller?.evaluateJavascript(source: js);
  }

  Future<void> _copySelection() async {
    final result = await _controller?.evaluateJavascript(
      source: 'window.getSelection() ? window.getSelection().toString() : ""',
    );
    if (result is String && result.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: result));
    }
  }

  Future<void> _cutSelection() async {
    await _copySelection();
    await _controller?.evaluateJavascript(source: 'document.execCommand("delete")');
  }

  /// Build the Cmd+/Ctrl+ shortcut bindings for the webview. Both modifiers
  /// are bound so the modal works on Windows/Linux as well as macOS.
  Map<ShortcutActivator, VoidCallback> _webviewShortcuts() {
    return {
      const SingleActivator(LogicalKeyboardKey.keyA, meta: true): _selectAll,
      const SingleActivator(LogicalKeyboardKey.keyA, control: true): _selectAll,
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
      const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
      const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _copySelection,
      const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copySelection,
      const SingleActivator(LogicalKeyboardKey.keyX, meta: true): _cutSelection,
      const SingleActivator(LogicalKeyboardKey.keyX, control: true): _cutSelection,
    };
  }

  @override
  void dispose() {
    // Best-effort cookie clear on dispose so dismissing the modal mid-flow
    // doesn't leave the webview signed in.
    unawaited(_clearWebViewCookies());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 56, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connect LinkedIn',
                style: theme.typography.lg.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Sign in to LinkedIn to give Plot access to your messages.',
                style: theme.typography.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        Flexible(
          child: Stack(
            children: [
              // CallbackShortcuts handles Cmd/Ctrl+A/V/C/X at the Flutter
              // layer so the webview's text inputs work — WKWebView on macOS
              // doesn't receive these keys when embedded in a Flutter app.
              // Focus(autofocus: true) ensures the shortcuts widget is in the
              // focus chain even before the user clicks into the webview.
              CallbackShortcuts(
                bindings: _webviewShortcuts(),
                child: Focus(
                  autofocus: true,
                  child: InAppWebView(
                    initialUrlRequest: URLRequest(url: _kLoginUrl),
                    initialSettings: InAppWebViewSettings(
                      // IMPORTANT: do NOT override the user-agent. LinkedIn pins
                      // session cookies to the UA that established them, and the
                      // server replays requests using whatever UA we report here.
                      isInspectable: false,
                      javaScriptEnabled: true,
                      // Some LinkedIn flows pop a new window after sign-in
                      // (e.g. the verification challenge). Keep navigation inside
                      // this webview so cookies are observed in one store.
                      supportMultipleWindows: false,
                      // Limit linkedin.com only — block third-party redirects so
                      // a stray ad/widget can't navigate us off-host.
                      useShouldOverrideUrlLoading: true,
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                    },
                    shouldOverrideUrlLoading: (controller, action) async {
                      final url = action.request.url;
                      if (url == null) return NavigationActionPolicy.ALLOW;
                      final host = url.host.toLowerCase();
                      if (host.isEmpty || host.endsWith('linkedin.com')) {
                        return NavigationActionPolicy.ALLOW;
                      }
                      // Block off-host navigations (licensing CDNs, ads, etc.).
                      // The login flow only needs linkedin.com.
                      return NavigationActionPolicy.CANCEL;
                    },
                    onLoadStop: (controller, url) {
                      unawaited(_maybeCaptureCookies(url));
                    },
                    onUpdateVisitedHistory: (controller, url, _) {
                      unawaited(_maybeCaptureCookies(url));
                    },
                  ),
                ),
              ),
              if (_isSubmitting)
                Positioned.fill(
                  child: ColoredBox(
                    color: theme.colors.background.withValues(alpha: 0.85),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Spinner(
                            color: theme.colors.foreground,
                            size: 20,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Connecting your LinkedIn account…',
                            style: theme.typography.sm,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: theme.typography.sm.copyWith(
                      color: theme.colors.destructive,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FButton(
                  variant: FButtonVariant.outline,
                  onPress: _retry,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
