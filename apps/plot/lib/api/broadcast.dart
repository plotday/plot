import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import 'package:plot/base.dart';
import 'package:plot/env.dart';
import 'package:plot/logging.dart';
import 'package:plot/api/broadcast_channel.dart';

typedef MessageHandler = Future<void> Function(Map<String, dynamic> message);

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
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  static const Duration _baseReconnectDelay = Duration(seconds: 1);
  static const Duration _maxReconnectDelay = Duration(seconds: 30);
  static const Duration _pingInterval = Duration(seconds: 30);

  bool _isConnected = false;
  bool _shouldReconnect = false;
  bool _hasConnectivity = false;
  bool _wasEverConnected =
      false; // Track if we've ever had a successful connection
  int _currentDelayMs = 1000; // Track current backoff delay
  MessageHandler? _messageHandler;
  int? _clientId;
  bool _isRefreshingToken = false; // Prevent concurrent refresh attempts
  int _authFailureCount = 0; // Track consecutive auth failures
  static const int _maxAuthRetries = 2; // Max refresh attempts before sign-out

  bool get isConnected => _isConnected;

  /// Initialize the broadcast client with a message handler
  Future<void> connect(MessageHandler messageHandler, int clientId) async {
    _messageHandler = messageHandler;
    _clientId = clientId;

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _shouldReconnect &&
        !_isConnected) {
      _resetBackoff(); // Reset backoff for immediate reconnect
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _connect();
    }
  }

  /// Reset backoff delay for immediate reconnection
  void _resetBackoff() {
    _currentDelayMs = _baseReconnectDelay.inMilliseconds;
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

      // Get current session tokens
      final session = Base.client.auth.currentSession;
      if (session?.accessToken == null || session?.refreshToken == null) {
        _scheduleReconnect();
        return;
      }

      final token = '${session!.accessToken}|${session.refreshToken}';
      final userId = session.user.id;

      // Build WebSocket URL
      final wsUri = Uri.parse(
        _wsScheme('${Env.apiRoot}/updates/$userId'),
      ).replace(queryParameters: {'clientId': _clientId.toString()});

      _channel = createWebSocketChannel(wsUri, ['plot-v1', token]);

      // Wait for connection to be established
      // This will throw WebSocketChannelException if connection fails (e.g., HTTP 401)
      await _channel!.ready;

      // Listen for messages
      _messageSubscription = _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDisconnection,
      );

      _isConnected = true;
      _resetBackoff();
      _authFailureCount = 0; // Reset auth failure count on successful connection
      _reconnectTimer?.cancel();

      _startPingTimer();

      if (_wasEverConnected) {
        log.info("WebSocket connection restored");
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

  /// Start sending periodic ping frames to keep the connection alive
  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_isConnected && _channel != null) {
        try {
          _channel!.sink.add('ping');
        } catch (_) {
          // Connection is broken; will be handled by error/disconnection handlers
        }
      }
    });
  }

  /// Cancel the ping timer
  void _cancelPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  /// Disconnect from the WebSocket
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

    WidgetsBinding.instance.removeObserver(this);

    _isConnected = false;
    _wasEverConnected = false;
    _isRefreshingToken = false;
    _authFailureCount = 0;
    _messageHandler = null;
    _clientId = null;
    _instance = null;
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

  /// Handle authentication errors by attempting token refresh before signing out
  Future<void> _handleAuthError() async {
    // Clean up any existing broken channel before attempting reconnection
    // This is critical: when _connect() fails with a 401 during await _channel!.ready,
    // _channel is already set but points to a broken channel. Without this cleanup,
    // _scheduleReconnect() will call _connect() which returns early due to _channel != null.
    if (_channel != null) {
      _messageSubscription?.cancel();
      _channel = null;
    }
    _isConnected = false;

    // Guard against concurrent refresh attempts
    if (_isRefreshingToken) {
      log.info("Token refresh already in progress, skipping");
      return;
    }

    log.info(
      "WebSocket auth failed - attempting token refresh",
    );

    _isRefreshingToken = true;
    try {
      await Base.refreshSession();
      log.info("Token refresh successful - reconnecting WebSocket");

      // Session is valid: reset failure count and reconnect with backoff
      _authFailureCount = 0;
      _shouldReconnect = true;
      _isRefreshingToken = false;

      _scheduleReconnect();
    } on supa.AuthException catch (e) {
      // Refresh token is invalid - must sign out
      log.warning("Token refresh failed (AuthException: ${e.message}) - signing out user");
      _isRefreshingToken = false;
      _shouldReconnect = false;
      try {
        await Base.signOut();
      } catch (signOutError, stackTrace) {
        log.warning("Error during sign-out", signOutError, stackTrace);
      }
    } catch (e) {
      _isRefreshingToken = false;

      // Token refresh failed for non-auth reason (network error, server down, etc.)
      // Count these failures — if repeated, the session may actually be invalid
      _authFailureCount++;
      if (_authFailureCount > _maxAuthRetries) {
        log.warning(
          "Token refresh failed $_authFailureCount times ($e) - signing out user",
        );
        _shouldReconnect = false;
        try {
          await Base.signOut();
        } catch (signOutError, stackTrace) {
          log.warning("Error during sign-out", signOutError, stackTrace);
        }
      } else {
        log.info(
          "Token refresh failed (attempt $_authFailureCount/$_maxAuthRetries: $e) - will retry",
        );
        _shouldReconnect = true;
        _scheduleReconnect();
      }
    }
  }

  /// Handle WebSocket errors
  Future<void> _handleError(Object error) async {
    final wasConnected = _isConnected;
    _isConnected = false;
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
    if (!_shouldReconnect || _reconnectTimer != null) {
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
