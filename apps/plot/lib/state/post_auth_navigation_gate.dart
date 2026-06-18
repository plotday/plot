/// Decides whether a freshly-emitted `UserReady` should bounce the user to
/// their default priority (Personal Inbox).
///
/// This must happen ONLY on a genuine **re-sign-in** — the user signed out and
/// back in while the app was already running. It must NOT happen on a **cold
/// start / web page refresh**, where the router has already resolved the real
/// browser URL (a deep link to a specific focus `/p/<id>` or thread
/// `/t/<id>`). Navigating to the default priority there clobbers the resolved
/// deep link — the "refresh / opening a link always lands on Personal Inbox"
/// bug.
///
/// Why a sticky "saw signed out" flag rather than the previous state:
/// `UserBloc` emits `UserLoading` immediately before every `UserReady` (see
/// `UserBloc._process`), on both cold start and re-sign-in. So the state
/// directly preceding `UserReady` is always `UserLoading` and can't tell the
/// two apart. A re-sign-in is the only path that first passes through
/// `UserSignedOut`, so we latch that and consume it when the next ready
/// arrives.
class PostAuthNavigationGate {
  bool _sawSignedOut = false;

  /// Call whenever the user signs out (a `UserSignedOut` emission).
  void onSignedOut() => _sawSignedOut = true;

  /// Call once while handling a `UserReady` emission. Returns `true` when the
  /// app should navigate to the default priority (re-sign-in), `false` when it
  /// should leave the current, already-resolved route untouched (cold start /
  /// refresh / deep-link open). The re-sign-in latch is consumed on each call.
  bool shouldNavigateToDefaultOnReady() {
    final reSignIn = _sawSignedOut;
    _sawSignedOut = false;
    return reSignIn;
  }
}
