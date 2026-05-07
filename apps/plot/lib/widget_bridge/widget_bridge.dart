import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:plot/state/now.dart';
import 'package:plot/state/user.dart';

import 'widget_bridge_channel.dart';
import 'widget_data.dart';

/// Side-effect listener that watches the user/now blocs and pushes
/// a fresh [WidgetState] to the native widget host whenever the
/// signed-in user or context priority changes.
///
/// The bridge intentionally does not own any UI — it only translates
/// app state into the data widgets read on their own refresh
/// timeline. Callers attach it once at app startup (see
/// `RootProvider`) and dispose it on tear-down.
class WidgetBridge {
  WidgetBridge({required UserBloc userBloc, required NowBloc nowBloc})
    : _userBloc = userBloc,
      _nowBloc = nowBloc;

  final UserBloc _userBloc;
  final NowBloc _nowBloc;

  StreamSubscription<UserState>? _userSub;
  StreamSubscription<NowState>? _nowSub;
  Timer? _debounce;
  WidgetState _last = WidgetState.signedOut();
  bool _started = false;

  /// Begin streaming state to the native host. Safe to call
  /// multiple times; subsequent calls are no-ops.
  void start() {
    if (_started || !WidgetBridgeChannel.isSupportedPlatform) return;
    _started = true;
    WidgetBridgeChannel.instance.attach();

    _userSub = _userBloc.stream.listen((_) => _scheduleSync());
    _nowSub = _nowBloc.stream.listen((_) => _scheduleSync());
    _scheduleSync(immediate: true);
  }

  /// Stop streaming and clear any pending debounce.
  Future<void> stop() async {
    _started = false;
    _debounce?.cancel();
    _debounce = null;
    await _userSub?.cancel();
    await _nowSub?.cancel();
    _userSub = null;
    _nowSub = null;
  }

  void _scheduleSync({bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      unawaited(_sync());
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_sync());
    });
  }

  Future<void> _sync() async {
    final next = _snapshot();
    if (next == _last) return;
    _last = next;
    debugPrint(
      '[widget-bridge] state '
      'signedIn=${next.isSignedIn} '
      'priority=${next.currentPriorityId ?? '-'}',
    );
    await WidgetBridgeChannel.instance.writeState(next);
    await WidgetBridgeChannel.instance.reloadAll();
  }

  WidgetState _snapshot() {
    final userState = _userBloc.state;
    if (userState is! UserReady) {
      return WidgetState.signedOut();
    }
    final user = userState.user;
    final nowState = _nowBloc.state;
    String? priorityId;
    String? priorityTitle;
    if (nowState is NowLoaded) {
      final priority = nowState.priority;
      priorityId = priority.id.toString();
      priorityTitle = priority.title;
    }
    return WidgetState(
      isSignedIn: true,
      userId: user.id,
      currentPriorityId: priorityId,
      currentPriorityTitle: priorityTitle,
    );
  }
}
