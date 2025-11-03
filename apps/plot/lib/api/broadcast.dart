import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:plot/base.dart';
import 'package:plot/env.dart';
import 'package:plot/logging.dart';
import 'package:plot/api/broadcast_channel.dart';

typedef MessageHandler = Future<void> Function(Map<String, dynamic> message);

class BroadcastClient {
  static BroadcastClient? _instance;
  static BroadcastClient get instance => _instance ??= BroadcastClient._();

  BroadcastClient._();

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  StreamSubscription<dynamic>? _messageSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;
  static const Duration _baseReconnectDelay = Duration(seconds: 1);

  bool _isConnected = false;
  bool _shouldReconnect = false;
  bool _hasConnectivity = false;
  MessageHandler? _messageHandler;
  int? _clientId;

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
      log.info("Initial connectivity: $_hasConnectivity");
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
        log.info("Network connectivity restored, attempting to reconnect");
        _connect();
      }
    });
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
        log.warning("No network connectivity, skipping WebSocket connection");
        _scheduleReconnect();
        return;
      }

      // Get current session tokens
      final session = Base.client.auth.currentSession;
      if (session?.accessToken == null || session?.refreshToken == null) {
        log.warning(
          "No valid session tokens available for WebSocket connection",
        );
        _scheduleReconnect();
        return;
      }

      final token = '${session!.accessToken}|${session.refreshToken}';
      final userId = session.user.id;

      // Build WebSocket URL
      //

      final wsUri = Uri.parse(
        _wsScheme('${Env.apiRoot}/updates/$userId'),
      ).replace(queryParameters: {'clientId': _clientId.toString()});

      log.info("Connecting to WebSocket: $wsUri");

      _channel = createWebSocketChannel(wsUri, ['plot-v1', token]);

      // Listen for messages
      _messageSubscription = _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDisconnection,
      );

      _isConnected = true;
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();

      log.info("WebSocket connected successfully");
    } catch (e, stackTrace) {
      log.warning("Failed to connect to WebSocket", e, stackTrace);
      _handleError(e);
    }
  }

  /// Disconnect from the WebSocket
  void disconnect() {
    log.info("Disconnecting WebSocket");
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
    _messageHandler = null;
    _clientId = null;
    _instance = null;
  }

  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic data) async {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      log.info("Received WebSocket message: $message");

      if (_messageHandler != null) {
        await _messageHandler!(message);
      }
    } catch (e, stackTrace) {
      log.warning("Error handling WebSocket message: $data", e, stackTrace);
    }
  }

  /// Handle WebSocket errors
  void _handleError(dynamic error) {
    log.warning("WebSocket error: $error");
    _isConnected = false;

    if (_channel != null) {
      _messageSubscription?.cancel();
      _channel = null;
    }

    if (_shouldReconnect) {
      _scheduleReconnect();
    }
  }

  /// Handle WebSocket disconnection
  void _handleDisconnection() {
    log.info("WebSocket disconnected");
    _isConnected = false;

    if (_channel != null) {
      _messageSubscription?.cancel();
      _channel = null;
    }

    if (_shouldReconnect) {
      _scheduleReconnect();
    }
  }

  /// Schedule a reconnection attempt with exponential backoff
  void _scheduleReconnect() {
    if (!_shouldReconnect || _reconnectTimer != null) {
      return;
    }

    _reconnectAttempts++;

    if (_reconnectAttempts > _maxReconnectAttempts) {
      log.warning("Max reconnection attempts reached, giving up");
      return;
    }

    // Exponential backoff with jitter
    final delayMs =
        (_baseReconnectDelay.inMilliseconds * pow(2, _reconnectAttempts - 1))
            .round();
    final jitterMs = Random().nextInt(1000);
    final totalDelay = Duration(milliseconds: delayMs + jitterMs);

    log.info(
      "Scheduling reconnection attempt $_reconnectAttempts in ${totalDelay.inSeconds}s",
    );

    _reconnectTimer = Timer(totalDelay, () {
      _reconnectTimer = null;
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
