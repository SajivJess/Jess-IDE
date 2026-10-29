import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'auth_api_service.dart';
import 'tasks_api_service.dart';

enum StreamConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

class TaskStreamService {
  final String taskId;
  int lastSequenceNumber;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;

  bool _isDisposed = false;
  int _reconnectAttempts = 0;

  final _eventController = StreamController<TaskEventModel>.broadcast();
  final _statusController = StreamController<StreamConnectionStatus>.broadcast();

  Stream<TaskEventModel> get events => _eventController.stream;
  Stream<StreamConnectionStatus> get status => _statusController.stream;
  StreamConnectionStatus currentStatus = StreamConnectionStatus.disconnected;

  TaskStreamService({
    required this.taskId,
    this.lastSequenceNumber = 0,
  });

  /// Build WebSocket URL from base URL
  Uri _buildWsUri() {
    final baseHttp = AuthApiService.baseUrl;
    String wsBase;
    if (baseHttp.startsWith('https://')) {
      wsBase = baseHttp.replaceFirst('https://', 'wss://');
    } else if (baseHttp.startsWith('http://')) {
      wsBase = baseHttp.replaceFirst('http://', 'ws://');
    } else {
      wsBase = 'ws://127.0.0.1:8000/api/v1';
    }

    final token = AuthApiService.currentAccessToken ?? '';
    return Uri.parse(
      '$wsBase/ws/tasks/$taskId?after=$lastSequenceNumber&token=$token',
    );
  }

  /// Establish WebSocket connection
  void connect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();

    _updateStatus(
      _reconnectAttempts > 0
          ? StreamConnectionStatus.reconnecting
          : StreamConnectionStatus.connecting,
    );

    try {
      final uri = _buildWsUri();
      debugPrint('[TaskStreamService] Connecting to task stream for taskId: $taskId (after: $lastSequenceNumber)');
      _channel = WebSocketChannel.connect(uri);

      _subscription = _channel!.stream.listen(
        _onMessageReceived,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: true,
      );

      _updateStatus(StreamConnectionStatus.connected);
      _reconnectAttempts = 0;
      _startHeartbeat();
    } catch (e) {
      debugPrint('[TaskStreamService] Connection exception: $e');
      _onError(e);
    }
  }

  void _onMessageReceived(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;

      if (type == 'event' && msg['data'] != null) {
        final data = msg['data'] as Map<String, dynamic>;
        final event = TaskEventModel.fromJson(data);

        // Track highest seen sequence number for replay safety
        if (event.sequenceNum > lastSequenceNumber) {
          lastSequenceNumber = event.sequenceNum;
        }

        if (!_eventController.isClosed) {
          _eventController.add(event);
        }
      } else if (type == 'pong') {
        // Heartbeat confirmed
      } else if (type == 'error') {
        debugPrint('[TaskStreamService] Server error: ${msg['message']}');
      }
    } catch (e) {
      debugPrint('[TaskStreamService] Error parsing message: $e');
    }
  }

  void _onError(dynamic err) {
    debugPrint('[TaskStreamService] WebSocket error: $err');
    _updateStatus(StreamConnectionStatus.error);
    _scheduleReconnect();
  }

  void _onDone() {
    debugPrint('[TaskStreamService] WebSocket connection closed by peer');
    _updateStatus(StreamConnectionStatus.disconnected);
    if (!_isDisposed) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();

    // Exponential backoff with jitter up to 10s
    _reconnectAttempts++;
    final delaySeconds = (_reconnectAttempts > 5 ? 10 : _reconnectAttempts * 2);
    debugPrint('[TaskStreamService] Scheduling reconnect in ${delaySeconds}s (attempt $_reconnectAttempts)');

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!_isDisposed) {
        connect();
      }
    });
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });
  }

  void _updateStatus(StreamConnectionStatus s) {
    currentStatus = s;
    if (!_statusController.isClosed) {
      _statusController.add(s);
    }
  }

  /// Disconnect manually
  void disconnect() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _updateStatus(StreamConnectionStatus.disconnected);
  }

  /// Clean up all streams and controllers
  void dispose() {
    _isDisposed = true;
    disconnect();
    _eventController.close();
    _statusController.close();
  }
}
