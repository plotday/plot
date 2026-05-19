import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart' show Clipboard;
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

  /// A real-browser User-Agent matched to the running platform. Used for both
  /// the in-app login webview and (after capture) the server-side Voyager
  /// calls — pinning the same UA on both sides keeps LinkedIn's fingerprint
  /// checks happy.
  ///
  /// We pin Chrome on every platform (not the platform-native browser). On
  /// macOS/iOS, a Safari UA makes LinkedIn render a passkey/autofill chip
  /// over the email input that blocks click-to-focus. Chrome doesn't get
  /// that overlay, and Voyager doesn't distinguish Chrome vs Safari — it
  /// only checks that *some* real browser token is present.
  ///
  /// Strings are intentionally a few minor versions back from "latest" so
  /// they age well; LinkedIn doesn't require bleeding-edge.
  static String _pinnedUserAgent() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        // CriOS = Chrome on iOS. Same WebKit underneath, different UA brand
        // → no Safari passkey chip on the login form.
        return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) '
            'CriOS/126.0.6478.122 Mobile/15E148 Safari/604.1';
      case TargetPlatform.android:
        return 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/126.0.6478.122 Mobile Safari/537.36';
      case TargetPlatform.macOS:
        return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/126.0.6478.127 Safari/537.36';
      case TargetPlatform.windows:
        return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/126.0.6478.127 Safari/537.36';
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return 'Mozilla/5.0 (X11; Linux x86_64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/126.0.6478.127 Safari/537.36';
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

  Future<void> _retry() async {
    setState(() {
      _errorMessage = null;
      _captureStarted = false;
    });
    // Wipe the webview's LinkedIn cookies before reloading. Without this,
    // /login redirects straight back to /feed because the user is still
    // signed in, we capture the same (rejected) cookie, and the server
    // immediately rejects it again — "Try again" becomes a no-op. Clearing
    // forces a fresh credential entry, which is what the user expects.
    await _clearWebViewCookies();
    await _controller?.loadUrl(urlRequest: URLRequest(url: _kLoginUrl));
  }

  // ---------------------------------------------------------------------------
  // Keyboard shortcuts in text inputs (Cmd/Ctrl + A/V/C/X)
  // ---------------------------------------------------------------------------
  //
  // The webview is a platform view (WKWebView on macOS/iOS, WebView on
  // Android) with its own native event loop. Keystrokes typed inside it
  // never reach Flutter's widget tree, so a Flutter-side `Shortcuts` /
  // `CallbackShortcuts` wrapper can't see them. The fix has to live inside
  // the page itself: a `keydown` capture-phase listener that detects the
  // Cmd/Ctrl modifier shortcuts and either:
  //
  //   - handles them entirely in JS (Cmd+A → `document.execCommand('selectAll')`)
  //   - bounces back to Flutter (Cmd+V) so we can read the system clipboard
  //     and `insertText` the result into the focused element
  //
  // Cmd+C / Cmd+X work natively in WKWebView once selection is established,
  // so we don't override them. We use the capture phase + `preventDefault`
  // so LinkedIn's own keydown handlers can't swallow the shortcut.

  /// User script injected at document-start. Uses `window.flutter_inappwebview.callHandler`
  /// to call our paste handler defined below.
  static final _kEditShortcutsScript = UserScript(
    source: r"""
      (function () {
        document.addEventListener(
          'keydown',
          function (e) {
            if (!(e.metaKey || e.ctrlKey)) return;
            if (e.altKey) return; // leave Alt-combinations alone
            var key = (e.key || '').toLowerCase();
            if (key === 'a') {
              e.preventDefault();
              e.stopPropagation();
              try {
                document.execCommand('selectAll');
              } catch (_) {}
              return;
            }
            if (key === 'v') {
              e.preventDefault();
              e.stopPropagation();
              try {
                window.flutter_inappwebview.callHandler('linkedinPaste');
              } catch (_) {}
              return;
            }
            // Cmd/Ctrl+C and Cmd/Ctrl+X: leave WKWebView's native selection
            // handling in place so the platform handles clipboard writes.
          },
          true /* capture phase, beat LinkedIn's own handlers */
        );
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  /// Read the system clipboard via Flutter (the webview can't reach it
  /// reliably in a non-https/secure context), then inject the text into the
  /// focused element. Using `insertText` so the input fires the same
  /// `input` event LinkedIn's React form is listening for.
  Future<void> _onLinkedInPasteRequested() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final js =
        'document.execCommand("insertText", false, ${jsonEncode(text)})';
    await _controller?.evaluateJavascript(source: js);
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
              InAppWebView(
                initialUrlRequest: URLRequest(url: _kLoginUrl),
                initialSettings: InAppWebViewSettings(
                  // Pin a real-browser UA. The WKWebView/Android default UA
                  // strings lack the trailing `Version/X Safari/X` (or
                  // `Chrome/X`) token, which LinkedIn's Voyager API
                  // fingerprints as automation and rejects with 403. We pin
                  // a Chrome UA (not Safari) because a Mac/iOS Safari UA
                  // makes LinkedIn enable a passkey/autofill chip on the
                  // email input, and the chip's overlay swallows pointer
                  // events — clicks miss and the I-beam never appears
                  // (Shift+Tab still works because that's keyboard focus
                  // traversal). Chrome on the same platforms skips that
                  // chip, and Voyager accepts either brand on replay so
                  // long as a `Safari` or `Chrome` token is present.
                  userAgent: _pinnedUserAgent(),
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
                // Inject the Cmd/Ctrl+A/V capture-phase listener at document
                // start so it's installed before LinkedIn's own scripts run.
                initialUserScripts:
                    UnmodifiableListView([_kEditShortcutsScript]),
                onWebViewCreated: (controller) {
                  _controller = controller;
                  controller.addJavaScriptHandler(
                    handlerName: 'linkedinPaste',
                    callback: (_) async {
                      await _onLinkedInPasteRequested();
                      return null;
                    },
                  );
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
