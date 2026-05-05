import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:plot/app_info.dart';
import 'package:plot/base.dart';
import 'package:plot/env.dart';
import 'package:plot/logging.dart';
import 'package:plot/api/broadcast_channel.dart';

typedef MessageHandler = Future<void> Function(Map<String, dynamic> message);
typedef ReconnectedHandler = void Function();

class BroadcastClient with WidgetsBindingObserver {
  static BroadcastClient? _instance;
  static BroadcastClient get instance => _instance ??= BroadcastClient._();

  BroadcastClient._() {
    WidgetsBinding.instance.addObserver(this);
  }

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  StreamSubscription<dynamic>? _messageSubscription;
  ReconnectedHandler? _onReconnected;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  static const Duration _baseReconnectDelay = Duration(seconds: 1);
  static const Duration _maxReconnectDelay = Duration(seconds: 30);
  static const Duration _pingInterval = Duration(seconds: 30);
  static const Duration _offlineDebounceDelay = Duration(seconds: 10);

  /// Debounced connection state for UI consumption.
  /// Goes to `false` only after being disconnected for 10 seconds.
  /// Returns to `true` immediately on reconnection.
  final ValueNotifier<bool> connectionState = ValueNotifier<bool>(true);
  Timer? _offlineDebounceTimer;

  bool _isConnected = false;
  bool _shouldReconnect = false;
  bool _hasConnectivity = false;
  bool _wasEverConnected =
      false; // Track if we've ever had a successful connection
  int _currentDelayMs = 1000; // Track current backoff delay
  MessageHandler? _messageHandler;
  int? _clientId;
  bool get isConnected => _isConnected;
  int? get clientId => _clientId;

  /// Initialize the broadcast client with a message handler
  Future<void> connect(
    MessageHandler messageHandler,
    int clientId, {
    ReconnectedHandler? onReconnected,
  }) async {
    _messageHandler = messageHandler;
    _clientId = clientId;
    _onReconnected = onReconnected;

    // Cancel any existing connectivity subscription to prevent leaks
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    // Check initial connectivity state
    try {
      final initialResults = await Connectivity().checkConnectivity();
      _hasConnectivity = initialResults.any(
        (result) => result != ConnectivityResult.none,
      );
    } catch (e) {
      log.warning("Error checking initial connectivity: $e");
      _hasConnectivity = true;
    }
    if (_hasConnectivity) {
      await _connect();
    }

    // Listen for connectivity changes
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      final hadConnectivity = _hasConnectivity;
      final hasConnection = results.any(
        (result) => result != ConnectivityResult.none,
      );
      _hasConnectivity = hasConnection;

      // Only attempt to reconnect when transitioning from offline to online
      if (!hadConnectivity && hasConnection && !_isConnected) {
        _resetBackoff(); // Reset backoff for immediate reconnect
        _connect();
      }
    });
  }

  /// Whether the app is currently in the foreground.
  bool _appIsActive = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appIsActive = true;
      if (_shouldReconnect && !_isConnected) {
        _resetBackoff(); // Reset backoff for immediate reconnect
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _connect();
      } else if (_isConnected) {
        // Already connected — tell server we're active again
        _sendPing(active: true);
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _appIsActive = false;
      _sendPing(active: false);
      // Cancel pending reconnect — don't reconnect while backgrounded
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
  }

  /// Reset backoff delay for immediate reconnection
  void _resetBackoff() {
    _currentDelayMs = _baseReconnectDelay.inMilliseconds;
  }

  /// Update the debounced connection notifier.
  /// Immediately shows connected; debounces 10s before showing offline.
  void _updateConnectionNotifier() {
    if (_isConnected) {
      _offlineDebounceTimer?.cancel();
      _offlineDebounceTimer = null;
      connectionState.value = true;
    } else {
      if (connectionState.value == false) return;
      if (_offlineDebounceTimer?.isActive == true) return;
      _offlineDebounceTimer = Timer(_offlineDebounceDelay, () {
        _offlineDebounceTimer = null;
        if (!_isConnected) {
          connectionState.value = false;
        }
      });
    }
  }

  /// Connect to the WebSocket endpoint
  Future<void> _connect() async {
    if (_isConnected || _channel != null) {
      return;
    }

    _shouldReconnect = true;

    try {
      // Check network connectivity
      final connectivity = await Connectivity().checkConnectivity();
      final hasConnection = connectivity.any(
        (result) => result != ConnectivityResult.none,
      );

      if (!hasConnection) {
        _scheduleReconnect();
        return;
      }

      // Get current session token
      final token = await Base.getSessionToken();
      if (token == null) {
        _scheduleReconnect();
        return;
      }
      final userId = Base.userId.toString();

      // Build WebSocket URL
      final wsUri = Uri.parse(_wsScheme('${Env.apiRoot}/updates/$userId'))
          .replace(
            queryParameters: {
              'clientId': _clientId.toString(),
              'clientVersion': '${AppInfo.version}/${AppInfo.buildNumber}',
              'clientPlatform': AppInfo.platform,
            },
          );

      final channel = createWebSocketChannel(wsUri, ['plot-v1', token]);
      _channel = channel;

      // Wait for connection to be established
      // This will throw WebSocketChannelException if connection fails (e.g., HTTP 401)
      await channel.ready;

      // Channel may have been cleaned up during the await (e.g. disconnect() called)
      if (_channel != channel) return;

      // Listen for messages
      _messageSubscription = channel.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDisconnection,
      );

      _isConnected = true;
      _updateConnectionNotifier();
      _resetBackoff();
      _reconnectTimer?.cancel();

      _startPingTimer();

      if (_wasEverConnected) {
        log.info("WebSocket connection restored");
        _onReconnected?.call();
      } else {
        _wasEverConnected = true;
        log.info("WebSocket connected");
      }
    } on WebSocketChannelException catch (e) {
      // Check for auth errors during connection establishment
      if (_isAuthError(e)) {
        log.warning("WebSocket authentication failed");
        await _handleAuthError();
      } else {
        await _handleError(e);
      }
    } catch (e, stackTrace) {
      // Log unexpected non-network errors
      if (!_isNetworkError(e)) {
        log.warning("WebSocket connection error", e, stackTrace);
      }
      await _handleError(e);
    }
  }

  /// Check if an error is a network-related error (expected during connectivity issues)
  bool _isNetworkError(Object error) {
    final errorString = error.toString().toLowerCase();
    return errorString.contains('connection refused') ||
        errorString.contains('network is unreachable') ||
        errorString.contains('no route to host') ||
        errorString.contains('host is down') ||
        errorString.contains('socketexception') ||
        errorString.contains('connection reset') ||
        errorString.contains('connection timed out') ||
        errorString.contains('no internet');
  }

  /// Send a structured ping to the server indicating active/inactive state.
  void _sendPing({required bool active}) {
    if (_isConnected && _channel != null) {
      try {
        _channel!.sink.add(jsonEncode({'type': 'ping', 'active': active}));
      } catch (_) {
        // Connection is broken; will be handled by error/disconnection handlers
      }
    }
  }

  /// Start sending periodic ping frames to keep the connection alive
  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      _sendPing(active: true);
    });
  }

  /// Cancel the ping timer
  void _cancelPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  /// Disconnect from the WebSocket. Tears down all transient state but keeps
  /// the singleton (and its [connectionState] notifier) alive so UI listeners
  /// stay subscribed across the disconnect/reconnect cycles triggered by every
  /// full sync.
  void disconnect() {
    _cancelPingTimer();

    _messageSubscription?.cancel();
    _messageSubscription = null;

    _channel?.sink.close();
    _channel = null;

    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    _isConnected = false;
    _offlineDebounceTimer?.cancel();
    _offlineDebounceTimer = null;
    connectionState.value = true;
    _wasEverConnected = false;
    _messageHandler = null;
    _onReconnected = null;
    _clientId = null;
  }

  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic data) async {
    // Filter out keepalive pong responses
    if (data == 'pong') return;

    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;

      if (_messageHandler != null) {
        await _messageHandler!(message);
      }
    } catch (e, stackTrace) {
      log.warning("Error handling WebSocket message: $data", e, stackTrace);
    }
  }

  /// Check if an error is an authentication error
  bool _isAuthError(Object error) {
    // Check typed WebSocketChannelException first
    if (error is WebSocketChannelException) {
      final message = error.message?.toLowerCase() ?? '';
      final inner = error.inner?.toString().toLowerCase() ?? '';
      return message.contains('401') ||
          message.contains('unauthorized') ||
          inner.contains('401') ||
          inner.contains('unauthorized');
    }

    // Fallback to string matching for other error types
    final errorString = error.toString().toLowerCase();
    return errorString.contains('401') || errorString.contains('unauthorized');
  }

  /// Handle authentication errors by verifying the session with Clerk.
  /// If the session is definitively invalid, triggers sign-out.
  /// Otherwise schedules a reconnect with a fresh token.
  Future<void> _handleAuthError() async {
    // Clean up any existing broken channel before attempting reconnection
    if (_channel != null) {
      _messageSubscription?.cancel();
      _channel = null;
    }
    _isConnected = false;
    _updateConnectionNotifier();

    // The websocket just rejected our token as unauthorized, so the
    // cached JWT is known-bad — force a reconciliation with Clerk's
    // server rather than handing the same token back on reconnect.
    final result = await Base.getSessionTokenWithReason(forceRefresh: true);
    Base.handleTokenResult(result);

    // If sessionInvalid, Base triggers sign-out — no reconnect needed.
    if (result.failure == TokenFailureReason.sessionInvalid) return;

    // Network error or stale token — reconnect will use a fresh token.
    log.info("WebSocket auth failed — will retry with fresh token");
    _shouldReconnect = true;
    _scheduleReconnect();
  }

  /// Handle WebSocket errors
  Future<void> _handleError(Object error) async {
    final wasConnected = _isConnected;
    _isConnected = false;
    _updateConnectionNotifier();
    _cancelPingTimer();

    if (_channel != null) {
      _messageSubscription?.cancel();
      _channel = null;
    }

    // Check if this is an authentication error and handle it
    if (_isAuthError(error)) {
      log.warning("WebSocket authentication failed");
      await _handleAuthError();
      return;
    }

    // Only log connection lost once (when we were connected)
    if (wasConnected && _wasEverConnected) {
      // Log non-network errors, otherwise just note connection lost
      if (!_isNetworkError(error)) {
        log.warning("WebSocket connection lost: $error");
      } else {
        log.info("WebSocket connection lost");
      }
    }

    if (_shouldReconnect) {
      _scheduleReconnect();
    }
  }

  /// Handle WebSocket disconnection
  Future<void> _handleDisconnection() async {
    final closeCode = _channel?.closeCode;
    final wasConnected = _isConnected;
    _isConnected = false;
    _updateConnectionNotifier();
    _cancelPingTimer();

    // Check for authentication-related close codes
    // 4401: Custom auth failure code (private use range 3000-4999)
    // 1008: Policy violation (can indicate auth failure)
    if (closeCode == 4401 || closeCode == 1008) {
      log.warning("WebSocket authentication failed (close code: $closeCode)");
      if (_channel != null) {
        _messageSubscription?.cancel();
        _channel = null;
      }
      await _handleAuthError();
      return;
    }

    // Only log connection lost once (when we were connected)
    if (wasConnected && _wasEverConnected) {
      log.info("WebSocket connection lost");
    }

    if (_channel != null) {
      _messageSubscription?.cancel();
      _channel = null;
    }

    if (_shouldReconnect) {
      _scheduleReconnect();
    }
  }

  /// Schedule a reconnection attempt with exponential backoff (no max attempts)
  void _scheduleReconnect() {
    if (!_shouldReconnect || _reconnectTimer != null || !_appIsActive) {
      return;
    }

    // Add jitter (0-1000ms) to prevent thundering herd
    final jitterMs = Random().nextInt(1000);
    final totalDelay = Duration(milliseconds: _currentDelayMs + jitterMs);

    _reconnectTimer = Timer(totalDelay, () {
      _reconnectTimer = null;
      // Increase delay for next attempt (exponential backoff), capped at max
      _currentDelayMs = min(
        _currentDelayMs * 2,
        _maxReconnectDelay.inMilliseconds,
      );
      _connect();
    });
  }

  static String _wsScheme(String apiRoot) {
    if (apiRoot.startsWith('https://')) {
      return apiRoot.replaceFirst('https', 'wss');
    } else if (apiRoot.startsWith('http://')) {
      return apiRoot.replaceFirst('http', 'ws');
    } else {
      // Optionally, throw or handle unexpected input.
      throw ArgumentError('API root must start with http:// or https://');
    }
  }
}
