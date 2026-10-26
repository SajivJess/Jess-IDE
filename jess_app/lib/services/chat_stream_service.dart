import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/agent_event.dart';
import 'auth_api_service.dart';

enum ChatStreamStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

class ChatStreamService {
  final String conversationId;
  int lastSequenceNumber;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;

  bool _isDisposed = false;
  int _reconnectAttempts = 0;

  final _eventController = StreamController<AgentEventModel>.broadcast();
  final _statusController = StreamController<ChatStreamStatus>.broadcast();

  Stream<AgentEventModel> get events => _eventController.stream;
  Stream<ChatStreamStatus> get status => _statusController.stream;
  ChatStreamStatus currentStatus = ChatStreamStatus.disconnected;

  ChatStreamService({
    required this.conversationId,
    this.lastSequenceNumber = 0,
  });

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
      '$wsBase/ws/conversations/$conversationId?after=$lastSequenceNumber&token=$token',
    );
  }

  void connect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();

    _updateStatus(
      _reconnectAttempts > 0 ? ChatStreamStatus.reconnecting : ChatStreamStatus.connecting,
    );

    try {
      final uri = _buildWsUri();
      debugPrint('[ChatStreamService] Connecting to $uri (after: $lastSequenceNumber)');
      _channel = WebSocketChannel.connect(uri);

      _subscription = _channel!.stream.listen(
        _onMessageReceived,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: true,
      );

      _updateStatus(ChatStreamStatus.connected);
      _reconnectAttempts = 0;
      _startHeartbeat();
    } catch (e) {
      debugPrint('[ChatStreamService] Connection exception: $e');
      _onError(e);
    }
  }

  void _onMessageReceived(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'pong') {
        return;
      }

      if (type == 'error') {
        debugPrint('[ChatStreamService] Server error: ${json['message']}');
        return;
      }

      // Check if normalized AgentEvent schema
      final event = AgentEventModel.fromJson(json);

      if (event.sequence > lastSequenceNumber) {
        lastSequenceNumber = event.sequence;
      }

      if (!_eventController.isClosed) {
        _eventController.add(event);
      }
    } catch (e) {
      debugPrint('[ChatStreamService] Error decoding message: $e');
    }
  }

  void _onError(dynamic err) {
    debugPrint('[ChatStreamService] WebSocket error: $err');
    _updateStatus(ChatStreamStatus.error);
    _scheduleReconnect();
  }

  void _onDone() {
    debugPrint('[ChatStreamService] WebSocket closed by server');
    _updateStatus(ChatStreamStatus.disconnected);
    if (!_isDisposed) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();

    _reconnectAttempts++;
    final delaySeconds = _reconnectAttempts > 4 ? 8 : _reconnectAttempts * 2;
    debugPrint('[ChatStreamService] Reconnect in ${delaySeconds}s (attempt $_reconnectAttempts)');

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

  void _updateStatus(ChatStreamStatus s) {
    currentStatus = s;
    if (!_statusController.isClosed) {
      _statusController.add(s);
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _updateStatus(ChatStreamStatus.disconnected);
  }

  void dispose() {
    _isDisposed = true;
    disconnect();
    _eventController.close();
    _statusController.close();
  }
}
